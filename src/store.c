/*
 * digiwelld-store - the single SQLite writer for ScreenGuard.
 *
 * This is the fourth worker of the digiwelld migration. It owns the `storage`
 * domain: opening and closing sessions, recording the event stream, and every
 * destructive maintenance operation (delete a date range, forget all usage).
 * It also owns the database file itself: on first boot it creates the schema
 * and runs the same one-time cleanups DatabaseService.init() used to run.
 *
 * Why a single writer:
 *
 *   SQLite allows many readers but only one writer at a time. Routing every
 *   session/event mutation through one process makes that serialisation
 *   structural instead of hopeful: two daemons, the GUI maintenance screens
 *   and the tracker can no longer interleave a close with an open. Readers
 *   (digiwelld-usage, the GUI) keep their own read-only connections.
 *
 * What it deliberately does NOT do:
 *
 *   * observe windows or idle time    -> Dart tracker
 *   * decide or apply limits           -> digiwelld-enforce
 *   * write policy intent             -> digiwelld-policy
 *   * answer analytics reads           -> digiwelld-usage
 *
 * Responsibilities during the migration:
 *
 *   digiwelld-store   owns sessions + events + the schema
 *   digiwelld-policy  owns settings, app_limits, distracting_apps and focus
 *   digiwelld-usage   read-only analytics over the same file
 *
 * The daemon discovers the worker through SCREENGUARD_STORE_SOCKET. When the
 * variable is set, DatabaseService delegates its mutating methods here; when
 * it is absent the daemon keeps its local writer for older installs. The
 * supervisor holds storage.lock around every routed storage.* request, so a
 * direct caller and a routed caller still serialise.
 *
 * Protocol (same envelope as digiwelld, digiwelld-session, digiwelld-usage,
 * digiwelld-policy):
 *
 *   request   <domain> <method> <json-object>
 *   response  ok <json>
 *             err <reason>
 *
 * Domains: system, storage. One request per connection.
 *
 * Every method mirrors DatabaseService one-for-one, including the
 * ended_at IS NULL guards, event payloads and return values, so moving a
 * caller from the Dart dispatch to this worker cannot change behaviour.
 *
 * Build:
 *   cc -O2 -Wall -Wextra -std=c99 -o digiwelld-store src/store.c -lsqlite3
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

    fprintf(stderr, "[digiwelld-store %s] %s\n", stamp, msg);
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
                             SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX, NULL);
    if (rc != SQLITE_OK) {
        if (db) sqlite3_close(db);
        return -1;
    }
    sqlite3_busy_timeout(db, 5000);
    /* Same pragmas as DatabaseService.init(). WAL lets the read models
     * (digiwelld-usage) keep reading while this worker writes; NORMAL is the
     * same durability choice the app already made. */
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
                  "name IN ('sessions','settings','app_limits',"
                  "'distracting_apps','focus_sessions','active_focus_state',"
                  "'events');", NULL, 0, &n) != 0)
        return 0;
    return n == 7 ? 1 : 0;
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
static long long g_writes = 0;

static int ok_null(int fd) {
    reply(fd, "ok null");
    return 0;
}

/* ------------------------------------------------------------------ schema */

static int exec_sql(const char *sql) {
    if (sqlite3_exec(g_db, sql, NULL, NULL, NULL) != SQLITE_OK) {
        if (g_verbose) {
            logmsg("exec failed: %s (%s)", sqlite3_errmsg(g_db), sql);
        }
        return -1;
    }
    return 0;
}

/* ALTER TABLE ADD COLUMN has no IF NOT EXISTS form; a second run is an
 * expected error, not a failure. */
static void exec_ignore(const char *sql) {
    (void)sqlite3_exec(g_db, sql, NULL, NULL, NULL);
}

static void ensure_db_dir(void) {
    char dir[PATH_MAX];
    if (snprintf(dir, sizeof dir, "%s", g_db_path) >= (int)sizeof dir) return;
    char *slash = strrchr(dir, '/');
    if (!slash || slash == dir) return;
    *slash = '\0';

    char tmp[PATH_MAX];
    if (snprintf(tmp, sizeof tmp, "%s", dir) >= (int)sizeof tmp) return;
    for (char *p = tmp + 1; *p; p++) {
        if (*p != '/') continue;
        *p = '\0';
        if (mkdir(tmp, 0755) != 0 && errno != EEXIST) return;
        *p = '/';
    }
    if (mkdir(tmp, DIR_MODE) == 0) chmod(tmp, DIR_MODE);
}

/* Exactly DatabaseService.init(): same tables, same columns, same indexes.
 * Only the writer creates them, so the read models can open with READWRITE
 * without CREATE and report database-not-ready until this has run once. */
static int ensure_schema(void) {
    if (exec_sql(
        "CREATE TABLE IF NOT EXISTS sessions ("
        "  id INTEGER PRIMARY KEY AUTOINCREMENT,"
        "  app TEXT NOT NULL,"
        "  app_name TEXT,"
        "  title TEXT,"
        "  pid INTEGER,"
        "  started_at INTEGER NOT NULL,"
        "  ended_at INTEGER,"
        "  duration_ms INTEGER,"
        "  idle INTEGER DEFAULT 0"
        ");"
        "CREATE TABLE IF NOT EXISTS settings ("
        "  key TEXT PRIMARY KEY,"
        "  value TEXT"
        ");"
        "CREATE TABLE IF NOT EXISTS app_limits ("
        "  app TEXT PRIMARY KEY,"
        "  limit_ms INTEGER NOT NULL,"
        "  temp_extension_ms INTEGER DEFAULT 0,"
        "  enabled INTEGER DEFAULT 1"
        ");"
        "CREATE TABLE IF NOT EXISTS distracting_apps ("
        "  app TEXT PRIMARY KEY"
        ");"
        "CREATE TABLE IF NOT EXISTS focus_sessions ("
        "  id INTEGER PRIMARY KEY AUTOINCREMENT,"
        "  started_at INTEGER NOT NULL,"
        "  ended_at INTEGER,"
        "  duration_minutes INTEGER NOT NULL,"
        "  completed INTEGER DEFAULT 0"
        ");"
        "CREATE TABLE IF NOT EXISTS active_focus_state ("
        "  id INTEGER PRIMARY KEY CHECK (id = 1),"
        "  end_time_ms INTEGER NOT NULL,"
        "  duration_minutes INTEGER NOT NULL,"
        "  is_paused INTEGER DEFAULT 0,"
        "  remaining_seconds INTEGER DEFAULT 0"
        ");"
        "CREATE TABLE IF NOT EXISTS events ("
        "  id INTEGER PRIMARY KEY AUTOINCREMENT,"
        "  at INTEGER NOT NULL,"
        "  kind TEXT NOT NULL,"
        "  app TEXT,"
        "  detail TEXT"
        ");"
        "CREATE INDEX IF NOT EXISTS idx_sessions_started ON sessions(started_at);"
        "CREATE INDEX IF NOT EXISTS idx_events_at ON events(at);"
        "CREATE INDEX IF NOT EXISTS idx_events_kind_at ON events(kind, at);"
        "CREATE INDEX IF NOT EXISTS idx_sessions_app ON sessions(app);") != 0)
        return -1;

    exec_ignore("ALTER TABLE active_focus_state ADD COLUMN is_paused INTEGER DEFAULT 0;");
    exec_ignore("ALTER TABLE active_focus_state ADD COLUMN remaining_seconds INTEGER DEFAULT 0;");
    exec_ignore("ALTER TABLE active_focus_state ADD COLUMN current_cycle INTEGER DEFAULT 1;");
    exec_ignore("ALTER TABLE active_focus_state ADD COLUMN total_cycles INTEGER DEFAULT 1;");
    exec_ignore("ALTER TABLE active_focus_state ADD COLUMN is_break INTEGER DEFAULT 0;");
    exec_ignore("ALTER TABLE active_focus_state ADD COLUMN break_duration_minutes INTEGER DEFAULT 5;");

    /* The one-time repairs DatabaseService.init() performs. They are
     * idempotent, so a daemon that also ran them on an older install cannot
     * make them do anything twice. */
    exec_ignore("UPDATE sessions SET app_name = 'Firefox' "
                "WHERE (app = 'org.mozilla.firefox' OR app = 'firefox') AND "
                "(app_name LIKE 'Open the Profile Manager%' OR "
                " app_name LIKE 'Open a New %' OR app_name IS NULL);");
    exec_ignore("UPDATE sessions SET app_name = 'Chromium' "
                "WHERE (app = 'chromium-browser' OR app = 'chromium') AND "
                "(app_name LIKE 'Open a New %' OR app_name IS NULL);");
    exec_ignore("UPDATE sessions SET app_name = 'Files' "
                "WHERE app LIKE '%nautilus%' AND "
                "(app_name = 'New Window' OR app_name IS NULL);");
    exec_ignore("UPDATE sessions SET app_name = 'Terminal' "
                "WHERE app LIKE '%ptyxis%' AND "
                "(app_name = 'Preferences' OR app_name LIKE 'New %' OR "
                " app_name IS NULL);");
    exec_ignore("UPDATE sessions SET app_name = 'Text Editor' "
                "WHERE app LIKE '%texteditor%' AND "
                "(app_name = 'New Window' OR app_name IS NULL);");
    exec_ignore("DELETE FROM sessions WHERE app IN ('xfdesktop',"
                "'nemo-desktop','plasmashell','gnome-shell','mutter');");

    sqlite3_stmt *st = NULL;
    if (db_prepare("DELETE FROM events WHERE at < ?;", &st) == 0) {
        sqlite3_bind_int64(st, 1,
                           wall_ms() - 90LL * 24 * 3600 * 1000);
        (void)sqlite3_step(st);
        sqlite3_finalize(st);
    }
    return 0;
}

/* ----------------------------------------------------------- input helpers */

static int miss(int fd, const char *key) {
    reply(fd, "err missing-argument:%s", key);
    return -1;
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

/* Decode [1,2,3] (epoch milliseconds) into a fixed array. Returns the count,
 * or -1 on a malformed array. An absent key is zero elements. */
static int json_get_ll_array(const jobject *obj, const char *key,
                             long long *out, int max) {
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
        jvalue item;
        memset(&item, 0, sizeof item);
        if (jp_value(&jp, &item) != 0) return -1;
        if (item.type == JV_NUM) {
            out[count++] = item.num;
        } else if (item.type == JV_BOOL) {
            out[count++] = item.boolean;
        } else {
            return -1;
        }
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

static void bind_text_or_null(sqlite3_stmt *st, int idx,
                              const jobject *obj, const char *key) {
    char value[MAX_STRING];
    if (json_get_str(obj, key, value, sizeof value) == 0) {
        sqlite3_bind_text(st, idx, value, -1, SQLITE_TRANSIENT);
    } else {
        sqlite3_bind_null(st, idx);
    }
}

/* Local calendar helpers. Dart builds these with DateTime(y, m, d), which is
 * local time and normalises month/year overflow; mktime does the same. */
static int local_day_start(long long ms, int add_days, long long *out) {
    time_t t = (time_t)(ms / 1000);
    if (ms < 0 && (ms % 1000) != 0) t -= 1;
    struct tm tm;
    if (!localtime_r(&t, &tm)) return -1;
    tm.tm_hour = 0;
    tm.tm_min = 0;
    tm.tm_sec = 0;
    tm.tm_isdst = -1;
    tm.tm_mday += add_days;
    time_t r = mktime(&tm);
    if (r == (time_t)-1) return -1;
    *out = (long long)r * 1000;
    return 0;
}

/* ---------------------------------------------------------------- storage */

/* Best-effort, like DatabaseService.recordEvent(): losing a diagnostic event
 * must never fail the operation that produced it. */
static void record_event(const jobject *a, long long fallback_at) {
    char kind[MAX_STRING];
    if (json_get_str(a, "kind", kind, sizeof kind) != 0) return;

    long long at = fallback_at;
    (void)json_get_ll(a, "at", &at);

    sqlite3_stmt *st = NULL;
    if (db_prepare("INSERT INTO events (at, kind, app, detail) "
                   "VALUES (?,?,?,?)", &st) != 0)
        return;
    sqlite3_bind_int64(st, 1, at);
    sqlite3_bind_text(st, 2, kind, -1, SQLITE_TRANSIENT);
    bind_text_or_null(st, 3, a, "app");
    bind_text_or_null(st, 4, a, "detail");
    if (sqlite3_step(st) == SQLITE_DONE) g_writes++;
    sqlite3_finalize(st);
}

static int storage_record_event(int fd, const jobject *a) {
    char kind[MAX_STRING];
    if (json_get_str(a, "kind", kind, sizeof kind) != 0)
        return miss(fd, "kind");

    long long at = wall_ms();
    (void)json_get_ll(a, "at", &at);

    sqlite3_stmt *st = NULL;
    if (db_prepare("INSERT INTO events (at, kind, app, detail) "
                   "VALUES (?,?,?,?)", &st) == 0) {
        sqlite3_bind_int64(st, 1, at);
        sqlite3_bind_text(st, 2, kind, -1, SQLITE_TRANSIENT);
        bind_text_or_null(st, 3, a, "app");
        bind_text_or_null(st, 4, a, "detail");
        if (sqlite3_step(st) == SQLITE_DONE) g_writes++;
        sqlite3_finalize(st);
    }
    /* DatabaseService swallows every insert failure here. */
    reply(fd, "ok null");
    return 0;
}

static int storage_open_session(int fd, const jobject *a) {
    char app[MAX_STRING];
    if (json_get_str(a, "app", app, sizeof app) != 0)
        return miss(fd, "app");
    long long started = 0;
    if (json_get_ll(a, "startedAt", &started) != 0)
        return miss(fd, "startedAt");
    int idle = 0;
    if (json_get_bool(a, "idle", &idle) != 0)
        return miss(fd, "idle");
    long long pid = 0;
    int has_pid = json_get_ll(a, "pid", &pid) == 0;

    sqlite3_stmt *st = NULL;
    if (db_prepare("INSERT INTO sessions (app, app_name, title, pid, "
                   "started_at, idle) VALUES (?,?,?,?,?,?)", &st) != 0)
        return reply_db_error(fd);
    sqlite3_bind_text(st, 1, app, -1, SQLITE_TRANSIENT);
    bind_text_or_null(st, 2, a, "appName");
    bind_text_or_null(st, 3, a, "title");
    if (has_pid) sqlite3_bind_int64(st, 4, pid);
    else sqlite3_bind_null(st, 4);
    sqlite3_bind_int64(st, 5, started);
    sqlite3_bind_int64(st, 6, idle ? 1 : 0);
    int rc = sqlite3_step(st);
    sqlite3_finalize(st);
    if (rc != SQLITE_DONE) return reply_db_error(fd);

    long long id = sqlite3_last_insert_rowid(g_db);
    g_writes++;

    char detail[96];
    snprintf(detail, sizeof detail, "id=%lld idle=%d", id, idle ? 1 : 0);
    jobject ev;
    memset(&ev, 0, sizeof ev);
    snprintf(ev.pairs[0].key, sizeof ev.pairs[0].key, "kind");
    ev.pairs[0].val.type = JV_STR;
    snprintf(ev.pairs[0].val.str, sizeof ev.pairs[0].val.str, "session.open");
    snprintf(ev.pairs[1].key, sizeof ev.pairs[1].key, "app");
    ev.pairs[1].val.type = JV_STR;
    snprintf(ev.pairs[1].val.str, sizeof ev.pairs[1].val.str, "%s", app);
    snprintf(ev.pairs[2].key, sizeof ev.pairs[2].key, "detail");
    ev.pairs[2].val.type = JV_STR;
    snprintf(ev.pairs[2].val.str, sizeof ev.pairs[2].val.str, "%s", detail);
    ev.count = 3;
    record_event(&ev, started);

    reply(fd, "ok %lld", id);
    return 0;
}

static int storage_close_session(int fd, const jobject *a) {
    long long id = 0, ended = 0;
    if (json_get_ll(a, "id", &id) != 0) return miss(fd, "id");
    if (json_get_ll(a, "endedAt", &ended) != 0) return miss(fd, "endedAt");

    sqlite3_stmt *st = NULL;
    if (db_prepare("SELECT started_at, app FROM sessions "
                   "WHERE id = ? AND ended_at IS NULL;", &st) != 0)
        return reply_db_error(fd);
    sqlite3_bind_int64(st, 1, id);
    int rc = sqlite3_step(st);
    if (rc != SQLITE_ROW) {
        sqlite3_finalize(st);
        return ok_null(fd);
    }
    long long started = sqlite3_column_int64(st, 0);
    char app[MAX_STRING];
    app[0] = '\0';
    int has_app = sqlite3_column_type(st, 1) != SQLITE_NULL;
    if (has_app) {
        const unsigned char *text = sqlite3_column_text(st, 1);
        if (text) snprintf(app, sizeof app, "%s", (const char *)text);
    }
    sqlite3_finalize(st);

    long long duration = ended > started ? ended - started : 0;

    if (db_prepare("UPDATE sessions SET ended_at = ?, duration_ms = ? "
                   "WHERE id = ? AND ended_at IS NULL;", &st) != 0)
        return reply_db_error(fd);
    sqlite3_bind_int64(st, 1, ended);
    sqlite3_bind_int64(st, 2, duration);
    sqlite3_bind_int64(st, 3, id);
    rc = sqlite3_step(st);
    sqlite3_finalize(st);
    if (rc != SQLITE_DONE) return reply_db_error(fd);
    if (sqlite3_changes(g_db) == 0) return ok_null(fd);
    g_writes++;

    char detail[96];
    snprintf(detail, sizeof detail, "id=%lld durationMs=%lld", id, duration);
    jobject ev;
    memset(&ev, 0, sizeof ev);
    snprintf(ev.pairs[0].key, sizeof ev.pairs[0].key, "kind");
    ev.pairs[0].val.type = JV_STR;
    snprintf(ev.pairs[0].val.str, sizeof ev.pairs[0].val.str, "session.close");
    if (has_app) {
        snprintf(ev.pairs[1].key, sizeof ev.pairs[1].key, "app");
        ev.pairs[1].val.type = JV_STR;
        snprintf(ev.pairs[1].val.str, sizeof ev.pairs[1].val.str, "%s", app);
        ev.count = 2;
    } else {
        ev.count = 1;
    }
    snprintf(ev.pairs[ev.count].key, sizeof ev.pairs[0].key, "detail");
    ev.pairs[ev.count].val.type = JV_STR;
    snprintf(ev.pairs[ev.count].val.str, sizeof ev.pairs[0].val.str, "%s",
             detail);
    ev.count++;
    record_event(&ev, ended);

    return ok_null(fd);
}

static int storage_database_file_size(int fd) {
    struct stat st;
    long long size = 0;
    if (stat(g_db_path, &st) == 0) size = (long long)st.st_size;
    reply(fd, "ok %lld", size);
    return 0;
}

static int storage_session_count(int fd) {
    long long n = 0;
    if (scalar_ll("SELECT COUNT(*) FROM sessions;", NULL, 0, &n) != 0)
        return reply_db_error(fd);
    reply(fd, "ok %lld", n);
    return 0;
}

static int storage_day_start(int fd, const jobject *a, int add_days) {
    long long day = 0;
    if (json_get_ll(a, "day", &day) != 0) return miss(fd, "day");
    long long out = 0;
    if (local_day_start(day, add_days, &out) != 0) {
        reply(fd, "err bad-argument:day");
        return -1;
    }
    reply(fd, "ok %lld", out);
    return 0;
}

/* DELETE sessions/focus_sessions/events in [start, end), returning the sum of
 * affected rows, exactly like DatabaseService._deleteSessionsBetween. */
static int delete_between(long long start, long long end, long long *out) {
    long long total = 0;
    static const char *const sql[] = {
        "DELETE FROM sessions WHERE started_at >= ? AND started_at < ?;",
        "DELETE FROM focus_sessions WHERE started_at >= ? AND started_at < ?;",
        "DELETE FROM events WHERE at >= ? AND at < ?;",
    };
    for (int i = 0; i < 3; i++) {
        sqlite3_stmt *st = NULL;
        if (db_prepare(sql[i], &st) != 0) return -1;
        sqlite3_bind_int64(st, 1, start);
        sqlite3_bind_int64(st, 2, end);
        int rc = sqlite3_step(st);
        sqlite3_finalize(st);
        if (rc != SQLITE_DONE) return -1;
        total += sqlite3_changes(g_db);
        g_writes++;
    }
    *out = total;
    return 0;
}

static void vacuum(void) {
    (void)sqlite3_exec(g_db, "VACUUM;", NULL, NULL, NULL);
}

static int storage_delete_range(int fd, const jobject *a) {
    long long from = 0, to = 0;
    if (json_get_ll(a, "from", &from) != 0) return miss(fd, "from");
    if (json_get_ll(a, "to", &to) != 0) return miss(fd, "to");
    long long start = 0, end = 0;
    if (local_day_start(from, 0, &start) != 0 ||
        local_day_start(to, 1, &end) != 0) {
        reply(fd, "err bad-argument:from");
        return -1;
    }
    if (end <= start) {
        reply(fd, "ok 0");
        return 0;
    }
    long long n = 0;
    if (delete_between(start, end, &n) != 0) return reply_db_error(fd);
    vacuum();
    reply(fd, "ok %lld", n);
    return 0;
}

static int storage_delete_dates(int fd, const jobject *a) {
    long long days[366];
    int count = json_get_ll_array(a, "days", days, 366);
    if (count < 0) {
        reply(fd, "err bad-argument:days");
        return -1;
    }
    long long total = 0;
    for (int i = 0; i < count; i++) {
        long long start = 0, end = 0, n = 0;
        if (local_day_start(days[i], 0, &start) != 0 ||
            local_day_start(days[i], 1, &end) != 0) {
            reply(fd, "err bad-argument:days");
            return -1;
        }
        if (delete_between(start, end, &n) != 0) return reply_db_error(fd);
        total += n;
    }
    vacuum();
    reply(fd, "ok %lld", total);
    return 0;
}

static int storage_clear_all(int fd) {
    long long total = 0;
    static const char *const sql[] = {
        "DELETE FROM sessions;",
        "DELETE FROM focus_sessions;",
        "DELETE FROM events;",
    };
    for (int i = 0; i < 3; i++) {
        sqlite3_stmt *st = NULL;
        if (db_prepare(sql[i], &st) != 0) return reply_db_error(fd);
        int rc = sqlite3_step(st);
        sqlite3_finalize(st);
        if (rc != SQLITE_DONE) return reply_db_error(fd);
        total += sqlite3_changes(g_db);
        g_writes++;
    }
    exec_ignore("DELETE FROM active_focus_state;");
    exec_ignore("DELETE FROM settings WHERE key = 'last_notified_goal_50';");
    exec_ignore("DELETE FROM settings WHERE key = 'last_notified_goal_100';");
    exec_ignore("DELETE FROM settings WHERE key = 'overtime_milestone_date';");
    exec_ignore("DELETE FROM settings WHERE key = 'overtime_milestone_index';");
    vacuum();
    reply(fd, "ok %lld", total);
    return 0;
}

static int storage_close_orphans(int fd, const jobject *a) {
    long long max_duration = 10000;
    (void)json_get_ll(a, "maxDurationMs", &max_duration);
    long long preserve = -1;
    (void)json_get_ll(a, "preserveId", &preserve);

    sqlite3_stmt *st = NULL;
    if (db_prepare("SELECT id, started_at FROM sessions "
                   "WHERE ended_at IS NULL;", &st) != 0)
        return reply_db_error(fd);

    /* Materialise first: SQLite must not mutate the table under an open
     * SELECT cursor, and the Dart helper returns a full list before updating. */
    long long ids[8192];
    long long starts[8192];
    int count = 0;
    int overflow = 0;
    int rc;
    while ((rc = sqlite3_step(st)) == SQLITE_ROW) {
        if (count >= (int)(sizeof ids / sizeof ids[0])) {
            overflow = 1;
            break;
        }
        ids[count] = sqlite3_column_int64(st, 0);
        starts[count] = sqlite3_column_int64(st, 1);
        count++;
    }
    sqlite3_finalize(st);
    if (rc != SQLITE_DONE && !overflow) return reply_db_error(fd);

    long long repaired = 0;
    for (int i = 0; i < count; i++) {
        if (preserve >= 0 && ids[i] == preserve) continue;
        sqlite3_stmt *up = NULL;
        if (db_prepare("UPDATE sessions SET ended_at = ?, duration_ms = ? "
                       "WHERE id = ?;", &up) != 0)
            return reply_db_error(fd);
        sqlite3_bind_int64(up, 1, starts[i] + max_duration);
        sqlite3_bind_int64(up, 2, max_duration);
        sqlite3_bind_int64(up, 3, ids[i]);
        rc = sqlite3_step(up);
        sqlite3_finalize(up);
        if (rc != SQLITE_DONE) return reply_db_error(fd);
        repaired++;
        g_writes++;
    }
    reply(fd, "ok %lld", repaired);
    return 0;
}

static int storage_database_path(int fd) {
    char out[PATH_MAX * 2 + 8];
    sbuf b;
    sb_init(&b, out, sizeof out);
    sb_json_str(&b, g_db_path);
    reply(fd, "ok %s", b.buf);
    return 0;
}

static int storage_init(int fd, const jobject *a) {
    char requested[MAX_STRING];
    if (json_get_str(a, "path", requested, sizeof requested) == 0 &&
        strcmp(requested, g_db_path) != 0) {
        /* The worker owns one database for its whole life; a daemon asking
         * for another path must not silently move every other writer. */
        logmsg("ignoring init path %s (worker owns %s)", requested, g_db_path);
    }
    if (ensure_schema() != 0) return reply_db_error(fd);
    reply(fd, "ok null");
    return 0;
}

static void serve_storage(int fd, const char *method, const char *payload) {
    jobject args;
    memset(&args, 0, sizeof args);
    if (payload && *payload) {
        if (json_parse_object(payload, strlen(payload), &args) != 0) {
            reply(fd, "err bad-json");
            return;
        }
    }

    if (!strcmp(method, "recordEvent")) {
        storage_record_event(fd, &args);
    } else if (!strcmp(method, "openSession")) {
        storage_open_session(fd, &args);
    } else if (!strcmp(method, "closeSession")) {
        storage_close_session(fd, &args);
    } else if (!strcmp(method, "databaseFileSize")) {
        storage_database_file_size(fd);
    } else if (!strcmp(method, "sessionCount")) {
        storage_session_count(fd);
    } else if (!strcmp(method, "dayStartMs")) {
        storage_day_start(fd, &args, 0);
    } else if (!strcmp(method, "nextDayStartMs")) {
        storage_day_start(fd, &args, 1);
    } else if (!strcmp(method, "deleteSessionsInRange")) {
        storage_delete_range(fd, &args);
    } else if (!strcmp(method, "deleteSessionsOnDates")) {
        storage_delete_dates(fd, &args);
    } else if (!strcmp(method, "clearAllUsageData")) {
        storage_clear_all(fd);
    } else if (!strcmp(method, "closeOrphanedSessions")) {
        storage_close_orphans(fd, &args);
    } else if (!strcmp(method, "databaseFilePath")) {
        storage_database_path(fd);
    } else if (!strcmp(method, "init")) {
        storage_init(fd, &args);
    } else {
        reply(fd, "err unknown-method");
    }
}

static void serve_system(int fd, const char *method) {
    if (!strcmp(method, "ping")) {
        reply(fd, "ok pong");
    } else if (!strcmp(method, "status")) {
        int ready = db_ready();
        long long sessions = 0, events = 0;
        if (ready == 1) {
            (void)scalar_ll("SELECT COUNT(*) FROM sessions;", NULL, 0, &sessions);
            (void)scalar_ll("SELECT COUNT(*) FROM events;", NULL, 0, &events);
        }
        reply(fd, "ok pid=%ld db=%s ready=%d writes=%lld sessions=%lld "
                  "events=%lld uptime=%ld",
              (long)getpid(), g_db_path, ready == 1, g_writes, sessions,
              events, (long)(time(NULL) - g_started_at));
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
        payload = (char *)"";
    }

    if (!strcmp(domain, "system")) {
        serve_system(client, method);
    } else if (!strcmp(domain, "storage")) {
        serve_storage(client, method, payload);
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
        "The worker is the single writer for sessions and events. It creates\n"
        "the database when needed and answers the storage domain on\n"
        "$XDG_RUNTIME_DIR/screenguard/store.sock (SCREENGUARD_STORE_SOCKET).\n",
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
    ensure_db_dir();
    if (db_open() != 0) {
        fprintf(stderr, "store-check: cannot open %s: %s\n", g_db_path,
                strerror(errno));
        return 1;
    }
    if (ensure_schema() != 0) {
        fprintf(stderr, "store-check: cannot create schema in %s: %s\n",
                g_db_path, sqlite3_errmsg(g_db));
        return 1;
    }
    long long sessions = 0, events = 0;
    if (scalar_ll("SELECT COUNT(*) FROM sessions;", NULL, 0, &sessions) != 0 ||
        scalar_ll("SELECT COUNT(*) FROM events;", NULL, 0, &events) != 0) {
        fprintf(stderr, "store-check: db=%s schema=incomplete (%s)\n",
                g_db_path, sqlite3_errmsg(g_db));
        return 1;
    }
    printf("store-check: db=%s schema=ok sessions=%lld events=%lld\n",
           g_db_path, sessions, events);
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

    if (snprintf(g_socket_path, sizeof g_socket_path, "%s/store.sock",
                 runtime) >= (int)sizeof g_socket_path ||
        snprintf(g_lock_path, sizeof g_lock_path, "%s/store.lock",
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
        fprintf(stderr, "another digiwelld-store already owns %s\n", runtime);
        return 1;
    }
    if (g_lock_fd < 0) {
        fprintf(stderr, "cannot lock %s: %s\n", g_lock_path, strerror(errno));
        return 1;
    }

    ensure_db_dir();
    if (db_open() != 0) {
        fprintf(stderr, "cannot open %s: %s\n", g_db_path, strerror(errno));
        return 1;
    }
    if (ensure_schema() != 0) {
        fprintf(stderr, "cannot create schema in %s: %s\n", g_db_path,
                sqlite3_errmsg(g_db));
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
    logmsg("owns sessions, events and the schema (single writer)");

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
