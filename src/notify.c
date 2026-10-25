/*
 * screenguard-notify — standalone, high-reliability desktop notification utility.
 *
 * Connects directly to the Freedesktop Notifications D-Bus interface
 * (org.freedesktop.Notifications) via GDBus.
 *
 * Features:
 *   - Automatic D-Bus session bus detection (handles systemd services,
 *     headless launches, and missing DBUS_SESSION_BUS_ADDRESS env vars).
 *   - Native D-Bus call to org.freedesktop.Notifications.Notify.
 *   - Does NOT emit broken vendor hints (e.g. desktop-entry which causes
 *     GNOME Shell to destroy notifications immediately upon sender exit).
 *   - Supports urgency, icons, sound playback, custom timeout, and categories.
 *   - Fallback to notify-send / console logging if D-Bus is temporarily unreachable.
 *
 * Build:
 *   cc -O2 -Wall -Wextra $(pkg-config --cflags --libs gio-2.0) -o screenguard-notify src/notify.c
 */

#define _POSIX_C_SOURCE 200809L
#include <gio/gio.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <fcntl.h>
#include <errno.h>

#define DEFAULT_APP_NAME "ScreenGuard"
#define DEFAULT_TIMEOUT_MS 5000

static void print_usage(const char *prog) {
    fprintf(stderr,
        "Usage: %s [OPTIONS] <TITLE> [BODY]\n"
        "\n"
        "Options:\n"
        "  -t, --title <TEXT>        Notification title / summary\n"
        "  -b, --body <TEXT>         Notification body text\n"
        "  -i, --icon <ICON>         Icon name or path (default: 'screenguard' or 'dialog-information')\n"
        "  -u, --urgency <LEVEL>     Urgency: low (0), normal (1), critical (2) [default: normal]\n"
        "  -e, --expire <MS>         Timeout in milliseconds (default: 5000; 0 = sticky)\n"
        "  -k, --category <CAT>      Notification category (e.g. 'im.received', 'presence')\n"
        "  -s, --sound <PATH>        Sound file path to play asynchronously\n"
        "  -r, --replace-id <ID>     Replace existing notification by ID\n"
        "  -v, --verbose             Print debug info to stderr\n"
        "  -h, --help                Show this help message\n",
        prog);
}

static void ensure_session_bus_env(void) {
    if (!getenv("DBUS_SESSION_BUS_ADDRESS")) {
        char bus_path[256];
        const char *runtime_dir = getenv("XDG_RUNTIME_DIR");
        if (runtime_dir && runtime_dir[0] != '\0') {
            snprintf(bus_path, sizeof(bus_path), "unix:path=%s/bus", runtime_dir);
        } else {
            snprintf(bus_path, sizeof(bus_path), "unix:path=/run/user/%d/bus", (int)getuid());
        }
        setenv("DBUS_SESSION_BUS_ADDRESS", bus_path, 0);
    }
}

static void play_sound_async(const char *sound_path) {
    if (!sound_path || sound_path[0] == '\0' || access(sound_path, R_OK) != 0) {
        return;
    }

    pid_t pid = fork();
    if (pid == 0) {
        // Child process: attempt to play using system audio players in order
        // Detach standard streams to prevent blocking
        int null_fd = open("/dev/null", O_RDWR);
        if (null_fd >= 0) {
            dup2(null_fd, STDIN_FILENO);
            dup2(null_fd, STDOUT_FILENO);
            dup2(null_fd, STDERR_FILENO);
            close(null_fd);
        }

        // 1. PipeWire pw-cat (standard on Fedora / modern Linux)
        execlp("pw-cat", "pw-cat", "-p", sound_path, (char *)NULL);
        // 2. PulseAudio paplay
        execlp("paplay", "paplay", sound_path, (char *)NULL);
        // 3. libcanberra canberra-gtk-play
        execlp("canberra-gtk-play", "canberra-gtk-play", "-f", sound_path, (char *)NULL);
        // 4. ALSA aplay
        execlp("aplay", "aplay", "-q", sound_path, (char *)NULL);
        // 5. mpv
        execlp("mpv", "mpv", "--no-video", "--really-quiet", sound_path, (char *)NULL);

        _exit(1);
    }
}

static const char *resolve_default_icon(void) {
    // Check if the installed SVG icon exists
    if (access("/usr/share/icons/hicolor/scalable/apps/screenguard.svg", R_OK) == 0) {
        return "screenguard";
    }
    char user_icon[512];
    const char *home = getenv("HOME");
    if (home) {
        snprintf(user_icon, sizeof(user_icon), "%s/.local/share/icons/hicolor/scalable/apps/screenguard.svg", home);
        if (access(user_icon, R_OK) == 0) {
            return "screenguard";
        }
    }
    return "dialog-information";
}

int main(int argc, char **argv) {
    const char *title = NULL;
    const char *body = "";
    const char *icon = NULL;
    const char *sound = NULL;
    const char *category = NULL;
    int urgency = 1; // 0=low, 1=normal, 2=critical
    int expire_ms = DEFAULT_TIMEOUT_MS;
    guint32 replace_id = 0;
    int verbose = 0;

    // Argument parsing
    int pos_idx = 0;
    for (int i = 1; i < argc; i++) {
        const char *arg = argv[i];
        if (strcmp(arg, "-h") == 0 || strcmp(arg, "--help") == 0) {
            print_usage(argv[0]);
            return 0;
        } else if (strcmp(arg, "-v") == 0 || strcmp(arg, "--verbose") == 0) {
            verbose = 1;
        } else if ((strcmp(arg, "-t") == 0 || strcmp(arg, "--title") == 0) && i + 1 < argc) {
            title = argv[++i];
        } else if ((strcmp(arg, "-b") == 0 || strcmp(arg, "--body") == 0) && i + 1 < argc) {
            body = argv[++i];
        } else if ((strcmp(arg, "-i") == 0 || strcmp(arg, "--icon") == 0) && i + 1 < argc) {
            icon = argv[++i];
        } else if ((strcmp(arg, "-s") == 0 || strcmp(arg, "--sound") == 0) && i + 1 < argc) {
            sound = argv[++i];
        } else if ((strcmp(arg, "-k") == 0 || strcmp(arg, "--category") == 0) && i + 1 < argc) {
            category = argv[++i];
        } else if ((strcmp(arg, "-e") == 0 || strcmp(arg, "--expire") == 0) && i + 1 < argc) {
            expire_ms = atoi(argv[++i]);
        } else if ((strcmp(arg, "-r") == 0 || strcmp(arg, "--replace-id") == 0) && i + 1 < argc) {
            replace_id = (guint32)strtoul(argv[++i], NULL, 10);
        } else if ((strcmp(arg, "-u") == 0 || strcmp(arg, "--urgency") == 0) && i + 1 < argc) {
            const char *u = argv[++i];
            if (strcmp(u, "low") == 0 || strcmp(u, "0") == 0) urgency = 0;
            else if (strcmp(u, "critical") == 0 || strcmp(u, "2") == 0) urgency = 2;
            else urgency = 1;
        } else if (arg[0] != '-') {
            if (pos_idx == 0 && !title) {
                title = arg;
                pos_idx++;
            } else if (pos_idx == 1 && (!body || body[0] == '\0')) {
                body = arg;
                pos_idx++;
            }
        }
    }

    if (!title || title[0] == '\0') {
        fprintf(stderr, "Error: Notification title is required.\n");
        print_usage(argv[0]);
        return 1;
    }

    if (!icon || icon[0] == '\0') {
        icon = (urgency == 2) ? "dialog-warning" : resolve_default_icon();
    }

    if (sound && sound[0] != '\0') {
        play_sound_async(sound);
    }

    ensure_session_bus_env();

    GError *error = NULL;
    GDBusConnection *conn = g_bus_get_sync(G_BUS_TYPE_SESSION, NULL, &error);
    if (!conn) {
        if (verbose) {
            fprintf(stderr, "[screenguard-notify] Warning: cannot connect to D-Bus session bus: %s\n",
                    error ? error->message : "unknown");
        }
        g_clear_error(&error);

        // Fallback to notify-send if D-Bus GIO connection failed
        pid_t fb = fork();
        if (fb == 0) {
            char u_str[16];
            snprintf(u_str, sizeof(u_str), "%s", urgency == 2 ? "critical" : (urgency == 0 ? "low" : "normal"));
            execlp("notify-send", "notify-send", title, body, "-u", u_str, "-i", icon, "-a", DEFAULT_APP_NAME, (char *)NULL);
            _exit(1);
        }
        waitpid(fb, NULL, 0);
        return 0;
    }

    // Prepare hints dictionary
    GVariantBuilder hints_builder;
    g_variant_builder_init(&hints_builder, G_VARIANT_TYPE("a{sv}"));
    g_variant_builder_add(&hints_builder, "{sv}", "urgency", g_variant_new_byte((guchar)urgency));
    if (category && category[0] != '\0') {
        g_variant_builder_add(&hints_builder, "{sv}", "category", g_variant_new_string(category));
    }

    // NOTE: We intentionally DO NOT set 'desktop-entry' hint!
    // In GNOME Shell's notification daemon (notificationDaemon.js), associating
    // an app with a transient CLI sender causes GNOME to destroy the notification
    // immediately when the CLI process disconnects from D-Bus (_onNameVanished).

    // Empty actions array
    GVariantBuilder actions_builder;
    g_variant_builder_init(&actions_builder, G_VARIANT_TYPE("as"));

    GVariant *params = g_variant_new(
        "(susssasa{sv}i)",
        DEFAULT_APP_NAME,          // app_name
        replace_id,                // replaces_id
        icon,                      // app_icon
        title,                     // summary
        body,                      // body
        &actions_builder,          // actions
        &hints_builder,            // hints
        (gint32)expire_ms          // expire_timeout
    );

    GVariant *res = g_dbus_connection_call_sync(
        conn,
        "org.freedesktop.Notifications",
        "/org/freedesktop/Notifications",
        "org.freedesktop.Notifications",
        "Notify",
        params,
        G_VARIANT_TYPE("(u)"),
        G_DBUS_CALL_FLAGS_NONE,
        5000,
        NULL,
        &error
    );

    if (!res) {
        if (verbose) {
            fprintf(stderr, "[screenguard-notify] D-Bus Notify call failed: %s\n",
                    error ? error->message : "unknown");
        }
        g_clear_error(&error);
        g_object_unref(conn);
        return 1;
    }

    guint32 nid = 0;
    g_variant_get(res, "(u)", &nid);
    if (verbose) {
        printf("ID: %u\n", nid);
    }

    g_variant_unref(res);
    g_object_unref(conn);
    return 0;
}
