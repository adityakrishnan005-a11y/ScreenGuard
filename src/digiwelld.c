/*
 * digiwelld — ScreenGuard's native supervisor and front door.
 *
 * Boundary work only; no domain logic:
 *
 *   1. SINGLETON   exclusive flock() on digiwelld.lock, held for the process life
 *   2. AUTHORITY   SO_PEERCRED uid check on every accepted connection
 *   3. ROUTING     domain.method requests -> daemon backend socket
 *   4. WRITE LOCK  exclusive flock() on storage.lock around storage.* requests
 *   5. SUPERVISION fork/exec the Dart daemon, the session worker, the usage
 *                  read model, the policy worker and the store worker; restart
 *                  crashes with backoff, stop after a crash budget
 *   6. ALWAYS ON   system.ping / system.status answer even when a child is down
 *
 * Supervision policy (absorbed from the former screenguard-watchdog):
 *
 *   - exit code 0 means the child chose to stop; it is not restarted
 *   - a non-zero exit or fatal signal is a crash; a JSON report is written to
 *     $XDG_DATA_HOME/screenguard/crashes/crash_<epoch>.json
 *   - restarts back off 2s, 4s, 8s, 16s, then 30s
 *   - MAX_CRASHES crashes inside WINDOW_SEC stop that child permanently and
 *     raise one desktop notification; the front door keeps serving system.*
 *   - a crash after a full quiet window starts the budget over
 *
 * The child policies are independent: a broken session worker must not
 * consume the daemon's budget, and vice versa. `system restart` clears every
 * budget and respawns (the GUI's escape hatch after a give-up).
 *
 * Protocol: one request per connection, newline terminated.
 *
 *   request   <domain> <method> <opaque payload>\n
 *   response  ok <opaque payload>\n
 *             err <reason>\n
 *
 * Domains: system (handled here), usage, policy, tracking, storage (routed).
 * The supervisor never parses payloads; it validates the envelope and forwards.
 *
 * Build:
 *   cc -O2 -Wall -Wextra -o digiwelld src/digiwelld.c
 */

#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <poll.h>
#include <signal.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/file.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/time.h>
#include <sys/un.h>
#include <sys/wait.h>
#include <syslog.h>
#include <time.h>
#include <unistd.h>

#define MAX_REQUEST     65536
#define MAX_RESPONSE    65536
#define BACKLOG         32
#define SOCK_MODE       0600
#define DIR_MODE        0700
#define IO_TIMEOUT_SEC  3
#define SHUTDOWN_GRACE  5

/* Defaults match the former watchdog exactly. They can be overridden from
 * the environment for tests and for unusually slow machines. */
#define DEFAULT_MAX_CRASHES      5
#define DEFAULT_WINDOW_SEC       300
#define DEFAULT_RESTART_DELAY_MS 2000
#define DEFAULT_MAX_DELAY_MS     30000
#define MAX_CRASH_LIMIT          1000
#define MAX_WINDOW_SEC           86400

static volatile sig_atomic_t g_stop = 0;
static volatile sig_atomic_t g_restart_requested = 0;

static char g_runtime[PATH_MAX];
static char g_sock_path[PATH_MAX];
static char g_backend_path[PATH_MAX];
static char g_lock_path[PATH_MAX];
static char g_storage_lock_path[PATH_MAX];
static char g_data_dir[PATH_MAX];

static int   g_lock_fd = -1;
static int   g_storage_fd = -1;
static int   g_listen_fd = -1;

static int g_max_crashes      = DEFAULT_MAX_CRASHES;
static int g_window_sec       = DEFAULT_WINDOW_SEC;
static int g_initial_delay_ms = DEFAULT_RESTART_DELAY_MS;
static int g_max_delay_ms     = DEFAULT_MAX_DELAY_MS;

/* A supervised child. The supervisor deliberately knows nothing about what
 * the child does; it only starts it, reaps it, applies the crash budget and
 * stops it on shutdown. Every child shares the policy but keeps separate
 * counters. */
typedef struct {
    const char *name;
    const char *path;
    char       *argv[64];
    int         argc;
    pid_t       pid;
    time_t      started;
    long        backoff_ms;
    long        next_spawn_ms;
    int         enabled;

    /* crash budget */
    int         crash_count;
    time_t      window_start;
    int         stopped;      /* exited cleanly, waiting for an explicit start */
    int         gave_up;      /* crash budget exhausted */
} child_proc;

static child_proc g_daemon = {
    .name = "daemon", .pid = -1
};
static child_proc g_session = {
    .name = "session-worker", .pid = -1
};
static child_proc g_usage = {
    .name = "usage-worker", .pid = -1
};
static child_proc g_policy = {
    .name = "policy-worker", .pid = -1
};
static child_proc g_store = {
    .name = "store-worker", .pid = -1
};
static char g_session_socket[PATH_MAX];
static char g_usage_socket[PATH_MAX];
static char g_policy_socket[PATH_MAX];
static char g_store_socket[PATH_MAX];
static int  g_no_spawn = 0;
static time_t g_started_at = 0;

/* ------------------------------------------------------------------ utils */

static long now_ms(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec * 1000L + ts.tv_nsec / 1000000L;
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

    fprintf(stderr, "[digiwelld %s] %s\n", stamp, msg);
    fflush(stderr);
    syslog(LOG_INFO, "%s", msg);
}

static void on_signal(int sig) {
    (void)sig;
    g_stop = 1;
}

static int env_int(const char *name, int dflt, int min, int max) {
    const char *raw = getenv(name);
    if (!raw || !*raw) return dflt;
    char *end = NULL;
    errno = 0;
    long v = strtol(raw, &end, 10);
    if (errno != 0 || end == raw || *end != '\0') return dflt;
    if (v < min) v = min;
    if (v > max) v = max;
    return (int)v;
}

static int mkdir_private(const char *path) {
    if (mkdir(path, DIR_MODE) == 0) {
        chmod(path, DIR_MODE);
        return 0;
    }
    if (errno == EEXIST) {
        struct stat st;
        if (stat(path, &st) == 0 && S_ISDIR(st.st_mode)) {
            /* Refuse to serve from a directory other users can enter. */
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
    /* Linux local boundary is the uid. Different users never reach the router. */
    if (cred.uid != geteuid()) {
        logmsg("reject uid=%ld (supervisor uid=%ld)",
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

/* --------------------------------------------------------------- crash log */

/* $XDG_DATA_HOME/screenguard, matching CrashReporter._resolveDataDir(). */
static void resolve_data_dir(void) {
    const char *xdg = getenv("XDG_DATA_HOME");
    const char *home = getenv("HOME");
    if (xdg && *xdg)
        snprintf(g_data_dir, sizeof g_data_dir, "%s/screenguard", xdg);
    else if (home && *home)
        snprintf(g_data_dir, sizeof g_data_dir, "%s/.local/share/screenguard",
                 home);
    else
        snprintf(g_data_dir, sizeof g_data_dir, "/tmp/.screenguard");
}

static void write_crash_log(const child_proc *child, int exit_code) {
    char dir[PATH_MAX + 16];
    char path[PATH_MAX + 64];
    time_t now = time(NULL);
    struct tm tm;
    localtime_r(&now, &tm);

    char ts[64];
    strftime(ts, sizeof ts, "%Y-%m-%dT%H:%M:%S%z", &tm);

    if (mkdir(g_data_dir, 0755) < 0 && errno != EEXIST) return;
    snprintf(dir, sizeof dir, "%s/crashes", g_data_dir);
    if (mkdir(dir, DIR_MODE) == 0) {
        chmod(dir, DIR_MODE);
    } else if (errno != EEXIST) {
        return;
    }

    snprintf(path, sizeof path, "%s/crash_%ld.json", dir, (long)now);
    if (access(path, F_OK) == 0) {
        /* Two children can crash in the same second; never overwrite. */
        snprintf(path, sizeof path, "%s/crash_%ld_%s.json", dir, (long)now,
                 child->name);
    }

    char message[512];
    snprintf(message, sizeof message,
             "screenguard-%s exited with code %d (crash %d/%d within %ds window)",
             child->name, exit_code, child->crash_count, g_max_crashes,
             g_window_sec);

    int fd = open(path, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0600);
    if (fd < 0) return;
    FILE *f = fdopen(fd, "w");
    if (!f) {
        close(fd);
        return;
    }

    fprintf(f,
        "{\n"
        "  \"source\": \"digiwelld\",\n"
        "  \"process\": \"%s\",\n"
        "  \"timestamp\": \"%s\",\n"
        "  \"exit_code\": %d,\n"
        "  \"crash_number\": %d,\n"
        "  \"max_crashes\": %d,\n"
        "  \"window_seconds\": %d,\n"
        "  \"error\": \"%s\",\n"
        "  \"message\": \"%s\"\n"
        "}\n",
        child->name, ts, exit_code, child->crash_count, g_max_crashes,
        g_window_sec, message, message);
    fclose(f);
}

static const char *child_label(const child_proc *child) {
    if (!strcmp(child->name, "daemon")) return "Daemon";
    if (!strcmp(child->name, "session-worker")) return "Session Worker";
    if (!strcmp(child->name, "usage-worker")) return "Usage Worker";
    if (!strcmp(child->name, "policy-worker")) return "Policy Worker";
    if (!strcmp(child->name, "store-worker")) return "Store Worker";
    return child->name;
}

/* Best-effort desktop notification. The child is not waited for: notify-send
 * is short-lived and a wedged session bus must not stall supervision. */
static void send_giveup_notification(const child_proc *child) {
    char summary[128];
    char body[512];

    snprintf(summary, sizeof summary, "ScreenGuard %s Crashed",
             child_label(child));
    snprintf(body, sizeof body,
             "The ScreenGuard %s crashed %d times in %d seconds and has been "
             "stopped. Open ScreenGuard Settings \u2192 Tracker Daemon to "
             "restart it.",
             child->name, child->crash_count, g_window_sec);

    pid_t p = fork();
    if (p == 0) {
        execlp("notify-send", "notify-send",
               summary, body,
               "-i", "dialog-error",
               "-u", "critical",
               "-a", "ScreenGuard",
               "-h", "string:x-canonical-private-synchronous:digiwelld",
               (char *)NULL);
        _exit(127);
    }
}

/* --------------------------------------------------------------- routing */

enum domain { DOMAIN_SYSTEM, DOMAIN_USAGE, DOMAIN_POLICY, DOMAIN_TRACKING,
              DOMAIN_STORAGE, DOMAIN_UNKNOWN };

static enum domain domain_of(const char *s, size_t len) {
    if (len == 6 && !memcmp(s, "system", 6))   return DOMAIN_SYSTEM;
    if (len == 5 && !memcmp(s, "usage", 5))    return DOMAIN_USAGE;
    if (len == 6 && !memcmp(s, "policy", 6))   return DOMAIN_POLICY;
    if (len == 8 && !memcmp(s, "tracking", 8)) return DOMAIN_TRACKING;
    if (len == 7 && !memcmp(s, "storage", 7))  return DOMAIN_STORAGE;
    return DOMAIN_UNKNOWN;
}

static int valid_method(const char *s, size_t len) {
    if (len == 0 || len > 128) return 0;
    if (!((s[0] >= 'A' && s[0] <= 'Z') || (s[0] >= 'a' && s[0] <= 'z') ||
          s[0] == '_')) return 0;
    for (size_t i = 1; i < len; i++) {
        char c = s[i];
        if (!((c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') ||
              (c >= '0' && c <= '9') || c == '_')) return 0;
    }
    return 1;
}

static int connect_socket(const char *path) {
    struct sockaddr_un addr;
    if (!path || !*path) return -1;
    if (strlen(path) >= sizeof addr.sun_path) return -1;
    memset(&addr, 0, sizeof addr);
    addr.sun_family = AF_UNIX;
    strncpy(addr.sun_path, path, sizeof addr.sun_path - 1);

    int fd = socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0);
    if (fd < 0) return -1;
    if (connect(fd, (struct sockaddr *)&addr, sizeof addr) < 0) {
        int e = errno;
        close(fd);
        errno = e;
        return -1;
    }
    struct timeval tv = { IO_TIMEOUT_SEC, 0 };
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof tv);
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof tv);
    return fd;
}

static int connect_backend(void) {
    return connect_socket(g_backend_path);
}

static const char *child_state(const child_proc *child) {
    if (!child->enabled) return "disabled";
    if (child->gave_up) return "gave-up";
    if (child->stopped) return "stopped";
    if (child->pid > 0) return "running";
    if (now_ms() < child->next_spawn_ms) return "backoff";
    return "starting";
}

static void serve_system(int client, const char *method, const char *payload) {
    (void)payload;
    if (!strcmp(method, "ping")) {
        reply(client, "ok pong");
    } else if (!strcmp(method, "status")) {
        reply(client,
              "ok pid=%ld child=%ld session=%ld usage=%ld policy=%ld store=%ld "
              "uptime=%ld backend=%s locked=%d daemon=%s worker=%s "
              "usage_state=%s policy_state=%s store_state=%s crashes=%d "
              "session_crashes=%d usage_crashes=%d policy_crashes=%d "
              "store_crashes=%d",
              (long)getpid(), (long)g_daemon.pid, (long)g_session.pid,
              (long)g_usage.pid, (long)g_policy.pid, (long)g_store.pid,
              (long)(time(NULL) - g_started_at),
              g_backend_path[0] ? g_backend_path : "-",
              g_storage_fd >= 0,
              child_state(&g_daemon), child_state(&g_session),
              child_state(&g_usage), child_state(&g_policy),
              child_state(&g_store),
              g_daemon.crash_count, g_session.crash_count,
              g_usage.crash_count, g_policy.crash_count,
              g_store.crash_count);
    } else if (!strcmp(method, "restart")) {
        if (g_no_spawn) {
            reply(client, "err spawn-disabled");
        } else {
            g_restart_requested = 1;
            reply(client, "ok restarting");
        }
    } else {
        reply(client, "err unknown-method");
    }
}

static void serve_routed(int client, enum domain dom,
                         const char *line, size_t len) {
    int locked = 0;

    /* The special lock: storage mutations are serialised across processes,
     * not just across threads. Non-blocking on purpose; the caller gets an
     * honest answer instead of a hang. */
    if (dom == DOMAIN_STORAGE) {
        int fd = lock_exclusive(g_storage_lock_path);
        if (fd == -2) {
            reply(client, "err storage-busy");
            return;
        }
        if (fd < 0) {
            reply(client, "err storage-lock-failed");
            return;
        }
        g_storage_fd = fd;
        locked = 1;
    }

    int back = -1;
    if (dom == DOMAIN_USAGE && g_usage.enabled) {
        /* Once a usage worker exists it is the only answer for the usage
         * domain. Falling back to the daemon here would turn a dead worker
         * into a silent split-brain, so say it is unavailable instead. */
        back = connect_socket(g_usage_socket);
        if (back < 0) {
            reply(client, "err usage-unavailable");
            goto out;
        }
    } else if (dom == DOMAIN_POLICY && g_policy.enabled) {
        /* Same rule for policy: the worker is the only process allowed to
         * advance the focus state machine, so a daemon fallback would
         * double-insert focus sessions. */
        back = connect_socket(g_policy_socket);
        if (back < 0) {
            reply(client, "err policy-unavailable");
            goto out;
        }
    } else if (dom == DOMAIN_STORAGE && g_store.enabled) {
        /* The store is the single SQLite writer. Once it exists, a dead
         * worker must fail closed: letting the daemon write here would
         * reintroduce the two-writer race the worker was created to remove. */
        back = connect_socket(g_store_socket);
        if (back < 0) {
            reply(client, "err storage-unavailable");
            goto out;
        }
    } else {
        back = connect_backend();
        if (back < 0) {
            reply(client, "err daemon-unavailable");
            goto out;
        }
    }

    if (write_all(back, line, len) < 0 || write_all(back, "\n", 1) < 0) {
        reply(client, "err backend-write-failed");
        close(back);
        goto out;
    }

    char resp[MAX_RESPONSE];
    ssize_t n = read_line(back, resp, sizeof resp);
    close(back);
    if (n <= 0) {
        reply(client, "err backend-timeout");
        goto out;
    }
    (void)write_all(client, resp, (size_t)n);
    if (resp[n - 1] != '\n') (void)write_all(client, "\n", 1);

out:
    if (locked) {
        flock(g_storage_fd, LOCK_UN);
        close(g_storage_fd);
        g_storage_fd = -1;
    }
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

    enum domain dom = domain_of(domain, strlen(domain));
    if (dom == DOMAIN_UNKNOWN) {
        reply(client, "err unknown-domain");
        return;
    }
    if (!valid_method(method, strlen(method))) {
        reply(client, "err invalid-method");
        return;
    }

    if (dom == DOMAIN_SYSTEM) {
        serve_system(client, method, payload);
        return;
    }

    /* Rebuild the canonical request without the payload's leading spaces. */
    size_t need = strlen(domain) + 1 + strlen(method) + 1 + strlen(payload) + 1;
    char *req = malloc(need);
    if (!req) {
        reply(client, "err out-of-memory");
        return;
    }
    int written = snprintf(req, need, "%s %s %s", domain, method, payload);
    if (written < 0) written = 0;
    serve_routed(client, dom, req, (size_t)written);
    free(req);
}

/* ----------------------------------------------------------- supervision */

static void child_spawn(child_proc *child) {
    if (!child->enabled || child->argc == 0) return;
    pid_t pid = fork();
    if (pid < 0) {
        logmsg("fork %s: %s", child->name, strerror(errno));
        child->next_spawn_ms = now_ms() + g_initial_delay_ms;
        return;
    }
    if (pid == 0) {
        /* Keep the child in our process group: if the supervisor is killed
         * with its group, the children go with it. systemd uses KillMode
         * anyway. */
        sigset_t empty;
        sigemptyset(&empty);
        sigprocmask(SIG_SETMASK, &empty, NULL);
        signal(SIGTERM, SIG_DFL);
        signal(SIGINT, SIG_DFL);
        signal(SIGHUP, SIG_DFL);
        signal(SIGPIPE, SIG_DFL);

        /* The daemon discovers the session, policy and store workers through
         * these variables. If a worker is disabled, remove any inherited value
         * so the daemon does not wait on a socket nobody serves, does not
         * advance policy state behind the worker's back, and does not keep a
         * second SQLite writer for sessions and events. */
        if (child == &g_daemon) {
            if (g_session.enabled && g_session_socket[0])
                setenv("SCREENGUARD_SESSION_SOCKET", g_session_socket, 1);
            else
                unsetenv("SCREENGUARD_SESSION_SOCKET");
            if (g_policy.enabled && g_policy_socket[0])
                setenv("SCREENGUARD_POLICY_SOCKET", g_policy_socket, 1);
            else
                unsetenv("SCREENGUARD_POLICY_SOCKET");
            if (g_store.enabled && g_store_socket[0])
                setenv("SCREENGUARD_STORE_SOCKET", g_store_socket, 1);
            else
                unsetenv("SCREENGUARD_STORE_SOCKET");
        }

        execvp(child->path, child->argv);
        _exit(127);
    }
    child->pid = pid;
    child->started = time(NULL);
    logmsg("spawned %s pid=%ld", child->name, (long)pid);
}

/* Reset the budget after a full quiet window, exactly like the old watchdog:
 * a crash after WINDOW_SEC of stability counts as crash 1 again. */
static void child_maybe_reset_window(child_proc *child, time_t now) {
    if (child->window_start == 0) {
        child->window_start = now;
        return;
    }
    if (now - child->window_start > g_window_sec) {
        if (child->crash_count > 0)
            logmsg("%s stayed up for %ds; crash budget reset",
                   child->name, g_window_sec);
        child->crash_count = 0;
        child->backoff_ms = g_initial_delay_ms;
        child->window_start = now;
    }
}

static void child_reap(child_proc *child) {
    if (child->pid <= 0) return;
    int status = 0;
    pid_t r = waitpid(child->pid, &status, WNOHANG);
    if (r != child->pid) return;

    time_t now = time(NULL);
    time_t ran = now - child->started;
    child->pid = -1;

    /* A clean exit is the child's own decision: rotate journals, install an
     * update, or yield to another instance that owns the singleton lock.
     * Restarting it would ignore that decision and, for the singleton case,
     * spin forever. */
    if (WIFEXITED(status) && WEXITSTATUS(status) == 0) {
        logmsg("%s exited cleanly (code 0) after %lds; not restarting",
               child->name, (long)ran);
        child->stopped = 1;
        return;
    }

    int exit_code;
    if (WIFEXITED(status)) {
        exit_code = WEXITSTATUS(status);
        logmsg("%s pid=%ld exited code=%d after %lds",
               child->name, (long)r, exit_code, (long)ran);
    } else if (WIFSIGNALED(status)) {
        exit_code = 128 + WTERMSIG(status);
        logmsg("%s pid=%ld killed by signal %d after %lds",
               child->name, (long)r, WTERMSIG(status), (long)ran);
    } else {
        exit_code = 1;
        logmsg("%s pid=%ld ended abnormally after %lds",
               child->name, (long)r, (long)ran);
    }

    child_maybe_reset_window(child, now);
    child->crash_count++;
    write_crash_log(child, exit_code);

    if (child->crash_count >= g_max_crashes) {
        logmsg("too many crashes for %s (%d in %ds) — giving up",
               child->name, child->crash_count, g_window_sec);
        child->gave_up = 1;
        send_giveup_notification(child);
        return;
    }

    logmsg("restarting %s in %ldms (%d/%d crashes)",
           child->name, child->backoff_ms, child->crash_count, g_max_crashes);
    child->next_spawn_ms = now_ms() + child->backoff_ms;
    child->backoff_ms *= 2;
    if (child->backoff_ms > g_max_delay_ms) child->backoff_ms = g_max_delay_ms;
}

static void child_maybe_spawn(child_proc *child) {
    if (g_no_spawn || !child->enabled || child->pid > 0) return;
    if (child->stopped || child->gave_up) return;
    child_maybe_reset_window(child, time(NULL));
    if (now_ms() < child->next_spawn_ms) return;
    child_spawn(child);
}

static void child_stop(child_proc *child) {
    if (child->pid <= 0) return;
    logmsg("stopping %s pid=%ld", child->name, (long)child->pid);
    kill(child->pid, SIGTERM);
    for (int i = 0; i < SHUTDOWN_GRACE * 10; i++) {
        int status = 0;
        pid_t r = waitpid(child->pid, &status, WNOHANG);
        if (r == child->pid) { child->pid = -1; return; }
        struct timespec ts = { 0, 100 * 1000 * 1000 };
        nanosleep(&ts, NULL);
    }
    logmsg("%s did not stop; SIGKILL", child->name);
    kill(child->pid, SIGKILL);
    waitpid(child->pid, NULL, 0);
    child->pid = -1;
}

static void child_reset_budget(child_proc *child, long spawn_at) {
    child->crash_count = 0;
    child->window_start = time(NULL);
    child->backoff_ms = g_initial_delay_ms;
    child->next_spawn_ms = spawn_at;
    child->stopped = 0;
    child->gave_up = 0;
}

/* ------------------------------------------------------------------- main */

static void usage(const char *prog) {
    fprintf(stderr,
        "usage: %s [options] [-- daemon-args...]\n"
        "\n"
        "  --runtime DIR    runtime directory (default $XDG_RUNTIME_DIR/screenguard)\n"
        "  --daemon PATH    daemon executable to supervise (default screenguard-daemon)\n"
        "  --session-worker PATH\n"
        "                   digiwelld-session executable to supervise; it owns\n"
        "                   RUNTIME/session.sock and the canonical session journal\n"
        "  --usage-worker PATH\n"
        "                   digiwelld-usage executable to supervise; it owns\n"
        "                   RUNTIME/usage.sock and answers the usage domain\n"
        "  --policy-worker PATH\n"
        "                   digiwelld-policy executable to supervise; it owns\n"
        "                   RUNTIME/policy.sock, the policy domain and the only\n"
        "                   focus/Pomodoro state machine\n"
        "  --store-worker PATH\n"
        "                   digiwelld-store executable to supervise; it owns\n"
        "                   RUNTIME/store.sock and is the single SQLite writer\n"
        "                   for sessions and events\n"
        "  --backend PATH   daemon socket (default RUNTIME/daemon.sock)\n"
        "  --no-spawn       do not supervise children; route to an existing backend\n"
        "  -h, --help       this text\n"
        "\n"
        "Supervision tuning (defaults match the former screenguard-watchdog):\n"
        "  DIGIWELLD_MAX_CRASHES          crashes before giving up (5)\n"
        "  DIGIWELLD_CRASH_WINDOW         seconds before the budget resets (300)\n"
        "  DIGIWELLD_RESTART_DELAY_MS     first restart delay in ms (2000)\n"
        "  DIGIWELLD_MAX_RESTART_DELAY_MS backoff cap in ms (30000)\n",
        prog);
}

int main(int argc, char **argv) {
    const char *runtime = NULL;
    const char *session_worker = NULL;
    const char *usage_worker = NULL;
    const char *policy_worker = NULL;
    const char *store_worker = NULL;
    g_daemon.path = "screenguard-daemon";

    int i = 1;
    for (; i < argc; i++) {
        if (!strcmp(argv[i], "--")) { i++; break; }
        if (!strcmp(argv[i], "--runtime") && i + 1 < argc) {
            runtime = argv[++i];
        } else if (!strcmp(argv[i], "--daemon") && i + 1 < argc) {
            g_daemon.path = argv[++i];
        } else if (!strcmp(argv[i], "--session-worker") && i + 1 < argc) {
            session_worker = argv[++i];
        } else if (!strcmp(argv[i], "--usage-worker") && i + 1 < argc) {
            usage_worker = argv[++i];
        } else if (!strcmp(argv[i], "--policy-worker") && i + 1 < argc) {
            policy_worker = argv[++i];
        } else if (!strcmp(argv[i], "--store-worker") && i + 1 < argc) {
            store_worker = argv[++i];
        } else if (!strcmp(argv[i], "--backend") && i + 1 < argc) {
            snprintf(g_backend_path, sizeof g_backend_path, "%s", argv[++i]);
        } else if (!strcmp(argv[i], "--no-spawn")) {
            g_no_spawn = 1;
        } else if (!strcmp(argv[i], "-h") || !strcmp(argv[i], "--help")) {
            usage(argv[0]);
            return 0;
        } else {
            fprintf(stderr, "%s: unknown argument %s\n", argv[0], argv[i]);
            usage(argv[0]);
            return 2;
        }
    }

    g_max_crashes = env_int("DIGIWELLD_MAX_CRASHES",
                            DEFAULT_MAX_CRASHES, 1, MAX_CRASH_LIMIT);
    g_window_sec = env_int("DIGIWELLD_CRASH_WINDOW",
                           DEFAULT_WINDOW_SEC, 1, MAX_WINDOW_SEC);
    g_initial_delay_ms = env_int("DIGIWELLD_RESTART_DELAY_MS",
                                 DEFAULT_RESTART_DELAY_MS, 0, 3600000);
    g_max_delay_ms = env_int("DIGIWELLD_MAX_RESTART_DELAY_MS",
                             DEFAULT_MAX_DELAY_MS, g_initial_delay_ms,
                             3600000);
    g_daemon.backoff_ms = g_initial_delay_ms;
    g_session.backoff_ms = g_initial_delay_ms;
    g_usage.backoff_ms = g_initial_delay_ms;
    g_policy.backoff_ms = g_initial_delay_ms;
    g_store.backoff_ms = g_initial_delay_ms;

    /* Daemon argv: <daemon> [extra args] */
    g_daemon.argv[0] = (char *)g_daemon.path;
    g_daemon.argc = 1;
    for (; i < argc && g_daemon.argc < 63; i++) {
        g_daemon.argv[g_daemon.argc++] = argv[i];
    }
    g_daemon.argv[g_daemon.argc] = NULL;
    g_daemon.enabled = 1;

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

    if (snprintf(g_sock_path, sizeof g_sock_path, "%s/control.sock", runtime)
            >= (int)sizeof g_sock_path ||
        snprintf(g_lock_path, sizeof g_lock_path, "%s/digiwelld.lock", runtime)
            >= (int)sizeof g_lock_path ||
        snprintf(g_storage_lock_path, sizeof g_storage_lock_path, "%s/storage.lock",
                 runtime) >= (int)sizeof g_storage_lock_path ||
        snprintf(g_session_socket, sizeof g_session_socket, "%s/session.sock",
                 runtime) >= (int)sizeof g_session_socket ||
        snprintf(g_usage_socket, sizeof g_usage_socket, "%s/usage.sock",
                 runtime) >= (int)sizeof g_usage_socket ||
        snprintf(g_policy_socket, sizeof g_policy_socket, "%s/policy.sock",
                 runtime) >= (int)sizeof g_policy_socket ||
        snprintf(g_store_socket, sizeof g_store_socket, "%s/store.sock",
                 runtime) >= (int)sizeof g_store_socket ||
        (g_backend_path[0] == '\0' &&
         snprintf(g_backend_path, sizeof g_backend_path, "%s/daemon.sock", runtime)
             >= (int)sizeof g_backend_path)) {
        fprintf(stderr, "runtime path too long: %s\n", runtime);
        return 2;
    }

    resolve_data_dir();

    /* The session worker shares the canonical runtime directory with the
     * daemon: its socket is RUNTIME/session.sock, and its journal is the same
     * RUNTIME/session-{state.json,journal.jsonl} contract the Dart fallback
     * uses. Only one of them writes at a time. */
    if (!g_no_spawn && session_worker && access(session_worker, X_OK) == 0) {
        g_session.path = session_worker;
        g_session.argv[0] = (char *)session_worker;
        g_session.argv[1] = (char *)"--runtime";
        g_session.argv[2] = g_runtime;
        g_session.argv[3] = (char *)"--state-dir";
        g_session.argv[4] = g_runtime;
        g_session.argv[5] = NULL;
        g_session.argc = 5;
        g_session.enabled = 1;
    } else if (session_worker) {
        logmsg("session worker %s is not executable; the Dart journal stays "
               "authoritative", session_worker);
    }

    /* The usage worker is a read-only read model: it opens the same SQLite
     * file the daemon writes, never writes itself, and binds RUNTIME/usage.sock.
     * It inherits XDG_DATA_HOME/HOME, so it resolves the same database path. */
    if (!g_no_spawn && usage_worker && access(usage_worker, X_OK) == 0) {
        g_usage.path = usage_worker;
        g_usage.argv[0] = (char *)usage_worker;
        g_usage.argv[1] = (char *)"--runtime";
        g_usage.argv[2] = g_runtime;
        g_usage.argv[3] = NULL;
        g_usage.argc = 3;
        g_usage.enabled = 1;
    } else if (usage_worker) {
        logmsg("usage worker %s is not executable; usage stays on the daemon",
               usage_worker);
    }

    /* The policy worker owns policy writes and is the only process allowed to
     * advance the focus state machine. It inherits XDG_DATA_HOME/HOME, so it
     * resolves the same database path as the daemon. */
    if (!g_no_spawn && policy_worker && access(policy_worker, X_OK) == 0) {
        g_policy.path = policy_worker;
        g_policy.argv[0] = (char *)policy_worker;
        g_policy.argv[1] = (char *)"--runtime";
        g_policy.argv[2] = g_runtime;
        g_policy.argv[3] = NULL;
        g_policy.argc = 3;
        g_policy.enabled = 1;
    } else if (policy_worker) {
        logmsg("policy worker %s is not executable; policy stays on the daemon",
               policy_worker);
    }

    /* The store worker is the single SQLite writer for sessions and events.
     * It creates the database and its schema, so it must start before the
     * daemon's first write; the supervisor gives it the same small head start
     * as every other child. */
    if (!g_no_spawn && store_worker && access(store_worker, X_OK) == 0) {
        g_store.path = store_worker;
        g_store.argv[0] = (char *)store_worker;
        g_store.argv[1] = (char *)"--runtime";
        g_store.argv[2] = g_runtime;
        g_store.argv[3] = NULL;
        g_store.argc = 3;
        g_store.enabled = 1;
    } else if (store_worker) {
        logmsg("store worker %s is not executable; sessions stay on the daemon",
               store_worker);
    }

    if (mkdir_private(runtime) < 0) {
        fprintf(stderr, "cannot create %s: %s\n", runtime, strerror(errno));
        return 1;
    }

    /* 1. singleton lock, before anything is exposed */
    g_lock_fd = lock_exclusive(g_lock_path);
    if (g_lock_fd == -2) {
        fprintf(stderr, "another digiwelld already owns %s\n", runtime);
        return 1;
    }
    if (g_lock_fd < 0) {
        fprintf(stderr, "cannot lock %s: %s\n", g_lock_path, strerror(errno));
        return 1;
    }

    openlog("digiwelld", LOG_PID | LOG_CONS, LOG_USER);

    signal(SIGPIPE, SIG_IGN);
    struct sigaction sa;
    memset(&sa, 0, sizeof sa);
    sa.sa_handler = on_signal;
    sigaction(SIGTERM, &sa, NULL);
    sigaction(SIGINT, &sa, NULL);
    sigaction(SIGHUP, &sa, NULL);

    g_started_at = time(NULL);
    g_daemon.window_start = g_started_at;
    g_session.window_start = g_started_at;
    g_usage.window_start = g_started_at;
    g_policy.window_start = g_started_at;
    g_store.window_start = g_started_at;

    /* 2. the door */
    g_listen_fd = listen_unix(g_sock_path);
    if (g_listen_fd < 0) {
        fprintf(stderr, "cannot listen on %s\n", g_sock_path);
        return 1;
    }
    logmsg("listening on %s (mode %04o)", g_sock_path, SOCK_MODE);
    logmsg("backend %s, supervising %s", g_backend_path,
           g_no_spawn ? "(disabled)" : g_daemon.path);
    if (!g_no_spawn && g_session.enabled) {
        logmsg("session worker %s -> %s", g_session.path, g_session_socket);
    }
    if (!g_no_spawn && g_usage.enabled) {
        logmsg("usage worker %s -> %s", g_usage.path, g_usage_socket);
    }
    if (!g_no_spawn && g_policy.enabled) {
        logmsg("policy worker %s -> %s", g_policy.path, g_policy_socket);
    }
    if (!g_no_spawn && g_store.enabled) {
        logmsg("store worker %s -> %s", g_store.path, g_store_socket);
    }
    if (!g_no_spawn) {
        logmsg("crash budget: %d crashes / %ds, restart %dms..%dms",
               g_max_crashes, g_window_sec, g_initial_delay_ms,
               g_max_delay_ms);
    }

    if (!g_no_spawn) {
        /* The store opens the database and creates the schema. Give it the
         * first slot so the daemon's very first write finds a listener. */
        g_store.next_spawn_ms = now_ms() + 50;
        g_daemon.next_spawn_ms = now_ms() + 250;   /* small settle delay */
        g_session.next_spawn_ms = now_ms() + 250;
        g_usage.next_spawn_ms = now_ms() + 250;
        g_policy.next_spawn_ms = now_ms() + 250;
    }

    /* 3. serve */
    while (!g_stop) {
        child_maybe_spawn(&g_store);
        child_maybe_spawn(&g_daemon);
        child_maybe_spawn(&g_session);
        child_maybe_spawn(&g_usage);
        child_maybe_spawn(&g_policy);

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
        child_reap(&g_daemon);
        child_reap(&g_session);
        child_reap(&g_usage);
        child_reap(&g_policy);
        child_reap(&g_store);

        if (g_restart_requested) {
            g_restart_requested = 0;
            logmsg("restart requested through system.restart");
            /* Stop the daemon first: its clean shutdown closes the open
             * session through the store worker. Then stop the workers; the
             * store goes last so that close is never lost. */
            child_stop(&g_daemon);
            child_stop(&g_session);
            child_stop(&g_usage);
            child_stop(&g_policy);
            child_stop(&g_store);
            long at = now_ms() + 250;
            child_reset_budget(&g_daemon, at);
            child_reset_budget(&g_session, at);
            child_reset_budget(&g_usage, at);
            child_reset_budget(&g_policy, at);
            child_reset_budget(&g_store, at);
        }
    }

    logmsg("shutting down");
    child_stop(&g_daemon);
    child_stop(&g_session);
    child_stop(&g_usage);
    child_stop(&g_policy);
    child_stop(&g_store);
    if (g_listen_fd >= 0) close(g_listen_fd);
    unlink(g_sock_path);
    if (g_storage_fd >= 0) { flock(g_storage_fd, LOCK_UN); close(g_storage_fd); }
    if (g_lock_fd >= 0) { flock(g_lock_fd, LOCK_UN); close(g_lock_fd); }
    closelog();
    return 0;
}
