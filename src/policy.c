/*
 * digiwelld-policy - policy intent worker for ScreenGuard.
 *
 * This is the third worker of the digiwelld migration. It owns the `policy`
 * domain: app limits, the distracting-app list, focus/Pomodoro state, the
 * daily goal, and every notification/sound preference. Every method mirrors
 * DatabaseService one-for-one, including defaults, clamps and the exact
 * focus-session transition rules, so moving a caller from the Dart dispatch
 * to this worker cannot change behaviour.
 *
 * What it deliberately does NOT do:
 *
 *   * observe windows or idle time    -> Dart tracker / future enforcement
 *   * apply limits or kill apps       -> digiwelld-enforce
 *   * answer "what happened"          -> digiwelld-usage
 *
 * Focus state is the one sharp edge. getActiveFocusState() is not a pure read:
 * it completes an expired phase, starts a break or the next cycle, and writes
 * focus_sessions. This worker is therefore the ONLY process that advances the
 * state machine. The Dart tracker reads through SCREENGUARD_POLICY_SOCKET
 * instead of calling its own DatabaseService, and the GUI reaches this worker
 * through digiwelld's routing table. Without that rule two processes could
 * insert the same cycle twice.
 *
 * SQLite boundary during the migration:
 *
 *   digiwelld-policy  owns policy writes (settings, limits, focus tables)
 *   Dart daemon       still owns session/event writes until digiwelld-store
 *
 * Both use WAL and a 5s busy timeout, exactly like DatabaseService.init().
 *
 * Protocol (same envelope as digiwelld, digiwelld-session, digiwelld-usage):
 *
 *   request   <domain> <method> <json-object>
 *   response  ok <json>
 *             err <reason>
 *
 * Domains: system, policy. One request per connection.
 *
 * Build:
 *   cc -O2 -Wall -Wextra -std=c99 -o digiwelld-policy src/policy.c -lsqlite3
 */

#define _GNU_SOURCE
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
#include <sqlite3.h>

#define MAX_REQUEST      65536
#define MAX_RESPONSE     65536
#define MAX_JSON_PAIRS   32
#define MAX_STRING       1024
#define MAX_ALIASES      32
#define BACKLOG          16
#define IO_TIMEOUT_SEC   3
#define SOCK_MODE        0600
#define DIR_MODE         0700
static volatile sig_atomic_t g_stop = 0;

static char g_runtime[PATH_MAX];
static char g_socket_path[PATH_MAX];
static char g_lock_path[PATH_MAX];
static char g_db_path[PATH_MAX];

static int g_listen_fd = -1;
static int g_lock_fd = -1;
static int g_verbose = 0;
static long long g_started_at = 0;

static sqlite3 *g_db = NULL;

static int scalar_ll(const char *sql, const long long *params, int nparams,
                     long long *out);

/* ------------------------------------------------------------------ utils */

static long long wall_ms(void) {
    struct timespec ts;
    clock_gettime(CLOCK_REALTIME, &ts);
    return (long long)ts.tv_sec * 1000LL + ts.tv_nsec / 1000000LL;
}

static void logmsg(const char *fmt, ...) {
    va_list ap;
    char msg[2048];
    char stamp[32];
    time_t t = time(NULL);
    struct tm tm;
    localtime_r(&t, &tm);
    strftime(stamp, sizeof stamp, "%H:%M:%S", &tm);

    va_start(ap, fmt);
    vsnprintf(msg, sizeof msg, fmt, ap);
    va_end(ap);

    fprintf(stderr, "[digiwelld-policy %s] %s\n", stamp, msg);
    fflush(stderr);
}

static void on_signal(int sig) {
    (void)sig;
    g_stop = 1;
}

static int mkdir_private(const char *path) {
    if (mkdir(path, DIR_MODE) == 0) {
        chmod(path, DIR_MODE);
        return 0;
    }
    if (errno == EEXIST) {
        struct stat st;
        if (stat(path, &st) == 0 && S_ISDIR(st.st_mode)) {
            if ((st.st_mode & (S_IRWXG | S_IRWXO)) != 0) {
                logmsg("runtime dir %s has group/other bits; fixing to %04o",
                       path, DIR_MODE);
                chmod(path, DIR_MODE);
            }
            return 0;
        }
    }
    return -1;
}

/* Exclusive, non-blocking lock. Returns fd on success, -1 on error,
 * -2 if somebody else already holds it. */
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
        logmsg("listen %s: %s", path, strerror(errno));
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

/* ------------------------------------------------------------------ sqlite */

static int db_open(void) {
    if (g_db) return 0;
    sqlite3 *db = NULL;
    int rc = sqlite3_open_v2(g_db_path, &db,
                             SQLITE_OPEN_READWRITE | SQLITE_OPEN_NOMUTEX, NULL);
    if (rc != SQLITE_OK) {
        if (db) sqlite3_close(db);
        return -1;
    }
    sqlite3_busy_timeout(db, 5000);
    /* Same pragmas as DatabaseService.init(). WAL lets the daemon keep
     * writing sessions while policy writes here; NORMAL is the same
     * durability choice the app already made. */
    if (sqlite3_exec(db,
            "PRAGMA journal_mode=WAL;"
            "PRAGMA synchronous=NORMAL;", NULL, NULL, NULL) != SQLITE_OK) {
        sqlite3_close(db);
        return -1;
    }
    g_db = db;
    return 0;
}

/* 1 = ready, 0 = database exists but the Dart daemon has not created the
 * schema yet (normal on a first boot), -1 = cannot open the file at all.
 * The distinction matters: the first case heals by itself. */
static int db_ready(void) {
    if (db_open() != 0) return -1;
    long long n = 0;
    if (scalar_ll("SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND "
                  "name IN ('settings','app_limits','distracting_apps',"
                  "'focus_sessions','active_focus_state');", NULL, 0, &n) != 0)
        return 0;
    return n == 5 ? 1 : 0;
}

static int db_prepare(const char *sql, sqlite3_stmt **st) {
    if (sqlite3_prepare_v2(g_db, sql, -1, st, NULL) != SQLITE_OK) {
        if (g_verbose) {
            logmsg("prepare failed: %s (%s)", sqlite3_errmsg(g_db), sql);
        }
        return -1;
    }
    return 0;
}

/* Reply used when a query could not run. Distinguishes "no database yet"
 * (normal on a first boot) from a real SQL error. */
static int reply_db_error(int fd) {
    int code = g_db ? sqlite3_extended_errcode(g_db) : SQLITE_CANTOPEN;
    if (!g_db || code == SQLITE_CANTOPEN) {
        reply(fd, "err database-unavailable");
    } else if (code == SQLITE_BUSY || code == SQLITE_LOCKED) {
        reply(fd, "err database-busy");
    } else if (code == SQLITE_ERROR &&
               strstr(sqlite3_errmsg(g_db), "no such table") != NULL) {
        reply(fd, "err database-not-ready");
    } else {
        reply(fd, "err database-error");
    }
    return -1;
}

/* --------------------------------------------------------------- JSON I/O */

typedef enum { JV_NULL, JV_BOOL, JV_NUM, JV_STR, JV_OBJ, JV_ARR } jv_type;

typedef struct {
    jv_type     type;
    int         boolean;
    long long   num;
    char        str[MAX_STRING];
    const char *raw;      /* JV_OBJ / JV_ARR: points into the request */
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

static int jp_string(jparser *jp, char *out, size_t cap);

static int jp_hexval(int c) {
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    return -1;
}

static int jp_utf8_put(char *out, size_t cap, size_t *len, unsigned cp) {
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
        int h = jp_hexval((unsigned char)jp->p[i]);
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
                if (jp_utf8_put(out, cap, &len, cp) != 0) return -1;
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

static int jp_skip_value(jparser *jp);

static int jp_skip_container(jparser *jp) {
    char open = *jp->p;
    char close = open == '{' ? '}' : ']';
    jp->p++;
    jp_ws(jp);
    if (jp->p < jp->end && *jp->p == close) {
        jp->p++;
        return 0;
    }
    while (1) {
        jp_ws(jp);
        if (open == '{') {
            char key[MAX_STRING + 64];
            if (jp_string(jp, key, sizeof key) != 0) return -1;
            jp_ws(jp);
            if (jp->p >= jp->end || *jp->p != ':') return -1;
            jp->p++;
        }
        if (jp_skip_value(jp) != 0) return -1;
        jp_ws(jp);
        if (jp->p >= jp->end) return -1;
        if (*jp->p == ',') {
            jp->p++;
            continue;
        }
        if (*jp->p == close) {
            jp->p++;
            return 0;
        }
        return -1;
    }
}

static int jp_skip_value(jparser *jp) {
    jp_ws(jp);
    if (jp->p >= jp->end) return -1;
    char c = *jp->p;
    if (c == '"') {
        char scratch[MAX_STRING];
        return jp_string(jp, scratch, sizeof scratch);
    }
    if (c == '{' || c == '[') return jp_skip_container(jp);
    if (jp->end - jp->p >= 4 && !memcmp(jp->p, "true", 4)) {
        jp->p += 4;
        return 0;
    }
    if (jp->end - jp->p >= 5 && !memcmp(jp->p, "false", 5)) {
        jp->p += 5;
        return 0;
    }
    if (jp->end - jp->p >= 4 && !memcmp(jp->p, "null", 4)) {
        jp->p += 4;
        return 0;
    }
    if (c == '-' || (c >= '0' && c <= '9')) {
        char *endp = NULL;
        errno = 0;
        (void)strtod(jp->p, &endp);
        if (endp == jp->p || errno == ERANGE || endp > jp->end) return -1;
        jp->p = endp;
        return 0;
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
    if (c == '[') {
        const char *start = jp->p;
        if (jp_skip_container(jp) != 0) return -1;
        v->type = JV_ARR;
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
        if (endp == jp->p || errno == ERANGE || endp > jp->end) return -1;
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

/* Decode ["a","b"] into a fixed array. Returns the count, or -1 on a
 * malformed array. An absent key is not an error (count stays 0). */
static int json_get_aliases(const jobject *obj, const char *key,
                            char out[][MAX_STRING], int max) {
    const jvalue *v = json_get(obj, key);
    if (!v || v->type == JV_NULL) return 0;
    if (v->type != JV_ARR) return -1;

    jparser jp = { v->raw, v->raw + v->raw_len };
    jp_ws(&jp);
    if (jp.p >= jp.end || *jp.p != '[') return -1;
    jp.p++;
    jp_ws(&jp);
    int count = 0;
    if (jp.p < jp.end && *jp.p == ']') return 0;
    while (1) {
        if (count >= max) return -1;
        if (jp_string(&jp, out[count], MAX_STRING) != 0) return -1;
        count++;
        jp_ws(&jp);
        if (jp.p >= jp.end) return -1;
        if (*jp.p == ',') {
            jp.p++;
            jp_ws(&jp);
            continue;
        }
        if (*jp.p == ']') return count;
        return -1;
    }
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

static void sb_col_text(sbuf *b, sqlite3_stmt *st, int col) {
    if (sqlite3_column_type(st, col) == SQLITE_NULL) {
        sb_puts(b, "null");
        return;
    }
    const unsigned char *text = sqlite3_column_text(st, col);
    sb_json_str(b, text ? (const char *)text : "");
}

static void sb_col_int(sbuf *b, sqlite3_stmt *st, int col) {
    if (sqlite3_column_type(st, col) == SQLITE_NULL)
        sb_puts(b, "null");
    else
        sb_printf(b, "%lld", (long long)sqlite3_column_int64(st, col));
}

static int scalar_ll(const char *sql, const long long *params, int nparams,
                     long long *out) {
    sqlite3_stmt *st = NULL;
    if (db_prepare(sql, &st) != 0) return -1;
    for (int i = 0; i < nparams; i++) {
        sqlite3_bind_int64(st, i + 1, params[i]);
    }
    int rc = sqlite3_step(st);
    if (rc != SQLITE_ROW) {
        sqlite3_finalize(st);
        return -1;
    }
    *out = sqlite3_column_int64(st, 0);
    sqlite3_finalize(st);
    return 0;
}


/* ------------------------------------------------------------------ policy */
/*
 * The policy worker owns the `policy` domain: limits, the distracting-app
 * list, focus/Pomodoro state, goals and every notification/sound preference.
 * It is the only process allowed to ADVANCE the focus state machine. The Dart
 * tracker reads it through RUNTIME/policy.sock (SCREENGUARD_POLICY_SOCKET),
 * and the GUI reaches it through digiwelld's routing table. That matters:
 * getActiveFocusState() is not a pure read, it completes a phase and starts
 * the next one, so two processes advancing it would double-insert sessions.
 */

static long long g_writes = 0;

/* ------------------------------------------------------------- settings */

static int setting_get(const char *key, const char *dflt, char *out, size_t cap) {
    sqlite3_stmt *st = NULL;
    if (db_prepare("SELECT value FROM settings WHERE key = ?;", &st) != 0)
        return -1;
    sqlite3_bind_text(st, 1, key, -1, SQLITE_STATIC);
    int rc = sqlite3_step(st);
    if (rc == SQLITE_ROW) {
        if (sqlite3_column_type(st, 0) == SQLITE_NULL) {
            snprintf(out, cap, "%s", dflt);
        } else {
            const unsigned char *v = sqlite3_column_text(st, 0);
            snprintf(out, cap, "%s", v ? (const char *)v : "");
        }
    } else if (rc == SQLITE_DONE) {
        snprintf(out, cap, "%s", dflt);
    } else {
        sqlite3_finalize(st);
        return -1;
    }
    sqlite3_finalize(st);
    return 0;
}

static int setting_set(const char *key, const char *value) {
    sqlite3_stmt *st = NULL;
    if (db_prepare("INSERT INTO settings (key, value) VALUES (?, ?) "
                   "ON CONFLICT(key) DO UPDATE SET value = excluded.value;",
                   &st) != 0)
        return -1;
    sqlite3_bind_text(st, 1, key, -1, SQLITE_STATIC);
    sqlite3_bind_text(st, 2, value, -1, SQLITE_STATIC);
    int rc = sqlite3_step(st);
    sqlite3_finalize(st);
    if (rc != SQLITE_DONE) return -1;
    g_writes++;
    return 0;
}

static int setting_delete(const char *key) {
    sqlite3_stmt *st = NULL;
    if (db_prepare("DELETE FROM settings WHERE key = ?;", &st) != 0) return -1;
    sqlite3_bind_text(st, 1, key, -1, SQLITE_STATIC);
    int rc = sqlite3_step(st);
    sqlite3_finalize(st);
    if (rc != SQLITE_DONE) return -1;
    g_writes++;
    return 0;
}

static int setting_is(const char *key, const char *dflt) {
    char v[MAX_STRING];
    if (setting_get(key, dflt, v, sizeof v) != 0) return 0;
    return !strcmp(v, "1");
}

/* Strict base-10 parse, matching Dart's int.tryParse. */
static int parse_ll_strict(const char *s, long long *out) {
    if (!s || !*s) return -1;
    const char *p = s;
    if (*p == '+' || *p == '-') p++;
    if (!*p) return -1;
    for (const char *q = p; *q; q++) {
        if (*q < '0' || *q > '9') return -1;
    }
    errno = 0;
    char *end = NULL;
    long long v = strtoll(s, &end, 10);
    if (errno == ERANGE || !end || *end) return -1;
    *out = v;
    return 0;
}

static long long setting_ll(const char *key, long long dflt) {
    char v[MAX_STRING];
    long long n;
    if (setting_get(key, "", v, sizeof v) != 0) return dflt;
    return parse_ll_strict(v, &n) == 0 ? n : dflt;
}

static int begin_immediate(void) {
    return sqlite3_exec(g_db, "BEGIN IMMEDIATE;", NULL, NULL, NULL) == SQLITE_OK
               ? 0
               : -1;
}

static void end_txn(int commit) {
    sqlite3_exec(g_db, commit ? "COMMIT;" : "ROLLBACK;", NULL, NULL, NULL);
}

/* ---------------------------------------------------------- focus state */

typedef struct {
    int present;
    long long id;
    long long end_time_ms;
    long long duration_minutes;
    int paused_null;
    long long paused;
    int remaining_null;
    long long remaining;
    int cycle_null;
    long long cycle;
    int total_null;
    long long total;
    int break_null;
    long long is_break;
    int break_dur_null;
    long long break_dur;
} focus_state;

static long long fs_paused(const focus_state *s) {
    return s->paused_null ? 0 : s->paused;
}

static long long fs_cycle(const focus_state *s) {
    return s->cycle_null ? 1 : s->cycle;
}

static long long fs_total(const focus_state *s) {
    return s->total_null ? 1 : s->total;
}

static long long fs_break(const focus_state *s) {
    return s->break_null ? 0 : s->is_break;
}

static long long fs_break_dur(const focus_state *s) {
    return s->break_dur_null ? 5 : s->break_dur;
}

/* 1 = row, 0 = none, -1 = SQL error. NULLs stay NULL so the state machine can
 * apply the same fallbacks Dart applies and the JSON can report them as null. */
static int load_focus(focus_state *s) {
    memset(s, 0, sizeof *s);
    sqlite3_stmt *st = NULL;
    if (db_prepare("SELECT id, end_time_ms, duration_minutes, is_paused, "
                   "remaining_seconds, current_cycle, total_cycles, is_break, "
                   "break_duration_minutes FROM active_focus_state WHERE id = 1;",
                   &st) != 0)
        return -1;
    int rc = sqlite3_step(st);
    if (rc == SQLITE_DONE) {
        sqlite3_finalize(st);
        return 0;
    }
    if (rc != SQLITE_ROW) {
        sqlite3_finalize(st);
        return -1;
    }
    s->present = 1;
    s->id = sqlite3_column_int64(st, 0);
    s->end_time_ms = sqlite3_column_int64(st, 1);
    s->duration_minutes = sqlite3_column_int64(st, 2);
    s->paused_null = sqlite3_column_type(st, 3) == SQLITE_NULL;
    s->paused = sqlite3_column_int64(st, 3);
    s->remaining_null = sqlite3_column_type(st, 4) == SQLITE_NULL;
    s->remaining = sqlite3_column_int64(st, 4);
    s->cycle_null = sqlite3_column_type(st, 5) == SQLITE_NULL;
    s->cycle = sqlite3_column_int64(st, 5);
    s->total_null = sqlite3_column_type(st, 6) == SQLITE_NULL;
    s->total = sqlite3_column_int64(st, 6);
    s->break_null = sqlite3_column_type(st, 7) == SQLITE_NULL;
    s->is_break = sqlite3_column_int64(st, 7);
    s->break_dur_null = sqlite3_column_type(st, 8) == SQLITE_NULL;
    s->break_dur = sqlite3_column_int64(st, 8);
    sqlite3_finalize(st);
    return 1;
}

static void emit_focus(sbuf *b, const focus_state *s) {
    sb_puts(b, "{\"id\":");
    sb_printf(b, "%lld", s->id);
    sb_puts(b, ",\"end_time_ms\":");
    sb_printf(b, "%lld", s->end_time_ms);
    sb_puts(b, ",\"duration_minutes\":");
    sb_printf(b, "%lld", s->duration_minutes);
    sb_puts(b, ",\"is_paused\":");
    if (s->paused_null) sb_puts(b, "null"); else sb_printf(b, "%lld", s->paused);
    sb_puts(b, ",\"remaining_seconds\":");
    if (s->remaining_null) sb_puts(b, "null");
    else sb_printf(b, "%lld", s->remaining);
    sb_puts(b, ",\"current_cycle\":");
    if (s->cycle_null) sb_puts(b, "null"); else sb_printf(b, "%lld", s->cycle);
    sb_puts(b, ",\"total_cycles\":");
    if (s->total_null) sb_puts(b, "null"); else sb_printf(b, "%lld", s->total);
    sb_puts(b, ",\"is_break\":");
    if (s->break_null) sb_puts(b, "null"); else sb_printf(b, "%lld", s->is_break);
    sb_puts(b, ",\"break_duration_minutes\":");
    if (s->break_dur_null) sb_puts(b, "null");
    else sb_printf(b, "%lld", s->break_dur);
    sb_putc(b, '}');
}

/* Set the active row for the next phase and reload it so the reply is exactly
 * what a fresh SELECT would return. */
static int update_focus_next(long long end_ms, long long remaining_sec,
                             long long is_break, long long cycle) {
    sqlite3_stmt *st = NULL;
    if (db_prepare("UPDATE active_focus_state SET is_break = ?, "
                   "current_cycle = ?, end_time_ms = ?, remaining_seconds = ? "
                   "WHERE id = 1;", &st) != 0)
        return -1;
    sqlite3_bind_int64(st, 1, is_break);
    sqlite3_bind_int64(st, 2, cycle);
    sqlite3_bind_int64(st, 3, end_ms);
    sqlite3_bind_int64(st, 4, remaining_sec);
    int rc = sqlite3_step(st);
    sqlite3_finalize(st);
    if (rc != SQLITE_DONE) return -1;
    g_writes++;
    return 0;
}

static int insert_focus_session(long long at_ms, long long minutes) {
    sqlite3_stmt *st = NULL;
    if (db_prepare("INSERT INTO focus_sessions "
                   "(started_at, duration_minutes, completed) VALUES (?, ?, 0);",
                   &st) != 0)
        return -1;
    sqlite3_bind_int64(st, 1, at_ms);
    sqlite3_bind_int64(st, 2, minutes);
    int rc = sqlite3_step(st);
    sqlite3_finalize(st);
    if (rc != SQLITE_DONE) return -1;
    g_writes++;
    return 0;
}

static int complete_focus_row(long long ended_at, long long minutes) {
    sqlite3_stmt *st = NULL;
    if (db_prepare("UPDATE focus_sessions SET ended_at = ?, completed = 1 "
                   "WHERE ended_at IS NULL AND duration_minutes = ?;", &st) != 0)
        return -1;
    sqlite3_bind_int64(st, 1, ended_at);
    sqlite3_bind_int64(st, 2, minutes);
    int rc = sqlite3_step(st);
    sqlite3_finalize(st);
    if (rc != SQLITE_DONE) return -1;
    g_writes++;
    return 0;
}

static int delete_focus_state(void) {
    sqlite3_exec(g_db, "DELETE FROM active_focus_state WHERE id = 1;",
                 NULL, NULL, NULL);
    g_writes++;
    return 0;
}

static int reply_focus(int fd, const focus_state *s) {
    char buf[MAX_RESPONSE];
    sbuf b;
    sb_init(&b, buf, sizeof buf);
    emit_focus(&b, s);
    if (b.overflow) {
        reply(fd, "err response-too-large");
        return -1;
    }
    reply(fd, "ok %s", b.buf);
    return 0;
}

/* ---------------------------------------------------------- policy methods */

static int ok_null(int fd) {
    reply(fd, "ok null");
    return 0;
}

static int reply_bool(int fd, int value) {
    reply(fd, "ok %s", value ? "true" : "false");
    return 0;
}

static int reply_string(int fd, const char *value) {
    char buf[MAX_RESPONSE];
    sbuf b;
    sb_init(&b, buf, sizeof buf);
    sb_json_str(&b, value);
    if (b.overflow) {
        reply(fd, "err response-too-large");
        return -1;
    }
    reply(fd, "ok %s", b.buf);
    return 0;
}

static int policy_get_app_limit(int fd, const jobject *args) {
    char app[MAX_STRING];
    if (json_get_str(args, "app", app, sizeof app) != 0) {
        reply(fd, "err missing-argument:app");
        return -1;
    }
    char aliases[MAX_ALIASES][MAX_STRING];
    int na = json_get_aliases(args, "aliases", aliases, MAX_ALIASES);
    if (na < 0) {
        reply(fd, "err invalid-argument:aliases");
        return -1;
    }

    const char *names[1 + MAX_ALIASES];
    int count = 0;
    names[count++] = app;
    for (int i = 0; i < na; i++) {
        int dup = 0;
        for (int j = 0; j < count; j++) {
            if (!strcmp(names[j], aliases[i])) dup = 1;
        }
        if (!dup) names[count++] = aliases[i];
    }

    for (int i = 0; i < count; i++) {
        sqlite3_stmt *st = NULL;
        if (db_prepare("SELECT app, limit_ms, temp_extension_ms, enabled "
                       "FROM app_limits WHERE app = ?;", &st) != 0)
            return reply_db_error(fd);
        sqlite3_bind_text(st, 1, names[i], -1, SQLITE_STATIC);
        int rc = sqlite3_step(st);
        if (rc == SQLITE_ROW) {
            char buf[MAX_RESPONSE];
            sbuf b;
            sb_init(&b, buf, sizeof buf);
            sb_puts(&b, "{\"app\":");
            sb_col_text(&b, st, 0);
            sb_puts(&b, ",\"limit_ms\":");
            sb_col_int(&b, st, 1);
            sb_puts(&b, ",\"temp_extension_ms\":");
            sb_col_int(&b, st, 2);
            sb_puts(&b, ",\"enabled\":");
            sb_col_int(&b, st, 3);
            sb_putc(&b, '}');
            sqlite3_finalize(st);
            if (b.overflow) {
                reply(fd, "err response-too-large");
                return -1;
            }
            reply(fd, "ok %s", b.buf);
            return 0;
        }
        sqlite3_finalize(st);
        if (rc != SQLITE_DONE) return reply_db_error(fd);
    }
    reply(fd, "ok null");
    return 0;
}

static int policy_set_app_limit(int fd, const jobject *args) {
    char app[MAX_STRING];
    long long limit_ms;
    if (json_get_str(args, "app", app, sizeof app) != 0) {
        reply(fd, "err missing-argument:app");
        return -1;
    }
    if (json_get_ll(args, "limitMs", &limit_ms) != 0) {
        reply(fd, "err missing-argument:limitMs");
        return -1;
    }
    long long enabled = 1;
    const jvalue *v = json_get(args, "enabled");
    if (v && v->type == JV_BOOL) enabled = v->boolean;
    else if (v && v->type == JV_NUM) enabled = v->num ? 1 : 0;

    sqlite3_stmt *st = NULL;
    if (db_prepare("INSERT INTO app_limits (app, limit_ms, temp_extension_ms, "
                   "enabled) VALUES (?, ?, 0, ?) ON CONFLICT(app) DO UPDATE "
                   "SET limit_ms = ?, enabled = ?;", &st) != 0)
        return reply_db_error(fd);
    sqlite3_bind_text(st, 1, app, -1, SQLITE_STATIC);
    sqlite3_bind_int64(st, 2, limit_ms);
    sqlite3_bind_int64(st, 3, enabled);
    sqlite3_bind_int64(st, 4, limit_ms);
    sqlite3_bind_int64(st, 5, enabled);
    int rc = sqlite3_step(st);
    sqlite3_finalize(st);
    if (rc != SQLITE_DONE) return reply_db_error(fd);
    g_writes++;
    return ok_null(fd);
}

static int policy_add_temp_extension(int fd, const jobject *args) {
    char app[MAX_STRING];
    long long ms;
    if (json_get_str(args, "app", app, sizeof app) != 0) {
        reply(fd, "err missing-argument:app");
        return -1;
    }
    if (json_get_ll(args, "extensionMs", &ms) != 0) {
        reply(fd, "err missing-argument:extensionMs");
        return -1;
    }
    sqlite3_stmt *st = NULL;
    if (db_prepare("UPDATE app_limits SET temp_extension_ms = "
                   "temp_extension_ms + ? WHERE app = ?;", &st) != 0)
        return reply_db_error(fd);
    sqlite3_bind_int64(st, 1, ms);
    sqlite3_bind_text(st, 2, app, -1, SQLITE_STATIC);
    int rc = sqlite3_step(st);
    sqlite3_finalize(st);
    if (rc != SQLITE_DONE) return reply_db_error(fd);
    g_writes++;
    return ok_null(fd);
}

static int policy_delete_app_limit(int fd, const jobject *args) {
    char app[MAX_STRING];
    if (json_get_str(args, "app", app, sizeof app) != 0) {
        reply(fd, "err missing-argument:app");
        return -1;
    }
    sqlite3_stmt *st = NULL;
    if (db_prepare("DELETE FROM app_limits WHERE app = ?;", &st) != 0)
        return reply_db_error(fd);
    sqlite3_bind_text(st, 1, app, -1, SQLITE_STATIC);
    int rc = sqlite3_step(st);
    sqlite3_finalize(st);
    if (rc != SQLITE_DONE) return reply_db_error(fd);
    g_writes++;
    return ok_null(fd);
}

static int policy_distracting_apps(int fd) {
    sqlite3_stmt *st = NULL;
    if (db_prepare("SELECT app FROM distracting_apps;", &st) != 0)
        return reply_db_error(fd);
    char buf[MAX_RESPONSE];
    sbuf b;
    sb_init(&b, buf, sizeof buf);
    sb_puts(&b, "[");
    int first = 1;
    int rc;
    while ((rc = sqlite3_step(st)) == SQLITE_ROW) {
        if (!first) sb_puts(&b, ",");
        sb_col_text(&b, st, 0);
        first = 0;
    }
    sqlite3_finalize(st);
    if (rc != SQLITE_DONE) return reply_db_error(fd);
    sb_puts(&b, "]");
    if (b.overflow) {
        reply(fd, "err response-too-large");
        return -1;
    }
    reply(fd, "ok %s", b.buf);
    return 0;
}

static int policy_toggle_distracting(int fd, const jobject *args) {
    char app[MAX_STRING];
    if (json_get_str(args, "app", app, sizeof app) != 0) {
        reply(fd, "err missing-argument:app");
        return -1;
    }
    sqlite3_stmt *st = NULL;
    if (db_prepare("SELECT app FROM distracting_apps WHERE app = ?;", &st) != 0)
        return reply_db_error(fd);
    sqlite3_bind_text(st, 1, app, -1, SQLITE_STATIC);
    int rc = sqlite3_step(st);
    sqlite3_finalize(st);
    if (rc != SQLITE_ROW && rc != SQLITE_DONE) return reply_db_error(fd);

    const char *sql = rc == SQLITE_ROW
        ? "DELETE FROM distracting_apps WHERE app = ?;"
        : "INSERT INTO distracting_apps (app) VALUES (?);";
    st = NULL;
    if (db_prepare(sql, &st) != 0) return reply_db_error(fd);
    sqlite3_bind_text(st, 1, app, -1, SQLITE_STATIC);
    rc = sqlite3_step(st);
    sqlite3_finalize(st);
    if (rc != SQLITE_DONE) return reply_db_error(fd);
    g_writes++;
    return ok_null(fd);
}

static int policy_is_distracting(int fd, const jobject *args) {
    char app[MAX_STRING];
    if (json_get_str(args, "app", app, sizeof app) != 0) {
        reply(fd, "err missing-argument:app");
        return -1;
    }
    char aliases[MAX_ALIASES][MAX_STRING];
    int na = json_get_aliases(args, "aliases", aliases, MAX_ALIASES);
    if (na < 0) {
        reply(fd, "err invalid-argument:aliases");
        return -1;
    }

    sqlite3_stmt *st = NULL;
    if (db_prepare("SELECT app FROM distracting_apps;", &st) != 0)
        return reply_db_error(fd);
    int found = 0;
    int rc;
    while ((rc = sqlite3_step(st)) == SQLITE_ROW) {
        const unsigned char *text = sqlite3_column_text(st, 0);
        const char *name = text ? (const char *)text : "";
        if (!strcmp(name, app)) found = 1;
        for (int i = 0; i < na; i++) {
            if (!strcmp(name, aliases[i])) found = 1;
        }
    }
    sqlite3_finalize(st);
    if (rc != SQLITE_DONE) return reply_db_error(fd);
    return reply_bool(fd, found);
}

/* Read-only completion test used by the server before answering. It is the
 * exact transition Dart performs inside getActiveFocusState(). */
static int advance_focus(focus_state *s, int *is_null) {
    *is_null = 0;
    if (begin_immediate() != 0) return -1;
    int loaded = load_focus(s);
    if (loaded <= 0) {
        end_txn(loaded == 0);
        if (loaded == 0) *is_null = 1;
        return loaded < 0 ? -1 : 0;
    }
    long long now = wall_ms();
    if (fs_paused(s) == 1 || now < s->end_time_ms) {
        end_txn(1);
        return 0;
    }

    long long is_break = fs_break(s);
    long long cycle = fs_cycle(s);
    long long total = fs_total(s);
    long long work = s->duration_minutes;
    long long brk = fs_break_dur(s);

    if (!is_break) {
        if (complete_focus_row(s->end_time_ms, work) != 0) {
            end_txn(0);
            return -1;
        }
        if (cycle < total) {
            if (brk > 0) {
                long long break_end = now + brk * 60 * 1000;
                if (update_focus_next(break_end, brk * 60, 1, cycle) != 0 ||
                    load_focus(s) <= 0) {
                    end_txn(0);
                    return -1;
                }
                end_txn(1);
                return 0;
            }
            long long next = cycle + 1;
            long long next_end = now + work * 60 * 1000;
            if (update_focus_next(next_end, work * 60, 0, next) != 0 ||
                insert_focus_session(now, work) != 0 ||
                load_focus(s) <= 0) {
                end_txn(0);
                return -1;
            }
            end_txn(1);
            return 0;
        }
        delete_focus_state();
        end_txn(1);
        *is_null = 1;
        return 0;
    }

    long long next = cycle + 1;
    if (next <= total) {
        long long next_end = now + work * 60 * 1000;
        if (update_focus_next(next_end, work * 60, 0, next) != 0 ||
            insert_focus_session(now, work) != 0 ||
            load_focus(s) <= 0) {
            end_txn(0);
            return -1;
        }
        end_txn(1);
        return 0;
    }
    delete_focus_state();
    end_txn(1);
    *is_null = 1;
    return 0;
}

static int policy_get_active_focus(int fd) {
    focus_state s;
    int is_null = 0;
    int rc = advance_focus(&s, &is_null);
    if (rc != 0) return reply_db_error(fd);
    if (is_null) {
        reply(fd, "ok null");
        return 0;
    }
    return reply_focus(fd, &s);
}

static int policy_start_focus(int fd, const jobject *args) {
    long long minutes;
    if (json_get_ll(args, "durationMinutes", &minutes) != 0) {
        reply(fd, "err missing-argument:durationMinutes");
        return -1;
    }
    long long cycles;
    if (json_get_ll(args, "totalCycles", &cycles) != 0) {
        cycles = setting_is("pomodoro_loop_enabled", "0")
                     ? setting_ll("pomodoro_cycles_count", 4)
                     : 1;
    }
    long long brk;
    if (json_get_ll(args, "breakMinutes", &brk) != 0) {
        brk = setting_ll("pomodoro_break_minutes", 5);
    }

    long long now = wall_ms();
    long long end = now + minutes * 60 * 1000;
    long long remaining = minutes * 60;

    if (begin_immediate() != 0) return reply_db_error(fd);
    sqlite3_stmt *st = NULL;
    if (db_prepare("INSERT INTO active_focus_state (id, end_time_ms, "
                   "duration_minutes, is_paused, remaining_seconds, "
                   "current_cycle, total_cycles, is_break, "
                   "break_duration_minutes) VALUES (1, ?, ?, 0, ?, 1, ?, 0, ?) "
                   "ON CONFLICT(id) DO UPDATE SET end_time_ms = ?, "
                   "duration_minutes = ?, is_paused = 0, remaining_seconds = ?, "
                   "current_cycle = 1, total_cycles = ?, is_break = 0, "
                   "break_duration_minutes = ?;", &st) != 0) {
        end_txn(0);
        return reply_db_error(fd);
    }
    sqlite3_bind_int64(st, 1, end);
    sqlite3_bind_int64(st, 2, minutes);
    sqlite3_bind_int64(st, 3, remaining);
    sqlite3_bind_int64(st, 4, cycles);
    sqlite3_bind_int64(st, 5, brk);
    sqlite3_bind_int64(st, 6, end);
    sqlite3_bind_int64(st, 7, minutes);
    sqlite3_bind_int64(st, 8, remaining);
    sqlite3_bind_int64(st, 9, cycles);
    sqlite3_bind_int64(st, 10, brk);
    int rc = sqlite3_step(st);
    sqlite3_finalize(st);
    if (rc != SQLITE_DONE || insert_focus_session(now, minutes) != 0) {
        end_txn(0);
        return reply_db_error(fd);
    }
    g_writes++;
    end_txn(1);
    return ok_null(fd);
}

static int policy_pause_focus(int fd) {
    focus_state s;
    /* DatabaseService.pauseFocusSession() starts with getActiveFocusState(),
     * which completes an expired phase before pausing. Pausing the stale row
     * instead would strand a finished cycle and freeze the timer on it. */
    int is_null = 0;
    int rc = advance_focus(&s, &is_null);
    if (rc != 0) return reply_db_error(fd);
    if (is_null || fs_paused(&s) == 1) return ok_null(fd);

    long long now = wall_ms();
    long long delta = s.end_time_ms - now;
    long long remaining;
    if (delta >= 0) remaining = (delta + 999) / 1000;
    else remaining = delta / 1000; /* C truncates toward zero, like ceil() */
    if (remaining < 0) remaining = 0;
    if (remaining > 999999) remaining = 999999;

    sqlite3_stmt *st = NULL;
    if (db_prepare("UPDATE active_focus_state SET is_paused = 1, "
                   "remaining_seconds = ? WHERE id = 1;", &st) != 0)
        return reply_db_error(fd);
    sqlite3_bind_int64(st, 1, remaining);
    rc = sqlite3_step(st);
    sqlite3_finalize(st);
    if (rc != SQLITE_DONE) return reply_db_error(fd);
    g_writes++;
    return ok_null(fd);
}

static int policy_resume_focus(int fd) {
    focus_state s;
    int loaded = load_focus(&s);
    if (loaded < 0) return reply_db_error(fd);
    if (loaded == 0 || fs_paused(&s) == 0) return ok_null(fd);

    long long fallback = fs_break(&s) ? fs_break_dur(&s) : s.duration_minutes;
    long long remaining = s.remaining_null ? fallback * 60 : s.remaining;
    long long end = wall_ms() + remaining * 1000;

    sqlite3_stmt *st = NULL;
    if (db_prepare("UPDATE active_focus_state SET is_paused = 0, "
                   "end_time_ms = ? WHERE id = 1;", &st) != 0)
        return reply_db_error(fd);
    sqlite3_bind_int64(st, 1, end);
    int rc = sqlite3_step(st);
    sqlite3_finalize(st);
    if (rc != SQLITE_DONE) return reply_db_error(fd);
    g_writes++;
    return ok_null(fd);
}

static int policy_cancel_focus(int fd) {
    long long now = wall_ms();
    if (begin_immediate() != 0) return reply_db_error(fd);
    sqlite3_exec(g_db, "DELETE FROM active_focus_state WHERE id = 1;",
                 NULL, NULL, NULL);
    sqlite3_stmt *st = NULL;
    if (db_prepare("UPDATE focus_sessions SET ended_at = ?, completed = 0 "
                   "WHERE ended_at IS NULL;", &st) != 0) {
        end_txn(0);
        return reply_db_error(fd);
    }
    sqlite3_bind_int64(st, 1, now);
    int rc = sqlite3_step(st);
    sqlite3_finalize(st);
    if (rc != SQLITE_DONE) {
        end_txn(0);
        return reply_db_error(fd);
    }
    g_writes += 2;
    end_txn(1);
    return ok_null(fd);
}

static int policy_get_daily_goal(int fd) {
    long long goal = setting_ll("daily_goal_ms", 0);
    reply(fd, "ok %lld", goal);
    return 0;
}

static int policy_set_daily_goal(int fd, const jobject *args) {
    long long goal;
    if (json_get_ll(args, "goalMs", &goal) != 0) {
        reply(fd, "err missing-argument:goalMs");
        return -1;
    }
    if (goal <= 0) {
        if (setting_delete("daily_goal_ms") != 0) return reply_db_error(fd);
    } else {
        char buf[32];
        snprintf(buf, sizeof buf, "%lld", goal);
        if (setting_set("daily_goal_ms", buf) != 0) return reply_db_error(fd);
    }
    return ok_null(fd);
}

static int policy_get_setting(int fd, const jobject *args) {
    char key[MAX_STRING + 64];
    char dflt[MAX_STRING] = "";
    if (json_get_str(args, "key", key, sizeof key) != 0) {
        reply(fd, "err missing-argument:key");
        return -1;
    }
    const jvalue *v = json_get(args, "defaultValue");
    if (v && v->type == JV_STR) snprintf(dflt, sizeof dflt, "%s", v->str);
    char out[MAX_STRING];
    if (setting_get(key, dflt, out, sizeof out) != 0)
        return reply_db_error(fd);
    return reply_string(fd, out);
}

static int policy_set_setting(int fd, const jobject *args) {
    char key[MAX_STRING + 64];
    char value[MAX_STRING];
    if (json_get_str(args, "key", key, sizeof key) != 0) {
        reply(fd, "err missing-argument:key");
        return -1;
    }
    if (json_get_str(args, "value", value, sizeof value) != 0) {
        reply(fd, "err missing-argument:value");
        return -1;
    }
    if (setting_set(key, value) != 0) return reply_db_error(fd);
    return ok_null(fd);
}

static int policy_get_setting_bool(int fd, const char *key, const char *dflt,
                                   int invert) {
    int on = setting_is(key, dflt);
    return reply_bool(fd, invert ? !on : on);
}

static int policy_set_setting_bool(int fd, const jobject *args, const char *key,
                                   int invert) {
    const jvalue *v = json_get(args, "enabled");
    int enabled;
    if (!v || v->type == JV_NULL) {
        reply(fd, "err missing-argument:enabled");
        return -1;
    }
    if (v->type == JV_BOOL) enabled = v->boolean;
    else if (v->type == JV_NUM) enabled = v->num ? 1 : 0;
    else {
        reply(fd, "err invalid-argument:enabled");
        return -1;
    }
    if (invert) enabled = !enabled;
    if (setting_set(key, enabled ? "1" : "0") != 0) return reply_db_error(fd);
    return ok_null(fd);
}

static int policy_get_setting_string(int fd, const char *key,
                                     const char *dflt) {
    char out[MAX_STRING];
    if (setting_get(key, dflt, out, sizeof out) != 0)
        return reply_db_error(fd);
    return reply_string(fd, out);
}

static int policy_set_setting_string(int fd, const jobject *args,
                                     const char *arg, const char *key) {
    char value[MAX_STRING];
    if (json_get_str(args, arg, value, sizeof value) != 0) {
        reply(fd, "err missing-argument:%s", arg);
        return -1;
    }
    if (setting_set(key, value) != 0) return reply_db_error(fd);
    return ok_null(fd);
}

static int policy_get_event_bool(int fd, const jobject *args,
                                 const char *prefix, const char *dflt) {
    char event_key[MAX_STRING];
    char full[MAX_STRING + 64];
    if (json_get_str(args, "eventKey", event_key, sizeof event_key) != 0) {
        reply(fd, "err missing-argument:eventKey");
        return -1;
    }
    snprintf(full, sizeof full, "%s%s", prefix, event_key);
    return policy_get_setting_bool(fd, full, dflt, 0);
}

static int policy_set_event_bool(int fd, const jobject *args,
                                 const char *prefix) {
    char event_key[MAX_STRING];
    char full[MAX_STRING + 64];
    if (json_get_str(args, "eventKey", event_key, sizeof event_key) != 0) {
        reply(fd, "err missing-argument:eventKey");
        return -1;
    }
    snprintf(full, sizeof full, "%s%s", prefix, event_key);
    return policy_set_setting_bool(fd, args, full, 0);
}

static int policy_get_focus_grace_until(int fd, const jobject *args) {
    char app[MAX_STRING];
    char key[MAX_STRING + 64];
    if (json_get_str(args, "app", app, sizeof app) != 0) {
        reply(fd, "err missing-argument:app");
        return -1;
    }
    snprintf(key, sizeof key, "focus_grace_%s", app);
    reply(fd, "ok %lld", setting_ll(key, 0));
    return 0;
}

static int policy_set_focus_grace(int fd, const jobject *args) {
    char app[MAX_STRING];
    char key[MAX_STRING + 64];
    long long minutes;
    if (json_get_str(args, "app", app, sizeof app) != 0) {
        reply(fd, "err missing-argument:app");
        return -1;
    }
    if (json_get_ll(args, "minutes", &minutes) != 0) {
        reply(fd, "err missing-argument:minutes");
        return -1;
    }
    snprintf(key, sizeof key, "focus_grace_%s", app);
    char value[32];
    snprintf(value, sizeof value, "%lld", wall_ms() + minutes * 60000);
    if (setting_set(key, value) != 0) return reply_db_error(fd);
    return ok_null(fd);
}

static int policy_is_focus_grace_active(int fd, const jobject *args) {
    char app[MAX_STRING];
    char key[MAX_STRING + 64];
    if (json_get_str(args, "app", app, sizeof app) != 0) {
        reply(fd, "err missing-argument:app");
        return -1;
    }
    snprintf(key, sizeof key, "focus_grace_%s", app);
    return reply_bool(fd, wall_ms() < setting_ll(key, 0));
}

static int policy_get_pomodoro_cycles(int fd) {
    reply(fd, "ok %lld", setting_ll("pomodoro_cycles_count", 4));
    return 0;
}

static int policy_set_pomodoro_cycles(int fd, const jobject *args) {
    long long count;
    if (json_get_ll(args, "count", &count) != 0) {
        reply(fd, "err missing-argument:count");
        return -1;
    }
    if (count < 1) count = 1;
    if (count > 20) count = 20;
    char buf[32];
    snprintf(buf, sizeof buf, "%lld", count);
    if (setting_set("pomodoro_cycles_count", buf) != 0)
        return reply_db_error(fd);
    return ok_null(fd);
}

static int policy_get_pomodoro_break(int fd) {
    reply(fd, "ok %lld", setting_ll("pomodoro_break_minutes", 5));
    return 0;
}

static int policy_set_pomodoro_break(int fd, const jobject *args) {
    long long minutes;
    if (json_get_ll(args, "minutes", &minutes) != 0) {
        reply(fd, "err missing-argument:minutes");
        return -1;
    }
    if (minutes < 1) minutes = 1;
    if (minutes > 60) minutes = 60;
    char buf[32];
    snprintf(buf, sizeof buf, "%lld", minutes);
    if (setting_set("pomodoro_break_minutes", buf) != 0)
        return reply_db_error(fd);
    return ok_null(fd);
}

static int policy_has_notified(int fd, const jobject *args) {
    char milestone[MAX_STRING];
    char date_key[MAX_STRING];
    if (json_get_str(args, "milestoneKey", milestone, sizeof milestone) != 0) {
        reply(fd, "err missing-argument:milestoneKey");
        return -1;
    }
    if (json_get_str(args, "dateKey", date_key, sizeof date_key) != 0) {
        reply(fd, "err missing-argument:dateKey");
        return -1;
    }
    char key[MAX_STRING + 64];
    snprintf(key, sizeof key, "last_notified_%s", milestone);
    char out[MAX_STRING];
    if (setting_get(key, "", out, sizeof out) != 0)
        return reply_db_error(fd);
    return reply_bool(fd, !strcmp(out, date_key));
}

static int policy_mark_notified(int fd, const jobject *args) {
    char milestone[MAX_STRING];
    char date_key[MAX_STRING];
    char key[MAX_STRING + 64];
    if (json_get_str(args, "milestoneKey", milestone, sizeof milestone) != 0) {
        reply(fd, "err missing-argument:milestoneKey");
        return -1;
    }
    if (json_get_str(args, "dateKey", date_key, sizeof date_key) != 0) {
        reply(fd, "err missing-argument:dateKey");
        return -1;
    }
    snprintf(key, sizeof key, "last_notified_%s", milestone);
    if (setting_set(key, date_key) != 0) return reply_db_error(fd);
    return ok_null(fd);
}

static int policy_get_overtime(int fd, const jobject *args) {
    char date_key[MAX_STRING];
    char saved[MAX_STRING];
    if (json_get_str(args, "dateKey", date_key, sizeof date_key) != 0) {
        reply(fd, "err missing-argument:dateKey");
        return -1;
    }
    if (setting_get("overtime_milestone_date", "", saved, sizeof saved) != 0)
        return reply_db_error(fd);
    if (strcmp(saved, date_key)) {
        reply(fd, "ok 0");
        return 0;
    }
    reply(fd, "ok %lld", setting_ll("overtime_milestone_index", 0));
    return 0;
}

static int policy_set_overtime(int fd, const jobject *args) {
    char date_key[MAX_STRING];
    long long index;
    if (json_get_str(args, "dateKey", date_key, sizeof date_key) != 0) {
        reply(fd, "err missing-argument:dateKey");
        return -1;
    }
    if (json_get_ll(args, "index", &index) != 0) {
        reply(fd, "err missing-argument:index");
        return -1;
    }
    char buf[32];
    snprintf(buf, sizeof buf, "%lld", index);
    if (begin_immediate() != 0) return reply_db_error(fd);
    if (setting_set("overtime_milestone_date", date_key) != 0 ||
        setting_set("overtime_milestone_index", buf) != 0) {
        end_txn(0);
        return reply_db_error(fd);
    }
    end_txn(1);
    return ok_null(fd);
}

/* --------------------------------------------------------------- dispatch */

static void serve_policy(int fd, const char *method, const char *payload) {
    jobject args;
    if (!*payload) payload = "{}";
    if (json_parse_object(payload, strlen(payload), &args) != 0) {
        reply(fd, "err bad-json");
        return;
    }
    int ready = db_ready();
    if (ready < 0) {
        reply(fd, "err database-unavailable");
        return;
    }
    if (ready == 0) {
        reply(fd, "err database-not-ready");
        return;
    }

    if (!strcmp(method, "getAppLimit")) {
        policy_get_app_limit(fd, &args);
    } else if (!strcmp(method, "setAppLimit")) {
        policy_set_app_limit(fd, &args);
    } else if (!strcmp(method, "addTempExtension")) {
        policy_add_temp_extension(fd, &args);
    } else if (!strcmp(method, "deleteAppLimit")) {
        policy_delete_app_limit(fd, &args);
    } else if (!strcmp(method, "getDistractingApps")) {
        policy_distracting_apps(fd);
    } else if (!strcmp(method, "toggleDistractingApp")) {
        policy_toggle_distracting(fd, &args);
    } else if (!strcmp(method, "isDistractingApp")) {
        policy_is_distracting(fd, &args);
    } else if (!strcmp(method, "startFocusSession")) {
        policy_start_focus(fd, &args);
    } else if (!strcmp(method, "pauseFocusSession")) {
        policy_pause_focus(fd);
    } else if (!strcmp(method, "resumeFocusSession")) {
        policy_resume_focus(fd);
    } else if (!strcmp(method, "getActiveFocusState")) {
        policy_get_active_focus(fd);
    } else if (!strcmp(method, "cancelFocusSession")) {
        policy_cancel_focus(fd);
    } else if (!strcmp(method, "getDailyGoalMs")) {
        policy_get_daily_goal(fd);
    } else if (!strcmp(method, "setDailyGoalMs")) {
        policy_set_daily_goal(fd, &args);
    } else if (!strcmp(method, "getSetting")) {
        policy_get_setting(fd, &args);
    } else if (!strcmp(method, "setSetting")) {
        policy_set_setting(fd, &args);
    } else if (!strcmp(method, "isNotificationsGloballyEnabled")) {
        policy_get_setting_bool(fd, "notifications_enabled", "1", 0);
    } else if (!strcmp(method, "setNotificationsGloballyEnabled")) {
        policy_set_setting_bool(fd, &args, "notifications_enabled", 0);
    } else if (!strcmp(method, "isSoundGloballyEnabled")) {
        policy_get_setting_bool(fd, "sound_enabled", "1", 0);
    } else if (!strcmp(method, "setSoundGloballyEnabled")) {
        policy_set_setting_bool(fd, &args, "sound_enabled", 0);
    } else if (!strcmp(method, "getSoundTheme")) {
        policy_get_setting_string(fd, "sound_theme", "chime");
    } else if (!strcmp(method, "setSoundTheme")) {
        policy_set_setting_string(fd, &args, "theme", "sound_theme");
    } else if (!strcmp(method, "getCustomSoundPath")) {
        policy_get_setting_string(fd, "custom_sound_path", "");
    } else if (!strcmp(method, "setCustomSoundPath")) {
        policy_set_setting_string(fd, &args, "path", "custom_sound_path");
    } else if (!strcmp(method, "isEventNotificationEnabled")) {
        policy_get_event_bool(fd, &args, "notify_", "1");
    } else if (!strcmp(method, "setEventNotificationEnabled")) {
        policy_set_event_bool(fd, &args, "notify_");
    } else if (!strcmp(method, "isEventSoundEnabled")) {
        policy_get_event_bool(fd, &args, "sound_", "1");
    } else if (!strcmp(method, "setEventSoundEnabled")) {
        policy_set_event_bool(fd, &args, "sound_");
    } else if (!strcmp(method, "isPomodoroLoopEnabled")) {
        policy_get_setting_bool(fd, "pomodoro_loop_enabled", "0", 0);
    } else if (!strcmp(method, "setPomodoroLoopEnabled")) {
        policy_set_setting_bool(fd, &args, "pomodoro_loop_enabled", 0);
    } else if (!strcmp(method, "isFocusStrictAutoclose")) {
        policy_get_setting_bool(fd, "focus_strict_autoclose", "0", 0);
    } else if (!strcmp(method, "setFocusStrictAutoclose")) {
        policy_set_setting_bool(fd, &args, "focus_strict_autoclose", 0);
    } else if (!strcmp(method, "isFocusAppGridLayout")) {
        char layout[MAX_STRING];
        if (setting_get("focus_app_list_layout", "list", layout,
                        sizeof layout) != 0) {
            reply_db_error(fd);
            return;
        }
        reply(fd, "ok %s", !strcmp(layout, "grid") ? "true" : "false");
    } else if (!strcmp(method, "setFocusAppGridLayout")) {
        const jvalue *v = json_get(&args, "grid");
        int grid = 0;
        if (v && v->type == JV_BOOL) grid = v->boolean;
        else if (v && v->type == JV_NUM) grid = v->num ? 1 : 0;
        else {
            reply(fd, "err missing-argument:grid");
            return;
        }
        if (setting_set("focus_app_list_layout", grid ? "grid" : "list") != 0) {
            reply_db_error(fd);
            return;
        }
        ok_null(fd);
    } else if (!strcmp(method, "getFocusGraceUntilMs")) {
        policy_get_focus_grace_until(fd, &args);
    } else if (!strcmp(method, "setFocusGraceMinutes")) {
        policy_set_focus_grace(fd, &args);
    } else if (!strcmp(method, "isFocusGraceActive")) {
        policy_is_focus_grace_active(fd, &args);
    } else if (!strcmp(method, "getPomodoroCyclesCount")) {
        policy_get_pomodoro_cycles(fd);
    } else if (!strcmp(method, "setPomodoroCyclesCount")) {
        policy_set_pomodoro_cycles(fd, &args);
    } else if (!strcmp(method, "getPomodoroBreakMinutes")) {
        policy_get_pomodoro_break(fd);
    } else if (!strcmp(method, "setPomodoroBreakMinutes")) {
        policy_set_pomodoro_break(fd, &args);
    } else if (!strcmp(method, "hasNotifiedDailyMilestone")) {
        policy_has_notified(fd, &args);
    } else if (!strcmp(method, "markDailyMilestoneNotified")) {
        policy_mark_notified(fd, &args);
    } else if (!strcmp(method, "getOvertimeMilestoneIndex")) {
        policy_get_overtime(fd, &args);
    } else if (!strcmp(method, "setOvertimeMilestoneIndex")) {
        policy_set_overtime(fd, &args);
    } else {
        reply(fd, "err unknown-method");
    }
}

static void serve_system(int fd, const char *method) {
    if (!strcmp(method, "ping")) {
        reply(fd, "ok pong");
    } else if (!strcmp(method, "status")) {
        int ready = db_ready();
        reply(fd, "ok pid=%ld db=%s ready=%d writes=%lld uptime=%ld",
              (long)getpid(), g_db_path, ready == 1, g_writes,
              (long)(time(NULL) - g_started_at));
    } else {
        reply(fd, "err unknown-method");
    }
}

/* ------------------------------------------------------------------- server */

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
    while (n > 0 && (line[n - 1] == '\n' || line[n - 1] == '\r')) line[--n] = '\0';
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
        payload = (char *)"";
    }

    if (!strcmp(domain, "system")) {
        serve_system(client, method);
    } else if (!strcmp(domain, "policy")) {
        serve_policy(client, method, payload);
    } else {
        reply(client, "err unknown-domain");
    }
}

/* ---------------------------------------------------------------------- main */

static void usage(const char *prog) {
    fprintf(stderr,
        "usage: %s [options]\n"
        "\n"
        "  --runtime DIR   runtime directory (default $XDG_RUNTIME_DIR/screenguard)\n"
        "  --db PATH       SQLite database (default XDG_DATA_HOME/screenguard/usage.db)\n"
        "  --check         open the database, report its schema, and exit\n"
        "  --verbose       log requests and SQL failures\n"
        "  -h, --help      this text\n"
        "\n"
        "The worker owns the policy domain and is the only process that advances\n"
        "the focus/Pomodoro state machine. The Dart daemon reads it through\n"
        "$XDG_RUNTIME_DIR/screenguard/policy.sock.\n",
        prog);
}

static int resolve_db_path(char *out, size_t cap) {
    const char *xdg = getenv("XDG_DATA_HOME");
    const char *home = getenv("HOME");
    int n;
    if (xdg) {
        n = snprintf(out, cap, "%s/screenguard/usage.db", xdg);
    } else if (home) {
        n = snprintf(out, cap, "%s/.local/share/screenguard/usage.db", home);
    } else {
        n = snprintf(out, cap, "/tmp/.local/share/screenguard/usage.db");
    }
    return (n < 0 || (size_t)n >= cap) ? -1 : 0;
}

static int check_db(void) {
    if (db_open() != 0) {
        fprintf(stderr, "policy-check: cannot open %s: %s\n", g_db_path,
                strerror(errno));
        return 1;
    }
    if (db_ready() != 1) {
        fprintf(stderr, "policy-check: db=%s schema=missing (%s)\n", g_db_path,
                sqlite3_errmsg(g_db));
        return 1;
    }
    long long settings = 0, limits = 0, distracting = 0, focus = 0;
    if (scalar_ll("SELECT COUNT(*) FROM settings;", NULL, 0, &settings) != 0 ||
        scalar_ll("SELECT COUNT(*) FROM app_limits;", NULL, 0, &limits) != 0 ||
        scalar_ll("SELECT COUNT(*) FROM distracting_apps;", NULL, 0,
                  &distracting) != 0 ||
        scalar_ll("SELECT COUNT(*) FROM focus_sessions;", NULL, 0, &focus) != 0) {
        fprintf(stderr, "policy-check: db=%s schema=incomplete (%s)\n",
                g_db_path, sqlite3_errmsg(g_db));
        return 1;
    }
    printf("policy-check: db=%s schema=ok settings=%lld limits=%lld "
           "distracting=%lld focus=%lld\n",
           g_db_path, settings, limits, distracting, focus);
    return 0;
}

int main(int argc, char **argv) {
    const char *runtime = NULL;
    const char *db = NULL;
    int check_only = 0;

    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--runtime") && i + 1 < argc) {
            runtime = argv[++i];
        } else if (!strcmp(argv[i], "--db") && i + 1 < argc) {
            db = argv[++i];
        } else if (!strcmp(argv[i], "--check")) {
            check_only = 1;
        } else if (!strcmp(argv[i], "--verbose")) {
            g_verbose = 1;
        } else if (!strcmp(argv[i], "-h") || !strcmp(argv[i], "--help")) {
            usage(argv[0]);
            return 0;
        } else {
            fprintf(stderr, "%s: unknown argument %s\n", argv[0], argv[i]);
            usage(argv[0]);
            return 2;
        }
    }

    if (db) {
        if (snprintf(g_db_path, sizeof g_db_path, "%s", db) >=
            (int)sizeof g_db_path) {
            fprintf(stderr, "database path too long: %s\n", db);
            return 2;
        }
    } else if (resolve_db_path(g_db_path, sizeof g_db_path) != 0) {
        fprintf(stderr, "database path too long\n");
        return 2;
    }

    if (check_only) return check_db();

    if (!runtime) {
        const char *xdg = getenv("XDG_RUNTIME_DIR");
        static char fallback[PATH_MAX];
        if (xdg && *xdg) {
            snprintf(fallback, sizeof fallback, "%s/screenguard", xdg);
        } else {
            snprintf(fallback, sizeof fallback, "/tmp/screenguard-%ld",
                     (long)geteuid());
        }
        runtime = fallback;
    }
    snprintf(g_runtime, sizeof g_runtime, "%s", runtime);

    if (snprintf(g_socket_path, sizeof g_socket_path, "%s/policy.sock",
                 runtime) >= (int)sizeof g_socket_path ||
        snprintf(g_lock_path, sizeof g_lock_path, "%s/policy.lock",
                 runtime) >= (int)sizeof g_lock_path) {
        fprintf(stderr, "runtime path too long: %s\n", runtime);
        return 2;
    }

    if (mkdir_private(runtime) < 0) {
        fprintf(stderr, "cannot create %s: %s\n", runtime, strerror(errno));
        return 1;
    }

    g_lock_fd = lock_exclusive(g_lock_path);
    if (g_lock_fd == -2) {
        fprintf(stderr, "another digiwelld-policy already owns %s\n", runtime);
        return 1;
    }
    if (g_lock_fd < 0) {
        fprintf(stderr, "cannot lock %s: %s\n", g_lock_path, strerror(errno));
        return 1;
    }

    signal(SIGPIPE, SIG_IGN);
    struct sigaction sa;
    memset(&sa, 0, sizeof sa);
    sa.sa_handler = on_signal;
    sigaction(SIGTERM, &sa, NULL);
    sigaction(SIGINT, &sa, NULL);
    sigaction(SIGHUP, &sa, NULL);

    g_listen_fd = listen_unix(g_socket_path);
    if (g_listen_fd < 0) {
        fprintf(stderr, "cannot listen on %s\n", g_socket_path);
        return 1;
    }

    g_started_at = time(NULL);
    logmsg("listening on %s (mode %04o), db=%s", g_socket_path, SOCK_MODE,
           g_db_path);
    logmsg("owns policy intent and the focus state machine");

    while (!g_stop) {
        struct pollfd pfd = { .fd = g_listen_fd, .events = POLLIN, .revents = 0 };
        int pr = poll(&pfd, 1, 500);
        if (pr < 0 && errno != EINTR) {
            logmsg("poll: %s", strerror(errno));
            break;
        }
        if (pr > 0 && (pfd.revents & POLLIN)) {
            int client = accept4(g_listen_fd, NULL, NULL, SOCK_CLOEXEC);
            if (client >= 0) {
                handle_client(client);
                close(client);
            } else if (errno != EINTR && errno != EAGAIN) {
                logmsg("accept: %s", strerror(errno));
            }
        }
    }

    logmsg("shutting down");
    if (g_listen_fd >= 0) close(g_listen_fd);
    unlink(g_socket_path);
    if (g_db) sqlite3_close(g_db);
    if (g_lock_fd >= 0) {
        flock(g_lock_fd, LOCK_UN);
        close(g_lock_fd);
    }
    return 0;
}
