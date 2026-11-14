/*
 * digiwelld-usage — read-only usage query worker for ScreenGuard.
 *
 * This is the second worker of the digiwelld migration. It owns exactly one
 * thing: answering the `usage` domain ("what happened?") from the SQLite
 * history. Every method mirrors DatabaseService one-for-one; the SQL below is
 * a deliberate copy of lib/services/db.dart, including its quirks, so moving
 * a caller from the Dart dispatch to this worker cannot change a number.
 *
 * What it deliberately does NOT do:
 *
 *   * write SQLite                    -> Dart daemon (until digiwelld-store)
 *   * observe windows or idle time    -> Dart tracker
 *   * apply limits or kill apps       -> digiwelld-enforce
 *   * mutate settings or policies     -> digiwelld-policy
 *
 * Ownership boundary during the migration:
 *
 *   digiwelld-usage   owns the usage read model (RUNTIME/usage.sock)
 *   Dart daemon       owns observation and every SQLite write
 *
 * The connection is opened READWRITE only because SQLite needs it for WAL
 * housekeeping; PRAGMA query_only=ON makes a write impossible by construction.
 * When digiwelld-store lands, this file swaps its one db_* layer for that
 * worker's socket and the SQL moves with the store.
 *
 * Protocol (same envelope as digiwelld and digiwelld-session):
 *
 *   request   <domain> <method> <json-object>
 *   response  ok <json>
 *             err <reason>
 *
 * Domains: system, usage. One request per connection.
 *
 * Build:
 *   cc -O2 -Wall -Wextra -std=c99 -o digiwelld-usage src/usage.c -lsqlite3
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
#define DEFAULT_LIMIT    200
#define MAX_LIMIT        2000
#define DEFAULT_SHELLS   "'unknown','com.example.screenguard','screenguard'," \
                         "'xfdesktop','nemo-desktop','plasmashell'," \
                         "'gnome-shell','mutter'"

/* Same filter as DatabaseService._excludedAppsFilter. Keep the two in sync:
 * a divergence here would silently change every total.
 *
 * The doubled percent is deliberate: every use of this macro sits inside a
 * snprintf format string, where a lone '%' would be read as a conversion. */
#define EXCLUDED_APPS \
    "app NOT IN (" DEFAULT_SHELLS ") AND app NOT LIKE 'window:%%'"

static volatile sig_atomic_t g_stop = 0;

static char g_runtime[PATH_MAX];
static char g_socket_path[PATH_MAX];
static char g_lock_path[PATH_MAX];
static char g_db_path[PATH_MAX];

static int g_listen_fd = -1;
static int g_lock_fd = -1;
static int g_verbose = 0;
static long long g_started_at = 0;
static long long g_queries = 0;

static sqlite3 *g_db = NULL;

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

    fprintf(stderr, "[digiwelld-usage %s] %s\n", stamp, msg);
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

/* ----------------------------------------------------------------- date math */

/* Local midnight for the calendar day containing [at_ms]. mktime with
 * tm_isdst=-1 lets the C library resolve DST exactly like DateTime(y,m,d). */
static long long local_midnight_ms(long long at_ms) {
    time_t sec = (time_t)(at_ms / 1000);
    struct tm tm;
    if (!localtime_r(&sec, &tm)) return -1;
    tm.tm_hour = 0;
    tm.tm_min = 0;
    tm.tm_sec = 0;
    tm.tm_isdst = -1;
    time_t out = mktime(&tm);
    return out == (time_t)-1 ? -1 : (long long)out * 1000LL;
}

/* Calendar-day arithmetic, not 24h arithmetic: crossing DST must still land
 * on local midnight, which is what every Dart call site means by "a day". */
static long long add_days_ms(long long midnight_ms, int days) {
    time_t sec = (time_t)(midnight_ms / 1000);
    struct tm tm;
    if (!localtime_r(&sec, &tm)) return -1;
    tm.tm_mday += days;
    tm.tm_hour = 0;
    tm.tm_min = 0;
    tm.tm_sec = 0;
    tm.tm_isdst = -1;
    time_t out = mktime(&tm);
    return out == (time_t)-1 ? -1 : (long long)out * 1000LL;
}

static void date_key(long long at_ms, char out[16]) {
    time_t sec = (time_t)(at_ms / 1000);
    struct tm tm;
    if (!localtime_r(&sec, &tm)) {
        snprintf(out, 16, "1970-01-01");
        return;
    }
    strftime(out, 16, "%Y-%m-%d", &tm);
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
    /* Belt and braces: this process has no business writing. */
    if (sqlite3_exec(db, "PRAGMA query_only=ON;", NULL, NULL, NULL) !=
        SQLITE_OK) {
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
    sqlite3_stmt *st = NULL;
    if (sqlite3_prepare_v2(g_db,
            "SELECT 1 FROM sqlite_master WHERE type='table' "
            "AND name='sessions' LIMIT 1;", -1, &st, NULL) != SQLITE_OK) {
        return 0;
    }
    int ok = sqlite3_step(st) == SQLITE_ROW;
    sqlite3_finalize(st);
    return ok ? 1 : 0;
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
            char key[MAX_STRING];
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

static long long json_ll_or(const jobject *obj, const char *key,
                            long long dflt) {
    long long v;
    return json_get_ll(obj, key, &v) == 0 ? v : dflt;
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

/* ------------------------------------------------------------- query helpers */

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

/* Bind app names starting at [first]. Returns the next unused parameter. */
static int bind_apps(sqlite3_stmt *st, int first, const char *app,
                     char aliases[][MAX_STRING], int alias_count) {
    int idx = first;
    int have_app = 0;
    for (int i = 0; i < alias_count; i++) {
        if (!strcmp(aliases[i], app)) have_app = 1;
    }
    if (!have_app) {
        sqlite3_bind_text(st, idx++, app, -1, SQLITE_STATIC);
    }
    for (int i = 0; i < alias_count; i++) {
        sqlite3_bind_text(st, idx++, aliases[i], -1, SQLITE_STATIC);
    }
    return idx;
}

static int build_in_list(char *out, size_t cap, int n) {
    size_t off = 0;
    for (int i = 0; i < n; i++) {
        int w = snprintf(out + off, cap - off, "%s?", i ? "," : "");
        if (w < 0 || (size_t)w >= cap - off) return -1;
        off += (size_t)w;
    }
    return 0;
}

/* needed = 1 (app) + alias_count - 1 when the app is already listed. */
static int apps_count(const char *app, char aliases[][MAX_STRING],
                      int alias_count) {
    for (int i = 0; i < alias_count; i++) {
        if (!strcmp(aliases[i], app)) return alias_count;
    }
    return alias_count + 1;
}

/* Total lived milliseconds for a WHERE fragment, with the open-session
 * formula exactly as DatabaseService writes it. */
static int sum_ms(const char *where, const long long *prefix, int nprefix,
                  const long long *suffix, int nsuffix, long long *out) {
    char sql[1024];
    snprintf(sql, sizeof sql,
             "SELECT COALESCE(SUM(CASE WHEN ended_at IS NULL "
             "THEN MAX(0, ? - started_at) ELSE duration_ms END), 0) AS t "
             "FROM sessions WHERE %s;", where);
    sqlite3_stmt *st = NULL;
    if (db_prepare(sql, &st) != 0) return -1;
    int idx = 1;
    sqlite3_bind_int64(st, idx++, prefix[0]);
    for (int i = 1; i < nprefix; i++) {
        sqlite3_bind_int64(st, idx++, prefix[i]);
    }
    for (int i = 0; i < nsuffix; i++) {
        sqlite3_bind_int64(st, idx++, suffix[i]);
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

/* ------------------------------------------------------------- usage methods */

static int send_events(int fd, const char *sql, const long long *params,
                       int nparams) {
    sqlite3_stmt *st = NULL;
    if (db_prepare(sql, &st) != 0) return reply_db_error(fd);
    for (int i = 0; i < nparams; i++) {
        sqlite3_bind_int64(st, i + 1, params[i]);
    }
    char buf[MAX_RESPONSE];
    sbuf b;
    sb_init(&b, buf, sizeof buf);
    sb_puts(&b, "[");
    int first = 1;
    int rc;
    while ((rc = sqlite3_step(st)) == SQLITE_ROW) {
        if (!b.overflow) {
            if (!first) sb_puts(&b, ",");
            sb_puts(&b, "{\"id\":");
            sb_col_int(&b, st, 0);
            sb_puts(&b, ",\"at\":");
            sb_col_int(&b, st, 1);
            sb_puts(&b, ",\"kind\":");
            sb_col_text(&b, st, 2);
            sb_puts(&b, ",\"app\":");
            sb_col_text(&b, st, 3);
            sb_puts(&b, ",\"detail\":");
            sb_col_text(&b, st, 4);
            sb_putc(&b, '}');
        }
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

static int usage_recent_events(int fd, const jobject *args) {
    long long limit = json_ll_or(args, "limit", DEFAULT_LIMIT);
    if (limit <= 0) limit = 1;
    if (limit > MAX_LIMIT) limit = MAX_LIMIT;
    return send_events(fd,
        "SELECT id, at, kind, app, detail FROM events "
        "ORDER BY at DESC, id DESC LIMIT ?;", &limit, 1);
}

static int usage_event_count(int fd) {
    long long n = 0;
    if (scalar_ll("SELECT COUNT(*) FROM events;", NULL, 0, &n) != 0)
        return reply_db_error(fd);
    reply(fd, "ok %lld", n);
    return 0;
}

static int usage_events_for_day(int fd, const jobject *args) {
    long long at;
    if (json_get_ll(args, "day", &at) != 0) {
        reply(fd, "err missing-argument:day");
        return -1;
    }
    long long start = local_midnight_ms(at);
    long long end = add_days_ms(start, 1);
    long long params[2] = { start, end };
    return send_events(fd,
        "SELECT id, at, kind, app, detail FROM events "
        "WHERE at >= ? AND at < ? ORDER BY at, id;", params, 2);
}

static int usage_total_today(int fd) {
    long long now = wall_ms();
    long long start = local_midnight_ms(now);
    char where[512];
    snprintf(where, sizeof where, "idle=0 AND " EXCLUDED_APPS
             " AND started_at >= ?");
    long long prefix[1] = { now };
    long long suffix[1] = { start };
    long long total = 0;
    if (sum_ms(where, prefix, 1, suffix, 1, &total) != 0)
        return reply_db_error(fd);
    reply(fd, "ok %lld", total);
    return 0;
}

static int usage_total_yesterday(int fd) {
    long long now = wall_ms();
    long long today = local_midnight_ms(now);
    long long start = add_days_ms(today, -1);
    long long end = today - 1;
    char where[512];
    snprintf(where, sizeof where, "idle=0 AND " EXCLUDED_APPS
             " AND started_at >= ? AND started_at <= ?");
    long long prefix[1] = { end };
    long long suffix[2] = { start, end };
    long long total = 0;
    if (sum_ms(where, prefix, 1, suffix, 2, &total) != 0)
        return reply_db_error(fd);
    reply(fd, "ok %lld", total);
    return 0;
}

static int usage_app_history(int fd, const jobject *args) {
    char app[MAX_STRING];
    if (json_get_str(args, "app", app, sizeof app) != 0) {
        reply(fd, "err missing-argument:app");
        return -1;
    }
    long long days = json_ll_or(args, "days", 7);
    char buf[MAX_RESPONSE];
    sbuf b;
    sb_init(&b, buf, sizeof buf);
    sb_puts(&b, "[");

    if (days > 0) {
        if (days > 3650) days = 3650;
        long long now = wall_ms();
        long long start = add_days_ms(local_midnight_ms(now), -(int)(days - 1));
        sqlite3_stmt *st = NULL;
        if (db_prepare(
                "SELECT date(started_at/1000,'unixepoch','localtime') AS d, "
                "SUM(duration_ms) AS t FROM sessions "
                "WHERE idle=0 AND app = ? AND started_at >= ? "
                "GROUP BY d ORDER BY d;", &st) != 0) {
            return reply_db_error(fd);
        }
        sqlite3_bind_text(st, 1, app, -1, SQLITE_STATIC);
        sqlite3_bind_int64(st, 2, start);
        int first = 1;
        int rc;
        while ((rc = sqlite3_step(st)) == SQLITE_ROW) {
            if (!first) sb_puts(&b, ",");
            sb_puts(&b, "{\"d\":");
            sb_col_text(&b, st, 0);
            sb_puts(&b, ",\"t\":");
            sb_col_int(&b, st, 1);
            sb_putc(&b, '}');
            first = 0;
        }
        sqlite3_finalize(st);
        if (rc != SQLITE_DONE) return reply_db_error(fd);
    }

    sb_puts(&b, "]");
    if (b.overflow) {
        reply(fd, "err response-too-large");
        return -1;
    }
    reply(fd, "ok %s", b.buf);
    return 0;
}

static int usage_recent_unknown(int fd, const jobject *args) {
    long long minutes = json_ll_or(args, "minutes", 10);
    if (minutes < 0) minutes = 0;
    long long since = wall_ms() - minutes * 60LL * 1000LL;
    long long params[1] = { since };
    long long n = 0;
    if (scalar_ll("SELECT COUNT(*) FROM sessions WHERE app = 'unknown' "
                  "AND started_at >= ?;", params, 1, &n) != 0)
        return reply_db_error(fd);
    reply(fd, "ok %lld", n);
    return 0;
}

static int usage_app_today(int fd, const jobject *args) {
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

    long long now = wall_ms();
    long long start = local_midnight_ms(now);
    char inlist[256];
    int napps = apps_count(app, aliases, na);
    if (build_in_list(inlist, sizeof inlist, napps) != 0) {
        reply(fd, "err too-many-aliases");
        return -1;
    }
    char sql[1024];
    snprintf(sql, sizeof sql,
             "SELECT COALESCE(SUM(CASE WHEN ended_at IS NULL "
             "THEN MAX(0, ? - started_at) ELSE duration_ms END), 0) AS t "
             "FROM sessions WHERE idle=0 AND app IN (%s) AND started_at >= ?;",
             inlist);
    sqlite3_stmt *st = NULL;
    if (db_prepare(sql, &st) != 0) return reply_db_error(fd);
    sqlite3_bind_int64(st, 1, now);
    int next = bind_apps(st, 2, app, aliases, na);
    sqlite3_bind_int64(st, next, start);
    int rc = sqlite3_step(st);
    if (rc != SQLITE_ROW) {
        sqlite3_finalize(st);
        return reply_db_error(fd);
    }
    long long total = sqlite3_column_int64(st, 0);
    sqlite3_finalize(st);
    reply(fd, "ok %lld", total);
    return 0;
}

/* Nullable: an app with no non-idle session has no activity timestamp. */
static int last_activity(const char *app,
                         char aliases[][MAX_STRING], int na,
                         long long *out, int *is_null) {
    char inlist[256];
    int napps = apps_count(app, aliases, na);
    if (build_in_list(inlist, sizeof inlist, napps) != 0) return -1;
    char sql[1024];
    snprintf(sql, sizeof sql,
             "SELECT MAX(CASE WHEN ended_at IS NULL THEN ? ELSE ended_at END) "
             "FROM sessions WHERE idle=0 AND app IN (%s);", inlist);
    sqlite3_stmt *st = NULL;
    if (db_prepare(sql, &st) != 0) return -1;
    long long now = wall_ms();
    sqlite3_bind_int64(st, 1, now);
    (void)bind_apps(st, 2, app, aliases, na);
    int rc = sqlite3_step(st);
    if (rc != SQLITE_ROW) {
        sqlite3_finalize(st);
        return -1;
    }
    if (sqlite3_column_type(st, 0) == SQLITE_NULL) {
        *is_null = 1;
        *out = 0;
    } else {
        *is_null = 0;
        *out = sqlite3_column_int64(st, 0);
    }
    sqlite3_finalize(st);
    return 0;
}

static int usage_last_activity(int fd, const jobject *args) {
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
    long long last = 0;
    int is_null = 0;
    if (last_activity(app, aliases, na, &last, &is_null) != 0)
        return reply_db_error(fd);
    if (is_null) reply(fd, "ok null");
    else reply(fd, "ok %lld", last);
    return 0;
}

static int usage_is_inactive(int fd, const jobject *args) {
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
    long long after = json_ll_or(args, "inactiveAfterMs", 12LL * 60 * 60 * 1000);
    long long last = 0;
    int is_null = 0;
    if (last_activity(app, aliases, na, &last, &is_null) != 0)
        return reply_db_error(fd);
    int inactive = is_null || (wall_ms() - last >= after);
    reply(fd, "ok %s", inactive ? "true" : "false");
    return 0;
}

static int usage_inactive_apps(int fd, const jobject *args) {
    long long after = json_ll_or(args, "inactiveAfterMs", 12LL * 60 * 60 * 1000);
    long long now = wall_ms();
    long long cutoff = now - after;
    char sql[1024];
    snprintf(sql, sizeof sql,
             "SELECT app, MAX(CASE WHEN ended_at IS NULL THEN ? "
             "ELSE ended_at END) AS last FROM sessions WHERE " EXCLUDED_APPS
             " GROUP BY app HAVING last < ? ORDER BY last;");
    sqlite3_stmt *st = NULL;
    if (db_prepare(sql, &st) != 0) return reply_db_error(fd);
    sqlite3_bind_int64(st, 1, now);
    sqlite3_bind_int64(st, 2, cutoff);
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

static void focus_row_json(sbuf *b, sqlite3_stmt *st) {
    sb_puts(b, "{\"id\":");
    sb_col_int(b, st, 0);
    sb_puts(b, ",\"started_at\":");
    sb_col_int(b, st, 1);
    sb_puts(b, ",\"ended_at\":");
    sb_col_int(b, st, 2);
    sb_puts(b, ",\"duration_minutes\":");
    sb_col_int(b, st, 3);
    sb_puts(b, ",\"completed\":");
    sb_col_int(b, st, 4);
    sb_putc(b, '}');
}

static int usage_last_focus(int fd) {
    sqlite3_stmt *st = NULL;
    if (db_prepare("SELECT id, started_at, ended_at, duration_minutes, "
                   "completed FROM focus_sessions ORDER BY id DESC LIMIT 1;",
                   &st) != 0) {
        return reply_db_error(fd);
    }
    int rc = sqlite3_step(st);
    if (rc == SQLITE_DONE) {
        sqlite3_finalize(st);
        reply(fd, "ok null");
        return 0;
    }
    if (rc != SQLITE_ROW) {
        sqlite3_finalize(st);
        return reply_db_error(fd);
    }
    char buf[MAX_RESPONSE];
    sbuf b;
    sb_init(&b, buf, sizeof buf);
    focus_row_json(&b, st);
    sqlite3_finalize(st);
    reply(fd, "ok %s", b.buf);
    return 0;
}

static int usage_completed_focus(int fd) {
    long long now = wall_ms();
    long long start = local_midnight_ms(now);
    long long params[1] = { start };
    long long n = 0;
    if (scalar_ll("SELECT COUNT(*) FROM focus_sessions "
                  "WHERE completed = 1 AND started_at >= ?;",
                  params, 1, &n) != 0)
        return reply_db_error(fd);
    reply(fd, "ok %lld", n);
    return 0;
}

static int usage_tracked_apps(int fd) {
    char sql[1024];
    snprintf(sql, sizeof sql,
             "SELECT app, COALESCE(app_name, app) AS app_name, "
             "SUM(duration_ms) AS t FROM sessions WHERE " EXCLUDED_APPS
             " GROUP BY app ORDER BY app_name ASC;");
    sqlite3_stmt *st = NULL;
    if (db_prepare(sql, &st) != 0) return reply_db_error(fd);
    char buf[MAX_RESPONSE];
    sbuf b;
    sb_init(&b, buf, sizeof buf);
    sb_puts(&b, "[");
    int first = 1;
    int rc;
    while ((rc = sqlite3_step(st)) == SQLITE_ROW) {
        if (!first) sb_puts(&b, ",");
        sb_puts(&b, "{\"app\":");
        sb_col_text(&b, st, 0);
        sb_puts(&b, ",\"app_name\":");
        sb_col_text(&b, st, 1);
        sb_puts(&b, ",\"t\":");
        sb_col_int(&b, st, 2);
        sb_putc(&b, '}');
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

static int usage_per_app_date(int fd, const jobject *args) {
    long long at;
    if (json_get_ll(args, "date", &at) != 0) {
        reply(fd, "err missing-argument:date");
        return -1;
    }
    long long limit = json_ll_or(args, "limit", 10);
    if (limit <= 0) limit = 1;
    if (limit > MAX_LIMIT) limit = MAX_LIMIT;

    long long start = local_midnight_ms(at);
    long long end = add_days_ms(start, 1) - 1;
    long long now = wall_ms();
    long long effective_end = end < now ? end : now;

    char sql[1024];
    snprintf(sql, sizeof sql,
             "SELECT app, app_name, SUM(CASE WHEN ended_at IS NULL "
             "THEN MAX(0, ? - started_at) ELSE duration_ms END) AS t "
             "FROM sessions WHERE idle=0 AND " EXCLUDED_APPS
             " AND started_at >= ? AND started_at <= ? "
             "GROUP BY app ORDER BY t DESC LIMIT ?;");
    sqlite3_stmt *st = NULL;
    if (db_prepare(sql, &st) != 0) return reply_db_error(fd);
    sqlite3_bind_int64(st, 1, effective_end);
    sqlite3_bind_int64(st, 2, start);
    sqlite3_bind_int64(st, 3, end);
    sqlite3_bind_int64(st, 4, limit);
    char buf[MAX_RESPONSE];
    sbuf b;
    sb_init(&b, buf, sizeof buf);
    sb_puts(&b, "[");
    int first = 1;
    int rc;
    while ((rc = sqlite3_step(st)) == SQLITE_ROW) {
        if (!first) sb_puts(&b, ",");
        sb_puts(&b, "{\"app\":");
        sb_col_text(&b, st, 0);
        sb_puts(&b, ",\"app_name\":");
        sb_col_text(&b, st, 1);
        sb_puts(&b, ",\"t\":");
        sb_col_int(&b, st, 2);
        sb_putc(&b, '}');
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

static int usage_idle_for_date(int fd, const jobject *args) {
    long long at;
    if (json_get_ll(args, "date", &at) != 0) {
        reply(fd, "err missing-argument:date");
        return -1;
    }
    long long start = local_midnight_ms(at);
    long long end = add_days_ms(start, 1) - 1;
    long long now = wall_ms();
    long long effective_end = end < now ? end : now;

    char sql[1024];
    snprintf(sql, sizeof sql,
             "SELECT COALESCE(SUM(CASE WHEN ended_at IS NULL "
             "THEN MAX(0, ? - started_at) ELSE duration_ms END), 0) AS t "
             "FROM sessions WHERE idle=1 AND started_at >= ? "
             "AND started_at <= ?;");
    sqlite3_stmt *st = NULL;
    if (db_prepare(sql, &st) != 0) return reply_db_error(fd);
    sqlite3_bind_int64(st, 1, effective_end);
    sqlite3_bind_int64(st, 2, start);
    sqlite3_bind_int64(st, 3, end);
    int rc = sqlite3_step(st);
    if (rc != SQLITE_ROW) {
        sqlite3_finalize(st);
        return reply_db_error(fd);
    }
    long long total = sqlite3_column_int64(st, 0);
    sqlite3_finalize(st);
    reply(fd, "ok %lld", total);
    return 0;
}

static int usage_week_data(int fd, const jobject *args) {
    long long offset = json_ll_or(args, "weekOffset", 0);
    if (offset < -520) offset = -520;
    if (offset > 520) offset = 520;

    long long now = wall_ms();
    long long today = local_midnight_ms(now);
    long long end_window = add_days_ms(today, (int)(-offset * 7));
    long long start_window = add_days_ms(end_window, -6);

    char buf[MAX_RESPONSE];
    sbuf b;
    sb_init(&b, buf, sizeof buf);
    sb_puts(&b, "[");
    for (int i = 0; i < 7; i++) {
        long long day_start = add_days_ms(start_window, i);
        long long day_end = add_days_ms(start_window, i + 1) - 1;
        long long effective_end = day_end < now ? day_end : now;

        char sql[1024];
        snprintf(sql, sizeof sql,
                 "SELECT COALESCE(SUM(CASE WHEN ended_at IS NULL "
                 "THEN MAX(0, ? - started_at) ELSE duration_ms END), 0) AS t "
                 "FROM sessions WHERE idle=0 AND " EXCLUDED_APPS
                 " AND started_at >= ? AND started_at <= ?;");
        sqlite3_stmt *st = NULL;
        if (db_prepare(sql, &st) != 0) return reply_db_error(fd);
        sqlite3_bind_int64(st, 1, effective_end);
        sqlite3_bind_int64(st, 2, day_start);
        sqlite3_bind_int64(st, 3, day_end);
        int rc = sqlite3_step(st);
        if (rc != SQLITE_ROW) {
            sqlite3_finalize(st);
            return reply_db_error(fd);
        }
        long long total = sqlite3_column_int64(st, 0);
        sqlite3_finalize(st);

        char dk[16];
        date_key(day_start, dk);
        if (i) sb_puts(&b, ",");
        sb_puts(&b, "{\"d\":");
        sb_json_str(&b, dk);
        sb_printf(&b, ",\"t\":%lld,\"date\":{\"__dt\":%lld}}", total,
                  day_start);
    }
    sb_puts(&b, "]");
    if (b.overflow) {
        reply(fd, "err response-too-large");
        return -1;
    }
    reply(fd, "ok %s", b.buf);
    return 0;
}

static int usage_last30(int fd) {
    long long now = wall_ms();
    long long start = add_days_ms(local_midnight_ms(now), -29);
    char where[512];
    snprintf(where, sizeof where, "idle=0 AND " EXCLUDED_APPS
             " AND started_at >= ?");
    long long prefix[1] = { now };
    long long suffix[1] = { start };
    long long total = 0;
    if (sum_ms(where, prefix, 1, suffix, 1, &total) != 0)
        return reply_db_error(fd);
    reply(fd, "ok %lld", total);
    return 0;
}

static int usage_date_range(int fd) {
    sqlite3_stmt *st = NULL;
    if (db_prepare("SELECT MIN(started_at), MAX(started_at) FROM sessions;",
                   &st) != 0) {
        return reply_db_error(fd);
    }
    int rc = sqlite3_step(st);
    if (rc != SQLITE_ROW || sqlite3_column_type(st, 0) == SQLITE_NULL ||
        sqlite3_column_type(st, 1) == SQLITE_NULL) {
        sqlite3_finalize(st);
        reply(fd, "ok null");
        return 0;
    }
    long long lo = sqlite3_column_int64(st, 0);
    long long hi = sqlite3_column_int64(st, 1);
    sqlite3_finalize(st);
    reply(fd, "ok [%lld,%lld]", lo, hi);
    return 0;
}

static void serve_usage(int fd, const char *method, const char *payload) {
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
        /* A first boot before the daemon creates the schema is not a crash:
         * every later request re-checks, so the worker heals by itself. */
        reply(fd, "err database-not-ready");
        return;
    }

    g_queries++;
    int matched = 1;
    if (!strcmp(method, "recentEvents")) {
        usage_recent_events(fd, &args);
    } else if (!strcmp(method, "eventCount")) {
        usage_event_count(fd);
    } else if (!strcmp(method, "eventsForDay")) {
        usage_events_for_day(fd, &args);
    } else if (!strcmp(method, "todayTotalMs")) {
        usage_total_today(fd);
    } else if (!strcmp(method, "yesterdayTotalMs")) {
        usage_total_yesterday(fd);
    } else if (!strcmp(method, "appHistory")) {
        usage_app_history(fd, &args);
    } else if (!strcmp(method, "recentUnknownSessions")) {
        usage_recent_unknown(fd, &args);
    } else if (!strcmp(method, "getAppTodayMs")) {
        usage_app_today(fd, &args);
    } else if (!strcmp(method, "lastAppActivityMs")) {
        usage_last_activity(fd, &args);
    } else if (!strcmp(method, "isAppInactive")) {
        usage_is_inactive(fd, &args);
    } else if (!strcmp(method, "inactiveApps")) {
        usage_inactive_apps(fd, &args);
    } else if (!strcmp(method, "getLastFocusSession")) {
        usage_last_focus(fd);
    } else if (!strcmp(method, "getCompletedFocusSessionsToday")) {
        usage_completed_focus(fd);
    } else if (!strcmp(method, "allTrackedApps")) {
        usage_tracked_apps(fd);
    } else if (!strcmp(method, "perAppForDate")) {
        usage_per_app_date(fd, &args);
    } else if (!strcmp(method, "getIdleTimeForDate")) {
        usage_idle_for_date(fd, &args);
    } else if (!strcmp(method, "getWeekData")) {
        usage_week_data(fd, &args);
    } else if (!strcmp(method, "last30DaysTotalMs")) {
        usage_last30(fd);
    } else if (!strcmp(method, "sessionDateRange")) {
        usage_date_range(fd);
    } else {
        matched = 0;
    }
    if (!matched) reply(fd, "err unknown-method");
}

static void serve_system(int fd, const char *method) {
    if (!strcmp(method, "ping")) {
        reply(fd, "ok pong");
    } else if (!strcmp(method, "status")) {
        int ready = db_ready();
        reply(fd,
              "ok pid=%ld db=%s ready=%d queries=%lld uptime=%ld",
              (long)getpid(), g_db_path, ready == 1, g_queries,
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
    } else if (!strcmp(domain, "usage")) {
        serve_usage(client, method, payload);
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
        "  --db PATH       SQLite usage database (default XDG_DATA_HOME/screenguard/usage.db)\n"
        "  --check         open the database, report its schema, and exit\n"
        "  --verbose       log requests and SQL failures\n"
        "  -h, --help      this text\n"
        "\n"
        "The worker is a read-only read model: PRAGMA query_only=ON is set at\n"
        "open time. All writes stay with the Dart daemon until digiwelld-store.\n",
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
        fprintf(stderr, "usage-check: cannot open %s: %s\n", g_db_path,
                strerror(errno));
        return 1;
    }
    long long sessions = 0, events = 0;
    if (!db_ready() ||
        scalar_ll("SELECT COUNT(*) FROM sessions;", NULL, 0, &sessions) != 0 ||
        scalar_ll("SELECT COUNT(*) FROM events;", NULL, 0, &events) != 0) {
        fprintf(stderr, "usage-check: db=%s schema=missing (%s)\n", g_db_path,
                sqlite3_errmsg(g_db));
        return 1;
    }
    printf("usage-check: db=%s schema=ok sessions=%lld events=%lld\n",
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

    if (snprintf(g_socket_path, sizeof g_socket_path, "%s/usage.sock",
                 runtime) >= (int)sizeof g_socket_path ||
        snprintf(g_lock_path, sizeof g_lock_path, "%s/usage.lock",
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
        fprintf(stderr, "another digiwelld-usage already owns %s\n", runtime);
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
    logmsg("read-only read model; SQLite writes stay with the Dart daemon");

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
