/* ScreenGuard process killer — screenguard-killer.
 *
 * Escalating close for apps that shrug off a bare SIGTERM (notably
 * Proton/Steam games: wineserver keeps the tree alive, fullscreen exes
 * ignore signals). Stages:
 *   1. SIGTERM the PID, verify (poll, ~3 s).
 *   2. SIGKILL the PID plus its whole descendant tree, verify (~1 s).
 *   3. Proton-native kill for steam_app_<id>: find the wineserver whose
 *      WINEPREFIX belongs to this app and run `wineserver -k`.
 *   4. Pattern-kill by exe basename — never for generic runtime binaries
 *      (wineserver, wine, steam, ...) where that would hit unrelated apps.
 *   5. Pattern-kill by Steam manifest install dir (last resort).
 *
 * Usage: screenguard-killer --pid <n> [--app <id>] [--dry-run]
 * Exit: 0 = target gone, 1 = still alive / nothing to do, 2 = usage error.
 * Every run appends one line to ~/.local/share/screenguard/kill.log
 * (capped at 200 lines) so failed closes stay debuggable.
 *
 * Build: cc -O2 -Wall -Wextra -std=c99 -o screenguard-killer killer.c
 */
#define _POSIX_C_SOURCE 200809L

#include <ctype.h>
#include <dirent.h>
#include <errno.h>
#include <signal.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

static int g_dry_run = 0;
static pid_t g_pid = -1;
static char g_app[256] = "";
static char g_steps[8192] = "";

static void log_step(const char *fmt, ...) {
    char buf[512];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(buf, sizeof(buf), fmt, ap);
    va_end(ap);
    printf("  [killer] %s\n", buf);
    fflush(stdout);
    size_t len = strlen(g_steps);
    if (len + strlen(buf) + 4 < sizeof(g_steps)) {
        if (len > 0) strcat(g_steps, " | ");
        strcat(g_steps, buf);
    }
}

/* -- /proc helpers ---------------------------------------------------- */

static int read_file(const char *path, char *out, size_t cap) {
    FILE *f = fopen(path, "r");
    if (!f) return -1;
    size_t n = fread(out, 1, cap - 1, f);
    fclose(f);
    out[n] = '\0';
    return (int)n;
}

/* Process state from /proc/<pid>/stat ('R','S','Z',...), '?' on error. */
static char proc_state(pid_t pid) {
    char path[64], buf[1024];
    snprintf(path, sizeof(path), "/proc/%d/stat", (int)pid);
    if (read_file(path, buf, sizeof(buf)) < 0) return '?';
    char *rp = strrchr(buf, ')');
    if (!rp) return '?';
    rp++;
    while (*rp == ' ') rp++;
    return *rp ? *rp : '?';
}

/* Alive = signalable AND not a zombie (kill(pid,0) succeeds on zombies). */
static int alive(pid_t pid) {
    if (pid <= 0) return 0;
    if (kill(pid, 0) != 0) return 0;
    return proc_state(pid) != 'Z';
}

static void sleep_ms(long ms) {
    struct timespec ts = { ms / 1000, (ms % 1000) * 1000000L };
    nanosleep(&ts, NULL);
}

/* 1 when deadline passes, 0 if pid died first. */
static int wait_dead(pid_t pid, long timeout_ms) {
    long waited = 0;
    while (waited < timeout_ms) {
        if (!alive(pid)) return 0;
        sleep_ms(50);
        waited += 50;
    }
    return alive(pid);
}

/* Raw-bytes substring search (cmdline/environ contain NULs). */
static int contains_bytes(const char *hay, size_t hlen, const char *sub) {
    size_t slen = strlen(sub);
    if (slen == 0 || slen > hlen) return 0;
    for (size_t i = 0; i + slen <= hlen; i++) {
        if (memcmp(hay + i, sub, slen) == 0) return 1;
    }
    return 0;
}

static int is_numeric(const char *s) {
    if (!*s) return 0;
    while (*s) {
        if (!isdigit((unsigned char)*s)) return 0;
        s++;
    }
    return 1;
}

/* Basename of /proc/<pid>/exe symlink target, "" on error. */
static void exe_basename(pid_t pid, char *out, size_t cap) {
    char path[64], link[4096];
    snprintf(path, sizeof(path), "/proc/%d/exe", (int)pid);
    ssize_t n = readlink(path, link, sizeof(link) - 1);
    if (n < 0) {
        out[0] = '\0';
        return;
    }
    link[n] = '\0';
    /* "(deleted)" suffix can follow the path; cut it. */
    char *sp = strstr(link, " (deleted)");
    if (sp) *sp = '\0';
    char *base = strrchr(link, '/');
    base = base ? base + 1 : link;
    snprintf(out, cap, "%s", base);
}

/* Never touch our own helper or the ScreenGuard app/daemon. */
static int is_protected(pid_t pid) {
    if (pid == getpid()) return 1;
    char base[256];
    exe_basename(pid, base, sizeof(base));
    return strncmp(base, "screenguard", 11) == 0;
}

/* -- process tree ------------------------------------------------------ */

struct pid_list {
    pid_t *pids;
    size_t n, cap;
};

static void plist_add(struct pid_list *l, pid_t pid) {
    if (l->n == l->cap) {
        l->cap = l->cap ? l->cap * 2 : 64;
        l->pids = realloc(l->pids, l->cap * sizeof(pid_t));
        if (!l->pids) {
            perror("realloc");
            exit(1);
        }
    }
    l->pids[l->n++] = pid;
}

/* All descendants of root via one /proc ppid scan (BFS). */
static void descendants(pid_t root, struct pid_list *out) {
    struct { pid_t pid, ppid; } *all = NULL;
    size_t n = 0, cap = 0;
    DIR *d = opendir("/proc");
    if (!d) return;
    struct dirent *e;
    while ((e = readdir(d)) != NULL) {
        if (!is_numeric(e->d_name)) continue;
        pid_t p = (pid_t)atoi(e->d_name);
        if (p == root) continue;
        char path[64], buf[1024];
        snprintf(path, sizeof(path), "/proc/%d/stat", (int)p);
        if (read_file(path, buf, sizeof(buf)) < 0) continue;
        char *rp = strrchr(buf, ')');
        if (!rp) continue;
        /* stat fields after comm: state ppid ... — skip state token. */
        char *after = rp + 1;
        after += strspn(after, " \t");
        after += strcspn(after, " \t");
        after += strspn(after, " \t");
        pid_t ppid = (pid_t)atoi(after);
        if (n == cap) {
            cap = cap ? cap * 2 : 512;
            all = realloc(all, cap * sizeof(*all));
            if (!all) {
                perror("realloc");
                closedir(d);
                exit(1);
            }
        }
        all[n].pid = p;
        all[n].ppid = ppid;
        n++;
    }
    closedir(d);
    /* BFS from root over the child relation. */
    struct pid_list queue = { NULL, 0, 0 };
    plist_add(&queue, root);
    size_t head = 0;
    size_t guard = 0;
    while (head < queue.n && guard++ < 100000) {
        pid_t cur = queue.pids[head++];
        for (size_t i = 0; i < n; i++) {
            if (all[i].ppid == cur) {
                plist_add(out, all[i].pid);
                plist_add(&queue, all[i].pid);
            }
        }
    }
    free(queue.pids);
    free(all);
}

/* -- steam / proton ----------------------------------------------------- */

/* Read a "key" value from steamapps/appmanifest_<id>.acf. "" if absent. */
static void steam_manifest_field(const char *app_id, const char *key,
                                 char *out, size_t cap) {
    out[0] = '\0';
    const char *home = getenv("HOME");
    if (!home || !*home) return;
    const char *subs[] = {
        "/.local/share/Steam",
        "/.steam/steam",
        "/.var/app/com.valvesoftware.Steam/data/Steam",
    };
    char pattern[64];
    snprintf(pattern, sizeof(pattern), "\"%s\"", key);
    for (size_t i = 0; i < sizeof(subs) / sizeof(subs[0]); i++) {
        char path[1024];
        snprintf(path, sizeof(path), "%s%s/steamapps/appmanifest_%s.acf",
                 home, subs[i], app_id);
        char buf[65536];
        if (read_file(path, buf, sizeof(buf)) < 0) continue;
        char *hit = strstr(buf, pattern);
        if (!hit) continue;
        hit += strlen(pattern);
        while (*hit == ' ' || *hit == '\t') hit++;
        if (*hit != '"') continue;
        hit++;
        char *end = strchr(hit, '"');
        if (!end || (size_t)(end - hit) >= cap) continue;
        memcpy(out, hit, (size_t)(end - hit));
        out[end - hit] = '\0';
        /* trim */
        while (*out == ' ' || *out == '\t') memmove(out, out + 1, strlen(out));
        size_t l = strlen(out);
        while (l > 0 && (out[l - 1] == ' ' || out[l - 1] == '\t')) out[--l] = '\0';
        return;
    }
}

/* Run <wineserver-bin> -k with WINEPREFIX=<prefix>. 1 if delivered. */
static int wineserver_kill(const char *bin, const char *prefix) {
    if (g_dry_run) {
        log_step("would run: WINEPREFIX=%s %s -k", prefix, bin);
        return 1;
    }
    log_step("wineserver -k (prefix %.80s...)", prefix);
    pid_t c = fork();
    if (c < 0) {
        log_step("fork failed: %s", strerror(errno));
        return 0;
    }
    if (c == 0) {
        setenv("WINEPREFIX", prefix, 1);
        execl(bin, bin, "-k", (char *)NULL);
        _exit(127);
    }
    /* Wait up to 10 s, then reap forcefully. */
    int status = 0, done = 0;
    for (int i = 0; i < 200; i++) {
        pid_t w = waitpid(c, &status, WNOHANG);
        if (w == c) {
            done = 1;
            break;
        }
        sleep_ms(50);
    }
    if (!done) {
        kill(c, SIGKILL);
        waitpid(c, &status, 0);
        log_step("wineserver -k timed out");
        return 0;
    }
    return WIFEXITED(status) && WEXITSTATUS(status) != 127;
}

/* Find the wineserver owning compatdata/<app_id> and -k it. 1 if delivered. */
static int proton_kill(const char *app_id) {
    char needle[64];
    snprintf(needle, sizeof(needle), "compatdata/%s/", app_id);
    DIR *d = opendir("/proc");
    if (!d) return 0;
    struct dirent *e;
    int delivered = 0;
    while ((e = readdir(d)) != NULL) {
        if (!is_numeric(e->d_name)) continue;
        pid_t p = (pid_t)atoi(e->d_name);
        char path[64];
        static char cmd[65536], env[65536];
        snprintf(path, sizeof(path), "/proc/%d/cmdline", (int)p);
        int cn = read_file(path, cmd, sizeof(cmd));
        if (cn <= 0) continue;
        /* argv[0] is the first NUL-terminated token. */
        size_t a0len = strnlen(cmd, (size_t)cn);
        if (a0len < 10 || strcmp(cmd + a0len - 10, "wineserver") != 0) continue;
        snprintf(path, sizeof(path), "/proc/%d/environ", (int)p);
        int en = read_file(path, env, sizeof(env));
        if (en <= 0) continue;
        /* Walk NUL-separated VAR=value entries. */
        char prefix[1024] = "";
        size_t off = 0;
        while (off < (size_t)en) {
            char *ent = env + off;
            size_t elen = strnlen(ent, (size_t)en - off);
            if (elen == 0) break;
            if (strncmp(ent, "WINEPREFIX=", 11) == 0 &&
                contains_bytes(ent, elen, needle)) {
                snprintf(prefix, sizeof(prefix), "%s", ent + 11);
                break;
            }
            off += elen + 1;
        }
        if (!prefix[0]) continue;
        char bin[4096];
        snprintf(bin, sizeof(bin), "%.*s", (int)a0len, cmd);
        delivered = wineserver_kill(bin, prefix);
        break; /* one wineserver per prefix */
    }
    closedir(d);
    if (!delivered) log_step("no wineserver found for app %s", app_id);
    return delivered;
}

/* -- pattern kill (exe basename / install dir) -------------------------- */

static const char *runtime_blocklist[] = {
    "wineserver", "wineserver64", "wineserver32", "wine", "wine64",
    "wine-preloader", "steam", "steamwebhelper", "proton", "python",
    "python3", "bash", "sh", "dash", "gdbus", "screenguard",
    "screenguard-daemon", "screenguard-killer", NULL,
};

static int is_blocklisted(const char *pattern) {
    /* Compare against the basename, case-insensitively. */
    const char *base = strrchr(pattern, '/');
    base = base ? base + 1 : pattern;
    char lower[256];
    size_t i;
    for (i = 0; i < sizeof(lower) - 1 && base[i]; i++)
        lower[i] = (char)tolower((unsigned char)base[i]);
    lower[i] = '\0';
    for (size_t k = 0; runtime_blocklist[k]; k++) {
        if (strcmp(lower, runtime_blocklist[k]) == 0) return 1;
    }
    return strncmp(lower, "screenguard", 11) == 0;
}

/* SIGKILL every process whose cmdline contains <pattern>. Returns kills. */
static int pattern_kill(const char *label, const char *pattern) {
    if (is_blocklisted(pattern)) {
        log_step("%s '%s' skipped (runtime binary — too broad)", label, pattern);
        return 0;
    }
    DIR *d = opendir("/proc");
    if (!d) return 0;
    int kills = 0;
    struct dirent *e;
    static char cmd[131072];
    while ((e = readdir(d)) != NULL) {
        if (!is_numeric(e->d_name)) continue;
        pid_t p = (pid_t)atoi(e->d_name);
        if (p <= 1 || is_protected(p)) continue;
        char path[64];
        snprintf(path, sizeof(path), "/proc/%d/cmdline", (int)p);
        int n = read_file(path, cmd, sizeof(cmd));
        if (n <= 0) continue; /* kernel thread or gone */
        if (!contains_bytes(cmd, (size_t)n, pattern)) continue;
        if (g_dry_run) {
            log_step("would SIGKILL %d (matches '%s')", (int)p, pattern);
            kills++;
            continue;
        }
        if (kill(p, SIGKILL) == 0) {
            log_step("SIGKILL %d (matches '%s')", (int)p, pattern);
            kills++;
        }
    }
    closedir(d);
    if (kills == 0) log_step("no process matched '%s'", pattern);
    return kills;
}

/* 1 if any live process cmdline contains <pattern>. */
static int any_match(const char *pattern) {
    DIR *d = opendir("/proc");
    if (!d) return 0;
    int found = 0;
    struct dirent *e;
    static char cmd[131072];
    while ((e = readdir(d)) != NULL && !found) {
        if (!is_numeric(e->d_name)) continue;
        pid_t p = (pid_t)atoi(e->d_name);
        if (p <= 1 || p == getpid()) continue;
        char path[64];
        snprintf(path, sizeof(path), "/proc/%d/cmdline", (int)p);
        int n = read_file(path, cmd, sizeof(cmd));
        if (n <= 0) continue;
        if (contains_bytes(cmd, (size_t)n, pattern)) found = 1;
    }
    closedir(d);
    return found;
}

/* Exe token for a pid: the .exe argv token if present, else basename of the
 * last argv token. Mirrors the old Dart _exeName. */
static void exe_token(pid_t pid, char *out, size_t cap) {
    out[0] = '\0';
    char path[64];
    static char cmd[131072];
    snprintf(path, sizeof(path), "/proc/%d/cmdline", (int)pid);
    int n = read_file(path, cmd, sizeof(cmd));
    if (n <= 0) return;
    /* Collect tokens. */
    char *toks[1024];
    size_t ntok = 0, off = 0;
    while (off < (size_t)n && ntok < 1024) {
        char *t = cmd + off;
        size_t tl = strnlen(t, (size_t)n - off);
        if (tl == 0) break;
        toks[ntok++] = t;
        off += tl + 1;
    }
    if (ntok == 0) return;
    /* Prefer a .exe argv token (wine/proton). Otherwise use the last token
     * only if it looks like a program path/name (not a flag or bare arg
     * like "60"); fall back to argv[0]. This keeps generic interpreters
     * (sh, bash, python) resolving to their blocklisted binary names. */
    char *pick = NULL;
    for (size_t i = 0; i < ntok; i++) {
        size_t l = strlen(toks[i]);
        if (l > 4 && strcasecmp(toks[i] + l - 4, ".exe") == 0) {
            pick = toks[i];
            break;
        }
    }
    if (!pick) {
        char *last = toks[ntok - 1];
        if (last[0] != '-' &&
            (strchr(last, '/') || strchr(last, '\\') || strchr(last, '.'))) {
            pick = last;
        } else {
            pick = toks[0];
        }
    }
    char *base = strrchr(pick, '/');
    base = base ? base + 1 : pick;
    char *bs = strrchr(base, '\\');
    base = bs ? bs + 1 : base;
    while (*base == ' ' || *base == '\t') base++;
    if (!*base || strcmp(base, "exe") == 0) return;
    snprintf(out, cap, "%s", base);
}

/* -- kill log ------------------------------------------------------------ */

static void write_kill_log(int result) {
    const char *home = getenv("HOME");
    if (!home || !*home) return;
    char path[1024], tmp[1088];
    snprintf(path, sizeof(path), "%s/.local/share/screenguard/kill.log", home);
    snprintf(tmp, sizeof(tmp), "%s.tmp", path);
    char existing[200][1024];
    size_t nlines = 0;
    FILE *f = fopen(path, "r");
    if (f) {
        while (nlines < 200 && fgets(existing[nlines], sizeof(existing[0]), f))
            nlines++;
        fclose(f);
    }
    f = fopen(tmp, "w");
    if (!f) return;
    size_t start = nlines >= 200 ? nlines - 199 : 0;
    for (size_t i = start; i < nlines; i++) fputs(existing[i], f);
    time_t now = time(NULL);
    struct tm tm;
    localtime_r(&now, &tm);
    char ts[32];
    strftime(ts, sizeof(ts), "%Y-%m-%dT%H:%M:%S", &tm);
    /* strip trailing newline of carried lines is already handled by fgets */
    fprintf(f, "[%s] app=%s pid=%d result=%s :: %s\n", ts,
            g_app[0] ? g_app : "-",
            (int)g_pid, result ? "true" : "false",
            g_steps[0] ? g_steps : "(no steps)");
    fclose(f);
    rename(tmp, path);
}

/* -- main ---------------------------------------------------------------- */

static void usage(void) {
    fprintf(stderr,
            "usage: screenguard-killer --pid <n> [--app <id>] [--dry-run]\n"
            "  exit 0 = target gone, 1 = still alive, 2 = usage error\n");
}

int main(int argc, char **argv) {
    long pid_arg = -1;
    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--pid") == 0 && i + 1 < argc) {
            pid_arg = atol(argv[++i]);
        } else if (strcmp(argv[i], "--app") == 0 && i + 1 < argc) {
            snprintf(g_app, sizeof(g_app), "%s", argv[++i]);
        } else if (strcmp(argv[i], "--dry-run") == 0) {
            g_dry_run = 1;
        } else {
            usage();
            return 2;
        }
    }
    if (pid_arg > 0) g_pid = (pid_t)pid_arg;

    const char *steam_id = NULL;
    static char steam_buf[64];
    if (strncmp(g_app, "steam_app_", 10) == 0 && is_numeric(g_app + 10)) {
        snprintf(steam_buf, sizeof(steam_buf), "%s", g_app + 10);
        steam_id = steam_buf;
    }

    int has_pid = g_pid > 1000;

    if (has_pid && !alive(g_pid)) {
        log_step("pid %d already gone", (int)g_pid);
        write_kill_log(1);
        return 0;
    }

    /* Stage 1: SIGTERM. */
    if (has_pid) {
        if (g_dry_run) {
            log_step("would SIGTERM %d, wait 3s", (int)g_pid);
        } else {
            if (kill(g_pid, SIGTERM) == 0)
                log_step("SIGTERM %d", (int)g_pid);
            else
                log_step("SIGTERM %d failed: %s", (int)g_pid, strerror(errno));
            if (!wait_dead(g_pid, 3000)) {
                log_step("pid %d exited after SIGTERM", (int)g_pid);
                write_kill_log(1);
                return 0;
            }
            log_step("pid %d survived SIGTERM", (int)g_pid);
        }

        /* Stage 2: SIGKILL pid + whole descendant tree. */
        struct pid_list tree = { NULL, 0, 0 };
        descendants(g_pid, &tree);
        log_step("tree under %d: %zu descendant(s)", (int)g_pid, tree.n);
        if (g_dry_run) {
            for (size_t i = 0; i < tree.n; i++)
                log_step("would SIGKILL descendant %d", (int)tree.pids[i]);
            log_step("would SIGKILL %d", (int)g_pid);
        } else {
            for (size_t i = tree.n; i > 0; i--) kill(tree.pids[i - 1], SIGKILL);
            kill(g_pid, SIGKILL);
            log_step("SIGKILL %d + tree", (int)g_pid);
            if (!wait_dead(g_pid, 1000)) {
                log_step("pid %d dead after SIGKILL", (int)g_pid);
                free(tree.pids);
                write_kill_log(1);
                return 0;
            }
            log_step("pid %d survived SIGKILL?!", (int)g_pid);
        }
        free(tree.pids);
    }

    /* Stage 3: Proton-native wineserver -k. */
    if (steam_id) {
        int delivered = proton_kill(steam_id);
        if (delivered && !g_dry_run) sleep_ms(1000);
        if (has_pid && !g_dry_run && !alive(g_pid)) {
            log_step("pid %d dead after wineserver -k", (int)g_pid);
            write_kill_log(1);
            return 0;
        }
        if (!has_pid && delivered && !g_dry_run) {
            char dir[256];
            steam_manifest_field(steam_id, "installdir", dir, sizeof(dir));
            if (dir[0] && !any_match(dir)) {
                log_step("no process left matching installdir '%s'", dir);
                write_kill_log(1);
                return 0;
            }
        }
    }

    /* Stage 4: pkill -f exe basename. */
    if (has_pid) {
        char exe[256];
        exe_token(g_pid, exe, sizeof(exe));
        log_step("exe token for %d: '%s'", (int)g_pid,
                 exe[0] ? exe : "<unknown>");
        if (exe[0]) {
            int k = pattern_kill("exe pattern", exe);
            if (k > 0 && !g_dry_run) sleep_ms(1000);
            if (!g_dry_run && !alive(g_pid)) {
                log_step("pid %d dead after pattern kill", (int)g_pid);
                write_kill_log(1);
                return 0;
            }
        }
    }

    /* Stage 5: pkill -f Steam install dir (last resort). */
    if (steam_id) {
        char dir[256];
        steam_manifest_field(steam_id, "installdir", dir, sizeof(dir));
        if (dir[0] && strlen(dir) >= 4) {
            char lower[256];
            size_t i;
            for (i = 0; i < sizeof(lower) - 1 && dir[i]; i++)
                lower[i] = (char)tolower((unsigned char)dir[i]);
            lower[i] = '\0';
            const char *generic[] = { "common", "steamapps", "game", "bin",
                                      "steam", "data", "app", NULL };
            int is_generic = 0;
            for (size_t k = 0; generic[k]; k++) {
                if (strcmp(lower, generic[k]) == 0) {
                    is_generic = 1;
                    break;
                }
            }
            if (!is_generic) {
                int k = pattern_kill("installdir pattern", dir);
                if (k > 0 && !g_dry_run) sleep_ms(1000);
                if (!g_dry_run) {
                    if (has_pid && !alive(g_pid)) {
                        write_kill_log(1);
                        return 0;
                    }
                    if (!has_pid && !any_match(dir)) {
                        log_step("no process left matching '%s'", dir);
                        write_kill_log(1);
                        return 0;
                    }
                }
            } else {
                log_step("installdir '%s' too generic, skipped", dir);
            }
        }
    }

    if (g_dry_run) {
        /* Dry runs change nothing: don't pollute kill.log with them. */
        return 0;
    }
    if (!has_pid && !steam_id) {
        log_step("no pid and no steam app given — nothing to kill");
        write_kill_log(0);
        return 1;
    }
    int dead = has_pid ? !alive(g_pid) : 0;
    log_step(dead ? "target confirmed dead" : "target still alive — giving up");
    write_kill_log(dead);
    return dead ? 0 : 1;
}
