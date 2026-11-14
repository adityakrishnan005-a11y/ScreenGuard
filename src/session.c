/*
 * digiwelld-session — durable session-state worker for ScreenGuard.
 *
 * This is the first worker of the digiwelld migration. It owns exactly one
 * thing: the small amount of state that must survive a crash or a restart,
 * and the decision whether the session remembered in that state can be
 * adopted or must be closed at the last observed tick.
 *
 * What it deliberately does NOT do:
 *
 *   * query windows or idle time         -> tracker / future session backend
 *   * write SQLite                      -> digiwelld-store (single writer)
 *   * enforce limits                    -> digiwelld-enforce
 *
 * Ownership boundary during the migration:
 *
 *   digiwelld-session   owns the journal + recovery decision
 *   Dart tracker        owns the observation loop and SQLite writes
 *
 * The caller tells the worker when a database session was opened, when it was
 * closed, and when the last poll happened. The worker persists that fact and
 * reports what happened at the next startup. That keeps the state contract
 * stable when SQLite moves behind digiwelld-store.
 *
 * On-disk format (identical to lib/services/session_memory.dart):
 *
 *   session-state.json      one envelope: {"v":1,"seq":N,"state":{...}}
 *   session-journal.jsonl   append-only envelopes, one per transition
 *
 * The snapshot wins over journal records with an older `seq`. A crash between
 * the snapshot rename and the journal truncate therefore cannot replay stale
 * state. A corrupt final line is ignored, never fatal.
 *
 * Recovery policy (mirrors the Dart tracker):
 *
 *   gap <= 15 s        adopt the open session (quick restart)
 *   gap >  15 s        close it at the last observed tick (honest downtime)
 *   lock/suspend       never restored: they are live signals, and a stale
 *                      `true` could suppress tracking indefinitely
 *
 * Protocol (same envelope as the broker):
 *
 *   request   <domain> <method> <json-object>
 *   response  ok <json>
 *             err <reason>
 *
 * Domains: system, session. One request per connection.
 *
 * Build:
 *   cc -O2 -Wall -Wextra -std=c99 -o digiwelld-session src/session.c
 */

#define _GNU_SOURCE
#include <ctype.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <poll.h>
#include <signal.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/file.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/un.h>
#include <time.h>
#include <unistd.h>

#define MAX_REQUEST          65536
#define MAX_RESPONSE         65536
#define MAX_STATE_JSON       16384
#define MAX_JSON_PAIRS       32
#define MAX_STRING           1024
#define BACKLOG              16
#define IO_TIMEOUT_SEC       3
#define SOCK_MODE            0600
#define DIR_MODE             0700
#define RESUME_THRESHOLD_MS  15000LL   /* adopt an open session */
#define ENV_FRESH_MS         120000LL  /* lock/suspend/day-start freshness */
#define DEFAULT_COMPACT_AFTER 128
#define TICKS_PER_CHECKPOINT 5
#define SCHEMA_VERSION       1

static volatile sig_atomic_t g_stop = 0;
static volatile sig_atomic_t g_exit_code = 0;

static char g_runtime[PATH_MAX];
static char g_state_dir[PATH_MAX];
static char g_socket_path[PATH_MAX];
static char g_lock_path[PATH_MAX];
static char g_snapshot_path[PATH_MAX];
static char g_journal_path[PATH_MAX];

static int g_listen_fd = -1;
static int g_lock_fd = -1;
static int g_verbose = 0;
static long long g_now_override = 0;
static long long g_started_at_ms = 0;

static long long g_seq = 0;
static long long g_entries = 0;
static int g_compact_after = DEFAULT_COMPACT_AFTER;
static int g_ticks_since_checkpoint = 0;
static int g_had_state = 0;

/* Populated once at startup and reported through session.restore/status. */
static int g_resumed_id = 0;
static int g_closed_id = 0;
static long long g_close_at_ms = 0;
static long long g_restart_gap_ms = -1;

/* ------------------------------------------------------------------ state */

/*
 * The exact SessionMemory contract. Empty app/title mean "not set"; integer
 * zero means "not set" for ids/timestamps; -1 means JSON null for booleans.
 */
typedef struct {
    long long written_at_ms;
    long long current_session_id;
    char      current_app[MAX_STRING];
    char      current_title[MAX_STRING];
    long long current_pid;
    int       current_idle;              /* -1 = null */
    long long session_started_at_ms;
    long long last_tick_ms;
    int       last_idle_reported;         /* -1 = null */
    int       session_locked;
    int       suspended;
    long long day_start_ms;
    int       consecutive_unknown_ticks;
} session_state;

static void state_init(session_state *s) {
    memset(s, 0, sizeof *s);
    s->current_idle = -1;
    s->last_idle_reported = -1;
}

static session_state g_state;

static void state_clear_current(session_state *s) {
    s->current_session_id = 0;
    s->current_app[0] = '\0';
    s->current_title[0] = '\0';
    s->current_pid = 0;
    s->current_idle = -1;
    s->session_started_at_ms = 0;
    /* last_tick_ms is intentionally kept: it is the honest close boundary. */
}

/* ------------------------------------------------------------------ utils */

static long long now_ms(void) {
    if (g_now_override > 0) return g_now_override;
    struct timespec ts;
    clock_gettime(CLOCK_REALTIME, &ts);
    return (long long)ts.tv_sec * 1000LL + ts.tv_nsec / 1000000LL;
}

static long long local_midnight_ms(long long at_ms) {
    time_t t = (time_t)(at_ms / 1000);
    struct tm tm;
    if (!localtime_r(&t, &tm)) return at_ms - (at_ms % 86400000LL);
    tm.tm_hour = 0;
    tm.tm_min = 0;
    tm.tm_sec = 0;
    tm.tm_isdst = -1;
    time_t midnight = mktime(&tm);
    if (midnight == (time_t)-1) return at_ms - (at_ms % 86400000LL);
    return (long long)midnight * 1000LL;
}

static void logmsg(const char *fmt, ...) {
    if (!g_verbose) return;
    va_list ap;
    char stamp[32];
    time_t t = time(NULL);
    struct tm tm;
    localtime_r(&t, &tm);
    strftime(stamp, sizeof stamp, "%H:%M:%S", &tm);
    fprintf(stderr, "[session %s] ", stamp);
    va_start(ap, fmt);
    vfprintf(stderr, fmt, ap);
    va_end(ap);
    fputc('\n', stderr);
    fflush(stderr);
}

static void on_signal(int sig) {
    (void)sig;
    g_stop = 1;
}

static void secure_fd_file(int fd) {
    if (fd >= 0) (void)fchmod(fd, SOCK_MODE);
}

static int join_path(char *dst, size_t cap, const char *dir,
                     const char *name) {
    size_t d = strlen(dir);
    size_t n = strlen(name);
    if (d + 1 + n >= cap) return -1;
    memcpy(dst, dir, d);
    dst[d] = '/';
    memcpy(dst + d + 1, name, n + 1);
    return 0;
}

static int mkdir_p(const char *path) {
    char tmp[PATH_MAX];
    if (strlen(path) >= sizeof tmp) return -1;
    snprintf(tmp, sizeof tmp, "%s", path);
    for (char *p = tmp + 1; *p; p++) {
        if (*p != '/') continue;
        *p = '\0';
        if (mkdir(tmp, DIR_MODE) < 0 && errno != EEXIST) return -1;
        *p = '/';
    }
    if (mkdir(tmp, DIR_MODE) < 0 && errno != EEXIST) return -1;
    return 0;
}

static int ensure_private_dir(const char *path) {
    if (mkdir_p(path) < 0) {
        logmsg("cannot create %s: %s", path, strerror(errno));
        return -1;
    }
    struct stat st;
    if (stat(path, &st) < 0 || !S_ISDIR(st.st_mode)) return -1;
    if ((st.st_mode & (S_IRWXG | S_IRWXO)) != 0) {
        logmsg("%s has group/other bits; fixing to %04o", path, DIR_MODE);
        if (chmod(path, DIR_MODE) < 0) return -1;
    }
    return 0;
}

/* Exclusive, non-blocking lock. Returns fd, -2 if held by somebody else. */
static int lock_exclusive(const char *path) {
    int fd = open(path, O_CREAT | O_RDWR | O_CLOEXEC, 0600);
    if (fd < 0) {
        logmsg("open %s: %s", path, strerror(errno));
        return -1;
    }
    if (flock(fd, LOCK_EX | LOCK_NB) < 0) {
        int e = errno;
        close(fd);
        errno = e;
        return (e == EWOULDBLOCK) ? -2 : -1;
    }
    char buf[32];
    int n = snprintf(buf, sizeof buf, "%ld\n", (long)getpid());
    if (ftruncate(fd, 0) == 0) {
        ssize_t w = write(fd, buf, (size_t)n);
        (void)w;
    }
    return fd;
}

static int listen_unix(const char *path) {
    struct sockaddr_un addr;
    if (strlen(path) >= sizeof addr.sun_path) {
        logmsg("socket path too long: %s", path);
        return -1;
    }
    memset(&addr, 0, sizeof addr);
    addr.sun_family = AF_UNIX;
    strncpy(addr.sun_path, path, sizeof addr.sun_path - 1);

    unlink(path);
    int fd = socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0);
    if (fd < 0) {
        logmsg("socket: %s", strerror(errno));
        return -1;
    }
    if (bind(fd, (struct sockaddr *)&addr, sizeof addr) < 0) {
        logmsg("bind %s: %s", path, strerror(errno));
        close(fd);
        return -1;
    }
    if (chmod(path, SOCK_MODE) < 0) {
        logmsg("chmod %s: %s", path, strerror(errno));
        close(fd);
        unlink(path);
        return -1;
    }
    if (listen(fd, BACKLOG) < 0) {
        logmsg("listen: %s", strerror(errno));
        close(fd);
        unlink(path);
        return -1;
    }
    return fd;
}

static int peer_is_self(int fd) {
    struct ucred cred;
    socklen_t len = sizeof cred;
    if (getsockopt(fd, SOL_SOCKET, SO_PEERCRED, &cred, &len) < 0) {
        logmsg("SO_PEERCRED: %s", strerror(errno));
        return 0;
    }
    if (cred.uid != geteuid()) {
        logmsg("reject uid=%ld (worker uid=%ld)",
               (long)cred.uid, (long)geteuid());
        return 0;
    }
    return 1;
}

static ssize_t write_all(int fd, const char *buf, size_t len) {
    size_t off = 0;
    while (off < len) {
        ssize_t n = write(fd, buf + off, len - off);
        if (n < 0) {
            if (errno == EINTR) continue;
            return -1;
        }
        off += (size_t)n;
    }
    return (ssize_t)off;
}

static void reply(int fd, const char *fmt, ...) {
    char buf[MAX_RESPONSE];
    va_list ap;
    va_start(ap, fmt);
    int n = vsnprintf(buf, sizeof buf - 2, fmt, ap);
    va_end(ap);
    if (n < 0) n = 0;
    if ((size_t)n > sizeof buf - 2) n = (int)(sizeof buf - 2);
    buf[n++] = '\n';
    (void)write_all(fd, buf, (size_t)n);
}

static ssize_t read_line(int fd, char *buf, size_t cap) {
    size_t off = 0;
    while (off + 1 < cap) {
        ssize_t n = read(fd, buf + off, cap - 1 - off);
        if (n < 0) {
            if (errno == EINTR) continue;
            return -1;
        }
        if (n == 0) break;
        off += (size_t)n;
        if (memchr(buf, '\n', off) != NULL) break;
    }
    buf[off] = '\0';
    return (ssize_t)off;
}

/* --------------------------------------------------------------- JSON I/O */

typedef enum { JV_NULL, JV_BOOL, JV_NUM, JV_STR, JV_OBJ } jv_type;

typedef struct {
    jv_type     type;
    int         boolean;
    long long   num;
    char        str[MAX_STRING];
    const char *raw;      /* JV_OBJ: points into the parsed source */
    size_t      raw_len;
} jvalue;

typedef struct {
    char   key[64];
    jvalue val;
} jpair;

typedef struct {
    jpair pairs[MAX_JSON_PAIRS];
    int   count;
} jobject;

typedef struct {
    const char *p;
    const char *end;
} jparser;

static int hexval(int c) {
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    return -1;
}

static int utf8_put(char *out, size_t cap, size_t *len, unsigned cp) {
    unsigned char bytes[4];
    size_t n;
    if (cp <= 0x7F) {
        bytes[0] = (unsigned char)cp;
        n = 1;
    } else if (cp <= 0x7FF) {
        bytes[0] = (unsigned char)(0xC0 | (cp >> 6));
        bytes[1] = (unsigned char)(0x80 | (cp & 0x3F));
        n = 2;
    } else if (cp <= 0xFFFF) {
        bytes[0] = (unsigned char)(0xE0 | (cp >> 12));
        bytes[1] = (unsigned char)(0x80 | ((cp >> 6) & 0x3F));
        bytes[2] = (unsigned char)(0x80 | (cp & 0x3F));
        n = 3;
    } else if (cp <= 0x10FFFF) {
        bytes[0] = (unsigned char)(0xF0 | (cp >> 18));
        bytes[1] = (unsigned char)(0x80 | ((cp >> 12) & 0x3F));
        bytes[2] = (unsigned char)(0x80 | ((cp >> 6) & 0x3F));
        bytes[3] = (unsigned char)(0x80 | (cp & 0x3F));
        n = 4;
    } else {
        return -1;
    }
    if (*len + n >= cap) return -1;
    memcpy(out + *len, bytes, n);
    *len += n;
    return 0;
}

static void jp_ws(jparser *jp) {
    while (jp->p < jp->end) {
        char c = *jp->p;
        if (c != ' ' && c != '\t' && c != '\n' && c != '\r') break;
        jp->p++;
    }
}

static int jp_hex4(jparser *jp, unsigned *out) {
    if (jp->end - jp->p < 4) return -1;
    unsigned v = 0;
    for (int i = 0; i < 4; i++) {
        int h = hexval((unsigned char)jp->p[i]);
        if (h < 0) return -1;
        v = (v << 4) | (unsigned)h;
    }
    jp->p += 4;
    *out = v;
    return 0;
}

static int jp_string(jparser *jp, char *out, size_t cap) {
    if (jp->p >= jp->end || *jp->p != '"') return -1;
    jp->p++;
    size_t len = 0;
    while (jp->p < jp->end) {
        unsigned char c = (unsigned char)*jp->p++;
        if (c == '"') {
            out[len] = '\0';
            return 0;
        }
        if (c == '\\') {
            if (jp->p >= jp->end) return -1;
            char e = *jp->p++;
            switch (e) {
            case '"':  c = '"';  break;
            case '\\': c = '\\'; break;
            case '/':  c = '/';  break;
            case 'b':  c = '\b'; break;
            case 'f':  c = '\f'; break;
            case 'n':  c = '\n'; break;
            case 'r':  c = '\r'; break;
            case 't':  c = '\t'; break;
            case 'u': {
                unsigned cp;
                if (jp_hex4(jp, &cp) != 0) return -1;
                if (cp >= 0xD800 && cp <= 0xDBFF) {
                    if (jp->end - jp->p >= 2 && jp->p[0] == '\\' &&
                        jp->p[1] == 'u') {
                        const char *save = jp->p;
                        jp->p += 2;
                        unsigned low;
                        if (jp_hex4(jp, &low) == 0 &&
                            low >= 0xDC00 && low <= 0xDFFF) {
                            cp = 0x10000 + ((cp - 0xD800) << 10) +
                                 (low - 0xDC00);
                        } else {
                            jp->p = save;
                        }
                    }
                }
                if (cp >= 0xD800 && cp <= 0xDFFF) cp = 0xFFFD;
                if (utf8_put(out, cap, &len, cp) != 0) return -1;
                continue;
            }
            default:
                return -1;
            }
        } else if (c < 0x20) {
            return -1;
        }
        if (len + 1 >= cap) return -1;
        out[len++] = (char)c;
    }
    return -1;
}

static int jp_object(jparser *jp, jobject *obj);

static int jp_value(jparser *jp, jvalue *v) {
    jp_ws(jp);
    if (jp->p >= jp->end) return -1;
    memset(v, 0, sizeof *v);
    char c = *jp->p;

    if (c == '"') {
        v->type = JV_STR;
        return jp_string(jp, v->str, sizeof v->str);
    }
    if (c == '{') {
        const char *start = jp->p;
        jobject nested;
        if (jp_object(jp, &nested) != 0) return -1;
        v->type = JV_OBJ;
        v->raw = start;
        v->raw_len = (size_t)(jp->p - start);
        return 0;
    }
    if (jp->end - jp->p >= 4 && !memcmp(jp->p, "true", 4)) {
        v->type = JV_BOOL;
        v->boolean = 1;
        jp->p += 4;
        return 0;
    }
    if (jp->end - jp->p >= 5 && !memcmp(jp->p, "false", 5)) {
        v->type = JV_BOOL;
        v->boolean = 0;
        jp->p += 5;
        return 0;
    }
    if (jp->end - jp->p >= 4 && !memcmp(jp->p, "null", 4)) {
        v->type = JV_NULL;
        jp->p += 4;
        return 0;
    }
    if (c == '-' || (c >= '0' && c <= '9')) {
        char *endp = NULL;
        errno = 0;
        double d = strtod(jp->p, &endp);
        if (endp == jp->p || errno == ERANGE) return -1;
        if (endp > jp->end) return -1;
        v->type = JV_NUM;
        v->num = (long long)d;
        jp->p = endp;
        return 0;
    }
    return -1;
}

static int jp_object(jparser *jp, jobject *obj) {
    memset(obj, 0, sizeof *obj);
    jp_ws(jp);
    if (jp->p >= jp->end || *jp->p != '{') return -1;
    jp->p++;
    jp_ws(jp);
    if (jp->p < jp->end && *jp->p == '}') {
        jp->p++;
        return 0;
    }
    while (1) {
        jp_ws(jp);
        if (obj->count >= MAX_JSON_PAIRS) return -1;
        jpair *pair = &obj->pairs[obj->count];
        if (jp_string(jp, pair->key, sizeof pair->key) != 0) return -1;
        jp_ws(jp);
        if (jp->p >= jp->end || *jp->p != ':') return -1;
        jp->p++;
        if (jp_value(jp, &pair->val) != 0) return -1;
        obj->count++;
        jp_ws(jp);
        if (jp->p >= jp->end) return -1;
        if (*jp->p == ',') {
            jp->p++;
            continue;
        }
        if (*jp->p == '}') {
            jp->p++;
            return 0;
        }
        return -1;
    }
}

static int json_parse_object(const char *text, size_t len, jobject *out) {
    jparser jp = { text, text + len };
    if (jp_object(&jp, out) != 0) return -1;
    jp_ws(&jp);
    return jp.p == jp.end ? 0 : -1;
}

static const jvalue *json_get(const jobject *obj, const char *key) {
    for (int i = 0; i < obj->count; i++) {
        if (!strcmp(obj->pairs[i].key, key)) return &obj->pairs[i].val;
    }
    return NULL;
}

static int json_get_ll(const jobject *obj, const char *key, long long *out) {
    const jvalue *v = json_get(obj, key);
    if (!v || v->type == JV_NULL) return -1;
    if (v->type == JV_NUM) {
        *out = v->num;
        return 0;
    }
    if (v->type == JV_BOOL) {
        *out = v->boolean;
        return 0;
    }
    if (v->type == JV_STR) {
        char *end = NULL;
        long long n = strtoll(v->str, &end, 10);
        if (end && *end == '\0') {
            *out = n;
            return 0;
        }
    }
    return -1;
}

static int json_get_str(const jobject *obj, const char *key,
                        char *out, size_t cap) {
    const jvalue *v = json_get(obj, key);
    if (!v || v->type == JV_NULL) return -1;
    if (v->type != JV_STR) return -1;
    snprintf(out, cap, "%s", v->str);
    return 0;
}

static int json_get_bool(const jobject *obj, const char *key, int *out) {
    const jvalue *v = json_get(obj, key);
    if (!v || v->type == JV_NULL) return -1;
    if (v->type == JV_BOOL) {
        *out = v->boolean;
        return 0;
    }
    if (v->type == JV_NUM) {
        *out = v->num != 0;
        return 0;
    }
    return -1;
}

typedef struct {
    char  *buf;
    size_t cap;
    size_t len;
    int    overflow;
} sbuf;

static void sb_init(sbuf *b, char *buf, size_t cap) {
    b->buf = buf;
    b->cap = cap;
    b->len = 0;
    b->overflow = 0;
    if (cap) buf[0] = '\0';
}

static void sb_putc(sbuf *b, char c) {
    if (b->len + 1 >= b->cap) {
        b->overflow = 1;
        return;
    }
    b->buf[b->len++] = c;
    b->buf[b->len] = '\0';
}

static void sb_puts(sbuf *b, const char *s) {
    size_t n = strlen(s);
    if (b->len + n >= b->cap) {
        b->overflow = 1;
        return;
    }
    memcpy(b->buf + b->len, s, n);
    b->len += n;
    b->buf[b->len] = '\0';
}

static void sb_printf(sbuf *b, const char *fmt, ...) {
    if (b->overflow) return;
    va_list ap;
    va_start(ap, fmt);
    int n = vsnprintf(b->buf + b->len, b->cap - b->len, fmt, ap);
    va_end(ap);
    if (n < 0) {
        b->overflow = 1;
        return;
    }
    if ((size_t)n >= b->cap - b->len) {
        b->overflow = 1;
        b->len = b->cap - 1;
        return;
    }
    b->len += (size_t)n;
}

static void sb_json_str(sbuf *b, const char *s) {
    sb_putc(b, '"');
    for (const unsigned char *p = (const unsigned char *)s; *p; p++) {
        unsigned char c = *p;
        switch (c) {
        case '"':  sb_puts(b, "\\\""); break;
        case '\\': sb_puts(b, "\\\\"); break;
        case '\b': sb_puts(b, "\\b"); break;
        case '\f': sb_puts(b, "\\f"); break;
        case '\n': sb_puts(b, "\\n"); break;
        case '\r': sb_puts(b, "\\r"); break;
        case '\t': sb_puts(b, "\\t"); break;
        default:
            if (c < 0x20) sb_printf(b, "\\u%04x", c);
            else sb_putc(b, (char)c);
        }
    }
    sb_putc(b, '"');
}

/* ------------------------------------------------------------- serializing */

static void state_json(const session_state *s, sbuf *b) {
    sb_puts(b, "{\"version\":1");
    sb_printf(b, ",\"written_at_ms\":%lld", s->written_at_ms);

    if (s->current_session_id > 0)
        sb_printf(b, ",\"current_session_id\":%lld", s->current_session_id);
    else
        sb_puts(b, ",\"current_session_id\":null");

    if (s->current_app[0]) {
        sb_puts(b, ",\"current_app\":");
        sb_json_str(b, s->current_app);
    } else {
        sb_puts(b, ",\"current_app\":null");
    }
    if (s->current_title[0]) {
        sb_puts(b, ",\"current_title\":");
        sb_json_str(b, s->current_title);
    } else {
        sb_puts(b, ",\"current_title\":null");
    }
    if (s->current_pid > 0)
        sb_printf(b, ",\"current_pid\":%lld", s->current_pid);
    else
        sb_puts(b, ",\"current_pid\":null");

    sb_puts(b, ",\"current_idle\":");
    if (s->current_idle < 0) sb_puts(b, "null");
    else sb_puts(b, s->current_idle ? "true" : "false");

    if (s->session_started_at_ms > 0)
        sb_printf(b, ",\"session_started_at_ms\":%lld",
                  s->session_started_at_ms);
    else
        sb_puts(b, ",\"session_started_at_ms\":null");

    if (s->last_tick_ms > 0)
        sb_printf(b, ",\"last_tick_ms\":%lld", s->last_tick_ms);
    else
        sb_puts(b, ",\"last_tick_ms\":null");

    sb_puts(b, ",\"last_idle_reported\":");
    if (s->last_idle_reported < 0) sb_puts(b, "null");
    else sb_puts(b, s->last_idle_reported ? "true" : "false");

    sb_printf(b, ",\"session_locked\":%s",
              s->session_locked ? "true" : "false");
    sb_printf(b, ",\"suspended\":%s", s->suspended ? "true" : "false");
    sb_printf(b, ",\"day_start_ms\":%lld", s->day_start_ms);
    sb_printf(b, ",\"consecutive_unknown_ticks\":%d",
              s->consecutive_unknown_ticks);
    sb_puts(b, "}");
}

static void state_from_object(const jobject *o, session_state *s) {
    state_init(s);
    long long n;
    int b;
    if (json_get_ll(o, "written_at_ms", &n) == 0) s->written_at_ms = n;
    if (json_get_ll(o, "current_session_id", &n) == 0 &&
        n > 0) s->current_session_id = n;
    (void)json_get_str(o, "current_app", s->current_app,
                       sizeof s->current_app);
    (void)json_get_str(o, "current_title", s->current_title,
                       sizeof s->current_title);
    if (json_get_ll(o, "current_pid", &n) == 0 && n > 0) s->current_pid = n;
    if (json_get_bool(o, "current_idle", &b) == 0) s->current_idle = b;
    if (json_get_ll(o, "session_started_at_ms", &n) == 0 && n > 0)
        s->session_started_at_ms = n;
    if (json_get_ll(o, "last_tick_ms", &n) == 0 && n > 0)
        s->last_tick_ms = n;
    if (json_get_bool(o, "last_idle_reported", &b) == 0)
        s->last_idle_reported = b;
    if (json_get_bool(o, "session_locked", &b) == 0)
        s->session_locked = b;
    if (json_get_bool(o, "suspended", &b) == 0) s->suspended = b;
    if (json_get_ll(o, "day_start_ms", &n) == 0) s->day_start_ms = n;
    if (json_get_ll(o, "consecutive_unknown_ticks", &n) == 0)
        s->consecutive_unknown_ticks = (int)n;
}

static int envelope_build(long long seq, const session_state *s,
                          char *out, size_t cap) {
    sbuf b;
    sb_init(&b, out, cap);
    sb_printf(&b, "{\"v\":%d,\"seq\":%lld,\"state\":",
              SCHEMA_VERSION, seq);
    state_json(s, &b);
    sb_puts(&b, "}");
    return b.overflow ? -1 : 0;
}

static int envelope_parse(const char *text, size_t len,
                          long long *seq, session_state *s) {
    if (len == 0 || len >= MAX_REQUEST) return -1;
    char *tmp = malloc(len + 1);
    if (!tmp) return -1;
    memcpy(tmp, text, len);
    tmp[len] = '\0';

    jobject env;
    if (json_parse_object(tmp, len, &env) != 0) {
        free(tmp);
        return -1;
    }
    long long n;
    if (json_get_ll(&env, "seq", &n) != 0) {
        free(tmp);
        return -1;
    }
    const jvalue *sv = json_get(&env, "state");
    if (!sv || sv->type != JV_OBJ) {
        free(tmp);
        return -1;
    }
    char *sub = malloc(sv->raw_len + 1);
    if (!sub) {
        free(tmp);
        return -1;
    }
    memcpy(sub, sv->raw, sv->raw_len);
    sub[sv->raw_len] = '\0';
    jobject state_obj;
    int rc = json_parse_object(sub, sv->raw_len, &state_obj);
    if (rc == 0) state_from_object(&state_obj, s);
    free(sub);
    free(tmp);
    if (rc != 0) return -1;
    *seq = n;
    return 0;
}

/* -------------------------------------------------------------- file I/O */

static int read_file(const char *path, char *buf, size_t cap, size_t *len) {
    int fd = open(path, O_RDONLY | O_CLOEXEC);
    if (fd < 0) return -1;
    size_t off = 0;
    while (off + 1 < cap) {
        ssize_t n = read(fd, buf + off, cap - 1 - off);
        if (n < 0) {
            if (errno == EINTR) continue;
            close(fd);
            return -1;
        }
        if (n == 0) break;
        off += (size_t)n;
    }
    close(fd);
    buf[off] = '\0';
    if (len) *len = off;
    return 0;
}

static int fsync_dir(const char *dir) {
    int fd = open(dir, O_RDONLY | O_DIRECTORY | O_CLOEXEC);
    if (fd < 0) return -1;
    int rc = fsync(fd);
    close(fd);
    return rc;
}

/* Atomic replace: write a private temp file, flush it, rename it, then flush
 * the directory entry. A crash leaves the old or the new snapshot, never a
 * half-written one. */
static int write_atomic(const char *path, const char *data, size_t len) {
    char tmp[PATH_MAX];
    int n = snprintf(tmp, sizeof tmp, "%s.tmp.%ld", path, (long)getpid());
    if (n < 0 || (size_t)n >= sizeof tmp) return -1;

    int fd = open(tmp, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, SOCK_MODE);
    if (fd < 0) return -1;
    secure_fd_file(fd);
    int rc = 0;
    if (write_all(fd, data, len) < 0) rc = -1;
    if (rc == 0 && fsync(fd) < 0) rc = -1;
    close(fd);
    if (rc == 0 && rename(tmp, path) < 0) rc = -1;
    if (rc != 0) {
        unlink(tmp);
        return -1;
    }
    char dir[PATH_MAX];
    snprintf(dir, sizeof dir, "%s", path);
    char *slash = strrchr(dir, '/');
    if (slash) {
        *slash = '\0';
        (void)fsync_dir(dir);
    }
    return 0;
}

static int truncate_file(const char *path) {
    int fd = open(path, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, SOCK_MODE);
    if (fd < 0) return -1;
    secure_fd_file(fd);
    int rc = fsync(fd);
    close(fd);
    return rc;
}

static long long file_size(const char *path) {
    struct stat st;
    if (stat(path, &st) < 0) return 0;
    return (long long)st.st_size;
}

/* -------------------------------------------------------------- journal */

static int journal_checkpoint(void);

static int journal_load(void) {
    state_init(&g_state);
    g_seq = 0;
    g_entries = 0;
    g_had_state = 0;

    char *buf = malloc(MAX_STATE_JSON);
    if (!buf) return -1;

    size_t len = 0;
    if (read_file(g_snapshot_path, buf, MAX_STATE_JSON, &len) == 0) {
        long long seq;
        session_state st;
        if (envelope_parse(buf, len, &seq, &st) == 0) {
            g_state = st;
            g_seq = seq;
            g_had_state = 1;
        } else {
            logmsg("ignoring corrupt snapshot %s", g_snapshot_path);
        }
    }

    FILE *f = fopen(g_journal_path, "r");
    if (f) {
        char *line = NULL;
        size_t linecap = 0;
        ssize_t n;
        while ((n = getline(&line, &linecap, f)) >= 0) {
            if (n == 0 || (n == 1 && line[0] == '\n')) continue;
            g_entries++;
            long long seq;
            session_state st;
            if (envelope_parse(line, (size_t)n, &seq, &st) != 0) {
                logmsg("ignoring corrupt journal line");
                continue;
            }
            if (seq <= g_seq) continue;  /* already covered by snapshot */
            g_state = st;
            g_seq = seq;
            g_had_state = 1;
        }
        free(line);
        fclose(f);
    }

    free(buf);
    return g_had_state ? 0 : 1;
}

static int journal_append(void) {
    char *line = malloc(MAX_STATE_JSON);
    if (!line) return -1;
    long long seq = g_seq + 1;
    if (envelope_build(seq, &g_state, line, MAX_STATE_JSON) != 0) {
        free(line);
        return -1;
    }
    size_t len = strlen(line);

    int fd = open(g_journal_path,
                  O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, SOCK_MODE);
    if (fd < 0) {
        logmsg("open journal: %s", strerror(errno));
        free(line);
        return -1;
    }
    secure_fd_file(fd);
    int rc = 0;
    if (write_all(fd, line, len) < 0 || write_all(fd, "\n", 1) < 0)
        rc = -1;
    if (rc == 0 && fsync(fd) < 0) rc = -1;
    close(fd);
    free(line);
    if (rc != 0) {
        logmsg("append journal: %s", strerror(errno));
        return -1;
    }

    g_seq = seq;
    g_entries++;
    if (g_entries >= g_compact_after) return journal_checkpoint();
    return 0;
}

static int journal_checkpoint(void) {
    char *buf = malloc(MAX_STATE_JSON);
    if (!buf) return -1;
    long long seq = g_seq + 1;
    if (envelope_build(seq, &g_state, buf, MAX_STATE_JSON) != 0) {
        free(buf);
        return -1;
    }
    int rc = write_atomic(g_snapshot_path, buf, strlen(buf));
    free(buf);
    if (rc != 0) {
        logmsg("write snapshot: %s", strerror(errno));
        return -1;
    }
    if (truncate_file(g_journal_path) != 0) {
        /* The snapshot is already authoritative; stale journal records carry
         * a lower seq and will be ignored on load. Keep serving. */
        logmsg("truncate journal: %s", strerror(errno));
    }
    g_seq = seq;
    g_entries = 0;
    g_ticks_since_checkpoint = 0;
    return 0;
}

/* ------------------------------------------------------------- recovery */

static void recover_state(void) {
    long long now = now_ms();
    g_resumed_id = 0;
    g_closed_id = 0;
    g_close_at_ms = 0;
    g_restart_gap_ms = -1;

    long long gap = g_state.last_tick_ms > 0
                        ? now - g_state.last_tick_ms
                        : -1;
    g_restart_gap_ms = gap;

    /* Environment freshness is anchored to the last write, not to the last
     * app tick: a tracker can legitimately have no open session while the
     * lock/suspend/day-start state is still fresh. */
    long long env_gap = g_state.written_at_ms > 0
                            ? now - g_state.written_at_ms
                            : -1;

    if (g_state.current_session_id > 0) {
        if (gap >= 0 && gap <= RESUME_THRESHOLD_MS) {
            g_resumed_id = (int)g_state.current_session_id;
            logmsg("resuming session id=%d gap=%lldms",
                   g_resumed_id, gap);
        } else {
            long long close_at = g_state.last_tick_ms;
            if (close_at < g_state.session_started_at_ms)
                close_at = g_state.session_started_at_ms;
            if (close_at <= 0 || close_at > now) close_at = now;
            g_closed_id = (int)g_state.current_session_id;
            g_close_at_ms = close_at;
            logmsg("closing session id=%d at last tick (gap=%lldms)",
                   g_closed_id, gap);
            state_clear_current(&g_state);
            /* Keep the snapshot self-consistent: the session ended at the
             * last observation, so that is also the newest observed tick. */
            g_state.last_tick_ms = close_at;
        }
    }

    /* Live signals, not durable facts: a stale true would suppress tracking
     * until the matching unlock/resume arrives, which may never happen. */
    g_state.session_locked = 0;
    g_state.suspended = 0;
    if (!(env_gap >= 0 && env_gap <= ENV_FRESH_MS)) {
        g_state.consecutive_unknown_ticks = 0;
    }
    if (!(env_gap >= 0 && env_gap <= ENV_FRESH_MS) ||
        g_state.day_start_ms <= 0) {
        g_state.day_start_ms = local_midnight_ms(now);
    }

    g_state.written_at_ms = now;
    if (g_had_state || g_state.current_session_id > 0 ||
        g_state.day_start_ms > 0) {
        journal_checkpoint();
    }
}

/* -------------------------------------------------------------- status */

static void recovery_json(sbuf *b) {
    sb_puts(b, "\"restored\":");
    sb_puts(b, g_had_state ? "true" : "false");
    if (g_resumed_id > 0)
        sb_printf(b, ",\"resumed_session_id\":%d", g_resumed_id);
    else
        sb_puts(b, ",\"resumed_session_id\":null");
    if (g_closed_id > 0)
        sb_printf(b, ",\"closed_session_id\":%d,\"close_at_ms\":%lld",
                  g_closed_id, g_close_at_ms);
    else
        sb_puts(b, ",\"closed_session_id\":null,\"close_at_ms\":null");
    if (g_restart_gap_ms >= 0)
        sb_printf(b, ",\"restart_gap_ms\":%lld", g_restart_gap_ms);
    else
        sb_puts(b, ",\"restart_gap_ms\":null");
}

static void status_json(sbuf *b) {
    sb_puts(b, "{\"pid\":");
    sb_printf(b, "%ld", (long)getpid());
    sb_printf(b, ",\"uptime_ms\":%lld", now_ms() - g_started_at_ms);
    sb_puts(b, ",\"socket\":");
    sb_json_str(b, g_socket_path);
    sb_puts(b, ",\"state_dir\":");
    sb_json_str(b, g_state_dir);
    sb_puts(b, ",\"snapshot_path\":");
    sb_json_str(b, g_snapshot_path);
    sb_puts(b, ",\"journal_path\":");
    sb_json_str(b, g_journal_path);
    sb_printf(b, ",\"seq\":%lld,\"journal_entries\":%lld",
              g_seq, g_entries);
    sb_printf(b, ",\"compact_after\":%d", g_compact_after);
    sb_printf(b, ",\"snapshot_bytes\":%lld", file_size(g_snapshot_path));
    sb_printf(b, ",\"journal_bytes\":%lld", file_size(g_journal_path));
    sb_puts(b, ",\"recovery\":{");
    recovery_json(b);
    sb_puts(b, "},\"state\":");
    state_json(&g_state, b);
    sb_puts(b, "}");
}

static int print_status_stdout(void) {
    char *buf = malloc(MAX_RESPONSE);
    if (!buf) return 1;
    sbuf b;
    sb_init(&b, buf, MAX_RESPONSE);
    status_json(&b);
    if (b.overflow) {
        free(buf);
        return 1;
    }
    printf("%s\n", buf);
    free(buf);
    return 0;
}

/* ------------------------------------------------------------- handlers */

static int arg_ll(const jobject *o, const char *key, long long *out) {
    return json_get_ll(o, key, out);
}

static void handle_system(int fd, const char *method) {
    if (!strcmp(method, "ping")) {
        reply(fd, "ok pong");
        return;
    }
    if (!strcmp(method, "status")) {
        char *buf = malloc(MAX_RESPONSE);
        if (!buf) {
            reply(fd, "err out-of-memory");
            return;
        }
        sbuf b;
        sb_init(&b, buf, MAX_RESPONSE);
        status_json(&b);
        if (b.overflow) reply(fd, "err response-too-large");
        else reply(fd, "ok %s", buf);
        free(buf);
        return;
    }
    if (!strcmp(method, "shutdown")) {
        reply(fd, "ok {\"stopping\":true}");
        g_stop = 1;
        return;
    }
    reply(fd, "err unknown-method");
}

static void handle_session(int fd, const char *method, const char *payload) {
    jobject args;
    if (json_parse_object(payload, strlen(payload), &args) != 0) {
        reply(fd, "err invalid-json");
        return;
    }

    if (!strcmp(method, "status") || !strcmp(method, "restore")) {
        char *buf = malloc(MAX_RESPONSE);
        if (!buf) {
            reply(fd, "err out-of-memory");
            return;
        }
        sbuf b;
        sb_init(&b, buf, MAX_RESPONSE);
        if (!strcmp(method, "restore")) {
            sb_puts(&b, "{\"recovery\":{");
            recovery_json(&b);
            sb_puts(&b, "},\"state\":");
            state_json(&g_state, &b);
            sb_puts(&b, "}");
        } else {
            status_json(&b);
        }
        if (b.overflow) reply(fd, "err response-too-large");
        else reply(fd, "ok %s", buf);
        free(buf);
        return;
    }

    if (!strcmp(method, "begin")) {
        long long id = 0, at = 0, pid = 0, started = 0;
        char app[MAX_STRING] = "", title[MAX_STRING] = "";
        int idle = 0;
        if (arg_ll(&args, "id", &id) != 0 || id <= 0) {
            reply(fd, "err missing-argument:id");
            return;
        }
        if (json_get_str(&args, "app", app, sizeof app) != 0 || !app[0]) {
            reply(fd, "err missing-argument:app");
            return;
        }
        if (arg_ll(&args, "at_ms", &at) != 0 || at <= 0) {
            reply(fd, "err missing-argument:at_ms");
            return;
        }
        (void)json_get_str(&args, "title", title, sizeof title);
        (void)arg_ll(&args, "pid", &pid);
        (void)json_get_bool(&args, "idle", &idle);
        (void)arg_ll(&args, "started_at_ms", &started);

        if (g_state.current_session_id > 0 &&
            g_state.current_session_id != id) {
            reply(fd, "err session-already-open:%lld",
                  g_state.current_session_id);
            return;
        }

        /* Idempotent: the caller may repeat `begin` for the same id after a
         * worker restart, or to resynchronise after a fallback period. Never
         * move the original start time or an already newer tick backwards. */
        int same_session = g_state.current_session_id == id;
        if (same_session) {
            started = g_state.session_started_at_ms;
        } else if (started <= 0) {
            started = at;
        }

        g_state.current_session_id = id;
        snprintf(g_state.current_app, sizeof g_state.current_app, "%s", app);
        snprintf(g_state.current_title, sizeof g_state.current_title,
                 "%s", title);
        g_state.current_pid = pid > 0 ? pid : 0;
        g_state.current_idle = idle ? 1 : 0;
        g_state.session_started_at_ms = started;
        g_state.last_tick_ms = same_session && g_state.last_tick_ms > at
                                   ? g_state.last_tick_ms
                                   : at;
        if (g_state.last_idle_reported < 0)
            g_state.last_idle_reported = idle ? 1 : 0;
        g_state.written_at_ms = now_ms();
        if (journal_append() != 0) {
            reply(fd, "err journal-write-failed");
            return;
        }
        reply(fd, "ok {\"id\":%lld,\"started_at_ms\":%lld,"
                  "\"last_tick_ms\":%lld}",
              id, started, g_state.last_tick_ms);
        return;
    }

    if (!strcmp(method, "tick")) {
        long long at = 0, pid = 0;
        int idle = 0;
        char title[MAX_STRING];
        int have_title = json_get_str(&args, "title", title,
                                      sizeof title) == 0;
        int have_pid = arg_ll(&args, "pid", &pid) == 0;
        int have_idle = json_get_bool(&args, "idle", &idle) == 0;
        if (arg_ll(&args, "at_ms", &at) != 0 || at <= 0) {
            reply(fd, "err missing-argument:at_ms");
            return;
        }
        if (at > g_state.last_tick_ms) g_state.last_tick_ms = at;
        g_state.written_at_ms = at;
        if (g_state.current_session_id > 0) {
            if (have_title) {
                snprintf(g_state.current_title, sizeof g_state.current_title,
                         "%s", title);
            }
            if (have_pid) {
                g_state.current_pid = pid > 0 ? pid : 0;
            }
            if (have_idle) {
                g_state.current_idle = idle ? 1 : 0;
            }
        }

        g_ticks_since_checkpoint++;
        int checkpointed = 0;
        if (g_ticks_since_checkpoint >= TICKS_PER_CHECKPOINT) {
            checkpointed = journal_checkpoint() == 0;
        }
        reply(fd, "ok {\"last_tick_ms\":%lld,\"checkpointed\":%s}",
              g_state.last_tick_ms, checkpointed ? "true" : "false");
        return;
    }

    if (!strcmp(method, "close")) {
        long long at = 0, id = 0;
        int have_id = arg_ll(&args, "id", &id) == 0 && id > 0;
        if (arg_ll(&args, "at_ms", &at) != 0 || at <= 0) {
            reply(fd, "err missing-argument:at_ms");
            return;
        }
        if (g_state.current_session_id <= 0) {
            reply(fd, "ok {\"closed\":null}");
            return;
        }
        if (have_id && id != g_state.current_session_id) {
            reply(fd, "err not-current:%lld", g_state.current_session_id);
            return;
        }
        long long closed = g_state.current_session_id;
        long long started = g_state.session_started_at_ms;
        state_clear_current(&g_state);
        /* The close instant is the newest observed tick, so a snapshot left
         * without an open session still reports an honest boundary. */
        if (at > g_state.last_tick_ms) g_state.last_tick_ms = at;
        g_state.written_at_ms = at;
        if (journal_append() != 0) {
            reply(fd, "err journal-write-failed");
            return;
        }
        reply(fd, "ok {\"closed\":%lld,\"ended_at_ms\":%lld,"
                  "\"duration_ms\":%lld}",
              closed, at, at > started ? at - started : 0);
        return;
    }

    if (!strcmp(method, "env")) {
        int locked = 0, suspended = 0;
        long long day = 0, unknown = 0;
        int have_locked = json_get_bool(&args, "locked", &locked) == 0;
        int have_suspended =
            json_get_bool(&args, "suspended", &suspended) == 0;
        int have_day = arg_ll(&args, "day_start_ms", &day) == 0;
        int have_unknown =
            arg_ll(&args, "unknown_ticks", &unknown) == 0;
        if (!have_locked && !have_suspended && !have_day && !have_unknown) {
            reply(fd, "err missing-argument:env");
            return;
        }
        if (have_locked) g_state.session_locked = locked ? 1 : 0;
        if (have_suspended) g_state.suspended = suspended ? 1 : 0;
        if (have_day && day >= 0) g_state.day_start_ms = day;
        if (have_unknown && unknown >= 0)
            g_state.consecutive_unknown_ticks = (int)unknown;
        g_state.written_at_ms = now_ms();
        if (journal_append() != 0) {
            reply(fd, "err journal-write-failed");
            return;
        }
        reply(fd, "ok {\"locked\":%s,\"suspended\":%s,"
                  "\"day_start_ms\":%lld}",
              g_state.session_locked ? "true" : "false",
              g_state.suspended ? "true" : "false",
              g_state.day_start_ms);
        return;
    }

    if (!strcmp(method, "checkpoint") || !strcmp(method, "compact")) {
        g_state.written_at_ms = now_ms();
        if (journal_checkpoint() != 0) {
            reply(fd, "err journal-write-failed");
            return;
        }
        reply(fd, "ok {\"seq\":%lld,\"journal_entries\":%lld}",
              g_seq, g_entries);
        return;
    }

    reply(fd, "err unknown-method");
}

static void handle_client(int client) {
    struct timeval tv = { IO_TIMEOUT_SEC, 0 };
    setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof tv);
    setsockopt(client, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof tv);

    if (!peer_is_self(client)) {
        reply(client, "err unauthorized");
        return;
    }

    char line[MAX_REQUEST];
    ssize_t n = read_line(client, line, sizeof line);
    if (n <= 0) {
        reply(client, "err empty-request");
        return;
    }
    while (n > 0 && (line[n - 1] == '\n' || line[n - 1] == '\r'))
        line[--n] = '\0';
    if (n == 0) {
        reply(client, "err empty-request");
        return;
    }

    char *domain = line;
    char *sp = strchr(line, ' ');
    if (!sp) {
        reply(client, "err malformed: expected '<domain> <method>'");
        return;
    }
    *sp = '\0';
    char *method = sp + 1;
    while (*method == ' ') method++;
    char *payload = strchr(method, ' ');
    if (payload) {
        *payload++ = '\0';
        while (*payload == ' ') payload++;
    } else {
        payload = (char *)"{}";
    }

    if (!strcmp(domain, "system")) {
        handle_system(client, method);
    } else if (!strcmp(domain, "session")) {
        handle_session(client, method, payload);
    } else {
        reply(client, "err unknown-domain");
    }
}

/* ------------------------------------------------------------------ main */

static void usage(const char *prog) {
    fprintf(stderr,
        "usage: %s [options]\n"
        "\n"
        "  --runtime DIR        socket + lock directory\n"
        "                       (default $XDG_RUNTIME_DIR/screenguard/session)\n"
        "  --state-dir DIR      journal directory (default: --runtime)\n"
        "  --compact-after N    journal entries before a checkpoint (default %d)\n"
        "  --now-ms MS          testing: override wall-clock time\n"
        "  --check              load state, print status, exit (no socket)\n"
        "  --verbose            log lifecycle events\n"
        "  -h, --help           this text\n"
        "\n"
        "Takeover from the Dart journal: stop the Dart daemon, then run with\n"
        "  --runtime $XDG_RUNTIME_DIR/screenguard --state-dir $XDG_RUNTIME_DIR/screenguard\n"
        "so this worker reads and writes the canonical session files.\n",
        prog, DEFAULT_COMPACT_AFTER);
}

int main(int argc, char **argv) {
    const char *runtime = NULL;
    const char *state_dir = NULL;

    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--runtime") && i + 1 < argc) {
            runtime = argv[++i];
        } else if (!strcmp(argv[i], "--state-dir") && i + 1 < argc) {
            state_dir = argv[++i];
        } else if (!strcmp(argv[i], "--compact-after") && i + 1 < argc) {
            g_compact_after = atoi(argv[++i]);
            if (g_compact_after < 1) g_compact_after = 1;
        } else if (!strcmp(argv[i], "--now-ms") && i + 1 < argc) {
            g_now_override = atoll(argv[++i]);
        } else if (!strcmp(argv[i], "--check")) {
            /* handled after path resolution */
        } else if (!strcmp(argv[i], "--verbose")) {
            g_verbose = 1;
        } else if (!strcmp(argv[i], "-h") || !strcmp(argv[i], "--help")) {
            usage(argv[0]);
            return 0;
        } else {
            fprintf(stderr, "%s: unknown option %s\n", argv[0], argv[i]);
            usage(argv[0]);
            return 2;
        }
    }

    int check_only = 0;
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--check")) check_only = 1;
    }

    if (!runtime) {
        const char *xdg = getenv("XDG_RUNTIME_DIR");
        if (xdg && xdg[0])
            snprintf(g_runtime, sizeof g_runtime,
                     "%s/screenguard/session", xdg);
        else
            snprintf(g_runtime, sizeof g_runtime,
                     "/run/user/%d/screenguard/session", (int)getuid());
    } else {
        snprintf(g_runtime, sizeof g_runtime, "%s", runtime);
    }
    snprintf(g_state_dir, sizeof g_state_dir, "%s",
             state_dir && state_dir[0] ? state_dir : g_runtime);

    if (join_path(g_socket_path, sizeof g_socket_path,
                  g_runtime, "session.sock") != 0 ||
        join_path(g_lock_path, sizeof g_lock_path,
                  g_runtime, "session.lock") != 0 ||
        join_path(g_snapshot_path, sizeof g_snapshot_path,
                  g_state_dir, "session-state.json") != 0 ||
        join_path(g_journal_path, sizeof g_journal_path,
                  g_state_dir, "session-journal.jsonl") != 0) {
        fprintf(stderr, "digiwelld-session: runtime/state path too long\n");
        return 1;
    }

    g_started_at_ms = now_ms();

    if (ensure_private_dir(g_runtime) < 0) {
        fprintf(stderr, "digiwelld-session: cannot prepare runtime dir %s\n",
                g_runtime);
        return 1;
    }
    if (strcmp(g_state_dir, g_runtime) != 0 &&
        ensure_private_dir(g_state_dir) < 0) {
        fprintf(stderr, "digiwelld-session: cannot prepare state dir %s\n",
                g_state_dir);
        return 1;
    }

    if (journal_load() < 0) {
        fprintf(stderr, "digiwelld-session: cannot load journal\n");
        return 1;
    }

    if (check_only) {
        /* Recovery decisions are read-only here: do not rewrite the journal,
         * and do not clear the persisted state. */
        long long gap = g_state.last_tick_ms > 0
                            ? now_ms() - g_state.last_tick_ms
                            : -1;
        g_restart_gap_ms = gap;
        if (g_state.current_session_id > 0) {
            if (gap >= 0 && gap <= RESUME_THRESHOLD_MS) {
                g_resumed_id = (int)g_state.current_session_id;
            } else {
                long long close_at = g_state.last_tick_ms;
                if (close_at < g_state.session_started_at_ms)
                    close_at = g_state.session_started_at_ms;
                if (close_at <= 0 || close_at > now_ms()) close_at = now_ms();
                g_closed_id = (int)g_state.current_session_id;
                g_close_at_ms = close_at;
            }
        }
        return print_status_stdout();
    }

    g_lock_fd = lock_exclusive(g_lock_path);
    if (g_lock_fd == -2) {
        fprintf(stderr,
                "digiwelld-session: another session worker already owns %s\n",
                g_lock_path);
        return 1;
    }
    if (g_lock_fd < 0) {
        fprintf(stderr, "digiwelld-session: cannot lock %s: %s\n",
                g_lock_path, strerror(errno));
        return 1;
    }

    recover_state();

    struct sigaction sa;
    memset(&sa, 0, sizeof sa);
    sa.sa_handler = on_signal;
    sigaction(SIGTERM, &sa, NULL);
    sigaction(SIGINT, &sa, NULL);
    signal(SIGPIPE, SIG_IGN);

    g_listen_fd = listen_unix(g_socket_path);
    if (g_listen_fd < 0) {
        fprintf(stderr, "digiwelld-session: cannot listen on %s\n",
                g_socket_path);
        return 1;
    }
    logmsg("ready pid=%ld socket=%s state=%s resumed=%d closed=%d gap=%lld",
           (long)getpid(), g_socket_path, g_state_dir,
           g_resumed_id, g_closed_id, g_restart_gap_ms);

    while (!g_stop) {
        struct pollfd pfd = { g_listen_fd, POLLIN, 0 };
        int pr = poll(&pfd, 1, 1000);
        if (pr < 0) {
            if (errno == EINTR) continue;
            logmsg("poll: %s", strerror(errno));
            g_exit_code = 1;
            break;
        }
        if (pr == 0 || !(pfd.revents & POLLIN)) continue;

        int client = accept4(g_listen_fd, NULL, NULL, SOCK_CLOEXEC);
        if (client < 0) {
            if (errno == EINTR) continue;
            logmsg("accept: %s", strerror(errno));
            continue;
        }
        handle_client(client);
        close(client);
    }

    logmsg("shutting down");
    /* A clean stop is a snapshot boundary, but it does not invent a database
     * close: the caller owns that transition. An open session stays in the
     * journal so the next start can adopt or close it honestly. */
    g_state.written_at_ms = now_ms();
    (void)journal_checkpoint();
    close(g_listen_fd);
    g_listen_fd = -1;
    unlink(g_socket_path);
    if (g_lock_fd >= 0) {
        flock(g_lock_fd, LOCK_UN);
        close(g_lock_fd);
    }
    return g_exit_code;
}
