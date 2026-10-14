/*
 * screenguard-watchdog — lightweight process supervisor for screenguard-daemon.
 *
 * Responsibilities:
 *   1. Launch screenguard-daemon as a child process.
 *   2. Monitor it via waitpid().
 *   3. Restart on crash (non-zero exit) with exponential backoff.
 *   4. Give up after MAX_CRASHES crashes within WINDOW_SEC seconds.
 *   5. Forward SIGTERM/SIGINT/SIGHUP to the child; exit cleanly.
 *   6. Write its own PID to a file for single-instance gating.
 *
 * Build:
 *   cc -O2 -Wall -Wextra -o screenguard-watchdog src/watchdog.c
 *
 * Binary size: ~20 KB.  RAM: <200 KB RSS.  Dependencies: libc only.
 */

#define _POSIX_C_SOURCE 200809L
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <syslog.h>
#include <time.h>
#include <unistd.h>

/* ── Tunable constants ──────────────────────────────────────────────────── */

#define MAX_CRASHES     5       /* max crashes before giving up            */
#define WINDOW_SEC      300     /* reset crash counter after this many sec */
#define INITIAL_DELAY   2       /* first restart delay (seconds)           */
#define MAX_DELAY       30      /* backoff cap (seconds)                   */
#define NOTIFY_CMD      "notify-send"

/* ── Globals (signal-safe) ──────────────────────────────────────────────── */

static volatile sig_atomic_t g_child_pid = 0;
static volatile sig_atomic_t g_got_signal = 0;   /* forwarded signal num  */
static volatile sig_atomic_t g_got_child  = 0;

/* ── Signal handlers ────────────────────────────────────────────────────── */

static void on_forward_signal(int sig) {
    g_got_signal = sig;
    if (g_child_pid > 0) {
        kill(g_child_pid, sig);
    }
}

static void on_sigchld(int sig) {
    (void)sig;
    g_got_child = 1;
}

/* ── Helpers ────────────────────────────────────────────────────────────── */

/* Resolve the daemon binary path.  Order:
 *   1. Sibling of this executable  (e.g. ~/.local/opt/screenguard/screenguard-daemon)
 *   2. ~/.local/bin/screenguard-daemon
 *   3. /usr/bin/screenguard-daemon
 *   4. "screenguard-daemon" (rely on PATH)
 */
static const char *resolve_daemon(void) {
    static char buf[PATH_MAX];

    /* 1. Sibling of our own executable */
    ssize_t n = readlink("/proc/self/exe", buf, sizeof(buf) - 1);
    if (n > 0) {
        buf[n] = '\0';
        char *slash = strrchr(buf, '/');
        if (slash) {
            /* Replace our binary name with the daemon name */
            size_t dir_len = (size_t)(slash - buf) + 1;
            if (dir_len + strlen("screenguard-daemon") < sizeof(buf)) {
                strcpy(slash + 1, "screenguard-daemon");
                if (access(buf, X_OK) == 0)
                    return buf;
            }
        }
    }

    /* 2. ~/.local/bin */
    const char *home = getenv("HOME");
    if (home) {
        snprintf(buf, sizeof(buf), "%s/.local/bin/screenguard-daemon", home);
        if (access(buf, X_OK) == 0)
            return buf;
    }

    /* 3. System path */
    if (access("/usr/bin/screenguard-daemon", X_OK) == 0)
        return "/usr/bin/screenguard-daemon";

    /* 4. Fallback to PATH lookup */
    return "screenguard-daemon";
}

/* Write the watchdog PID file.  Returns 0 on success, -1 if another
 * watchdog is already running. */
static int write_pidfile(const char *path) {
    int fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (fd < 0) return -1;

    /* Try to get an exclusive lock; if we can't, another watchdog is running */
    struct flock fl = {
        .l_type   = F_WRLCK,
        .l_whence = SEEK_SET,
        .l_start  = 0,
        .l_len    = 0,
    };
    if (fcntl(fd, F_SETLK, &fl) == -1) {
        close(fd);
        return -1;
    }

    /* Hold fd open (keeps the lock alive for our process lifetime) */
    char pidbuf[32];
    int len = snprintf(pidbuf, sizeof(pidbuf), "%d\n", (int)getpid());
    if (write(fd, pidbuf, (size_t)len) < 0) {
        /* non-fatal; the lock is what matters */
    }
    /* Intentionally do NOT close fd — the lock must stay held */
    return 0;
}

/* Resolve the data directory (XDG_DATA_HOME or ~/.local/share/screenguard) */
static const char *resolve_data_dir(void) {
    static char dir[PATH_MAX];
    const char *xdg = getenv("XDG_DATA_HOME");
    const char *home = getenv("HOME");

    if (xdg && xdg[0])
        snprintf(dir, sizeof(dir), "%s/screenguard", xdg);
    else if (home && home[0])
        snprintf(dir, sizeof(dir), "%s/.local/share/screenguard", home);
    else
        snprintf(dir, sizeof(dir), "/tmp/.screenguard");

    /* Ensure directory exists */
    mkdir(dir, 0755);
    return dir;
}

/* Send a desktop notification (best-effort, non-blocking) */
static void send_notification(const char *summary, const char *body) {
    pid_t p = fork();
    if (p == 0) {
        /* child — exec notify-send and exit */
        execlp(NOTIFY_CMD, NOTIFY_CMD,
               summary, body,
               "-i", "dialog-error",
               "-u", "critical",
               "-a", "ScreenGuard",
               "-h", "string:x-canonical-private-synchronous:screenguard-watchdog",
               (char *)NULL);
        _exit(127);
    }
    /* parent — don't wait; the zombie will be reaped by our SIGCHLD handler
     * or the next waitpid(-1, ...) call */
}

/* Write a crash event to the crash log directory as a JSON file */
static void write_crash_log(const char *data_dir, int exit_code, int crash_num) {
    char path[PATH_MAX];
    time_t now = time(NULL);
    struct tm tm;
    localtime_r(&now, &tm);

    char ts[64];
    strftime(ts, sizeof(ts), "%Y-%m-%dT%H:%M:%S%z", &tm);

    snprintf(path, sizeof(path), "%s/crashes", data_dir);
    mkdir(path, 0755);

    snprintf(path, sizeof(path), "%s/crashes/crash_%ld.json", data_dir, (long)now);

    FILE *f = fopen(path, "w");
    if (!f) return;

    fprintf(f,
        "{\n"
        "  \"source\": \"watchdog\",\n"
        "  \"timestamp\": \"%s\",\n"
        "  \"exit_code\": %d,\n"
        "  \"crash_number\": %d,\n"
        "  \"max_crashes\": %d,\n"
        "  \"window_seconds\": %d,\n"
        "  \"message\": \"screenguard-daemon exited with code %d (crash %d/%d within %ds window)\"\n"
        "}\n",
        ts, exit_code, crash_num, MAX_CRASHES, WINDOW_SEC,
        exit_code, crash_num, MAX_CRASHES, WINDOW_SEC);
    fclose(f);
}

/* ── Main ───────────────────────────────────────────────────────────────── */

int main(void) {
    const char *daemon_path = resolve_daemon();
    const char *data_dir    = resolve_data_dir();

    /* PID file for single-instance */
    char pidfile[PATH_MAX];
    snprintf(pidfile, sizeof(pidfile), "%s/watchdog.pid", data_dir);
    if (write_pidfile(pidfile) < 0) {
        fprintf(stderr, "[screenguard-watchdog] another watchdog is already running\n");
        return 0;
    }

    openlog("screenguard-watchdog", LOG_PID | LOG_CONS, LOG_USER);

    /* Install signal handlers */
    struct sigaction sa;
    memset(&sa, 0, sizeof(sa));

    sa.sa_handler = on_forward_signal;
    sa.sa_flags = 0;
    sigemptyset(&sa.sa_mask);
    sigaction(SIGTERM, &sa, NULL);
    sigaction(SIGINT,  &sa, NULL);
    sigaction(SIGHUP,  &sa, NULL);

    sa.sa_handler = on_sigchld;
    sa.sa_flags = SA_NOCLDSTOP;
    sigaction(SIGCHLD, &sa, NULL);

    syslog(LOG_INFO, "starting — will supervise %s", daemon_path);
    fprintf(stderr, "[screenguard-watchdog] supervising %s\n", daemon_path);

    int crashes = 0;
    time_t window_start = time(NULL);
    int delay = INITIAL_DELAY;

    for (;;) {
        /* Reset crash counter if we've been stable long enough */
        time_t now = time(NULL);
        if (now - window_start > WINDOW_SEC) {
            crashes = 0;
            delay = INITIAL_DELAY;
            window_start = now;
        }

        /* Fork and exec the daemon */
        pid_t child = fork();
        if (child < 0) {
            syslog(LOG_ERR, "fork() failed: %s", strerror(errno));
            sleep(5);
            continue;
        }

        if (child == 0) {
            /* Child process — become the daemon */
            execl(daemon_path, "screenguard-daemon", (char *)NULL);
            /* If exec failed */
            fprintf(stderr, "[screenguard-watchdog] exec(%s) failed: %s\n",
                    daemon_path, strerror(errno));
            _exit(127);
        }

        /* Parent — track the child */
        g_child_pid = child;
        g_got_child = 0;
        syslog(LOG_INFO, "launched daemon pid=%d", (int)child);

        /* Wait for child to exit */
        int status = 0;
        pid_t w;
        for (;;) {
            w = waitpid(child, &status, 0);
            if (w == child) break;
            if (w == -1 && errno == EINTR) {
                /* We received a signal.  If it was SIGTERM/SIGINT, we already
                 * forwarded it to the child; just keep waiting for the child
                 * to exit.  If the child won't die, force kill after a grace. */
                if (g_got_signal) {
                    /* Give child 3 seconds to exit gracefully */
                    sleep(3);
                    /* Check if child exited */
                    w = waitpid(child, &status, WNOHANG);
                    if (w == 0) {
                        /* Still alive — force kill */
                        kill(child, SIGKILL);
                        waitpid(child, &status, 0);
                    }
                    syslog(LOG_INFO, "terminated by signal %d", (int)g_got_signal);
                    closelog();
                    _exit(0);
                }
                continue;
            }
            /* Reap any zombie from our notify-send children */
            if (w > 0) continue;
            break;
        }

        g_child_pid = 0;

        /* Determine exit reason */
        int exit_code;
        if (WIFEXITED(status)) {
            exit_code = WEXITSTATUS(status);
            if (exit_code == 0) {
                /* Clean exit — daemon chose to stop.  Don't restart. */
                syslog(LOG_INFO, "daemon exited cleanly (code 0); stopping watchdog");
                break;
            }
        } else if (WIFSIGNALED(status)) {
            exit_code = 128 + WTERMSIG(status);
            syslog(LOG_WARNING, "daemon killed by signal %d", WTERMSIG(status));
        } else {
            exit_code = 1;
        }

        crashes++;
        syslog(LOG_WARNING, "daemon crashed (exit %d), restart %d/%d",
               exit_code, crashes, MAX_CRASHES);

        /* Log crash to file */
        write_crash_log(data_dir, exit_code, crashes);

        if (crashes >= MAX_CRASHES) {
            syslog(LOG_ERR, "too many crashes (%d in %ds) — giving up",
                   crashes, WINDOW_SEC);
            send_notification(
                "ScreenGuard Daemon Crashed",
                "The tracking daemon crashed too many times and has been stopped. "
                "Open ScreenGuard Settings → Tracker Daemon to restart."
            );
            break;
        }

        syslog(LOG_INFO, "restarting in %d seconds...", delay);
        sleep((unsigned)delay);

        /* Exponential backoff: 2, 4, 8, 16, 30, 30, ... */
        delay *= 2;
        if (delay > MAX_DELAY)
            delay = MAX_DELAY;
    }

    closelog();
    return 0;
}
