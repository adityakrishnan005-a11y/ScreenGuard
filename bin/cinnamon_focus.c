/* ScreenGuard helper: the focused window from muffin (Cinnamon's compositor)
 * over D-Bus. Prints one JSON line:
 *   {"app": "<app-id>", "title": "<window title>", "pid": <int>}
 *
 * Build:
 *   cc -O2 -o cinnamon_focus cinnamon_focus.c \
 *      $(pkg-config --cflags --libs gio-2.0)
 *
 * Exit codes:
 *   0  printed a focused window
 *   1  no session bus
 *   2  muffin's debug interface is not available
 *   3  the ListWindows call failed
 *   4  no window is focused (nothing printed)
 *
 * The title is user-controlled text, so it is JSON-escaped here rather than
 * trusting the caller to fix it up.
 */
#include <gio/gio.h>
#include <string.h>
#include <stdio.h>

static void copy_field(GVariant *window, const char *key, char *out, size_t out_len) {
    GVariant *v = g_variant_lookup_value(window, key, G_VARIANT_TYPE_STRING);
    if (!v) return;
    g_strlcpy(out, g_variant_get_string(v, NULL), out_len);
    g_variant_unref(v);
}

/* Escape one UTF-8 string for a JSON double-quoted value. The result must be
 * freed with g_free(). Bytes >= 0x20 pass through unchanged (valid UTF-8 in,
 * valid UTF-8 out); quotes, backslashes and C0 controls are escaped. */
static char *json_escape(const char *in) {
    GString *out = g_string_new(NULL);
    for (const unsigned char *p = (const unsigned char *)in; *p; p++) {
        switch (*p) {
        case '"':  g_string_append(out, "\\\""); break;
        case '\\': g_string_append(out, "\\\\"); break;
        case '\b': g_string_append(out, "\\b");  break;
        case '\f': g_string_append(out, "\\f");  break;
        case '\n': g_string_append(out, "\\n");  break;
        case '\r': g_string_append(out, "\\r");  break;
        case '\t': g_string_append(out, "\\t");  break;
        default:
            if (*p < 0x20) {
                g_string_append_printf(out, "\\u%04x", *p);
            } else {
                g_string_append_c(out, (char)*p);
            }
        }
    }
    return g_string_free(out, FALSE);
}

/* Picks the window muffin reports as focused and renders it as JSON.
 * `windows` is the aa{sv} payload of Muffin.Debug.ListWindows. */
static char *focused_json(GVariant *windows) {
    GVariantIter iter;
    g_variant_iter_init(&iter, windows);

    GVariant *window;
    while (g_variant_iter_next(&iter, "@a{sv}", &window)) {
        GVariant *focused = g_variant_lookup_value(window, "focused", G_VARIANT_TYPE_BOOLEAN);
        gboolean is_focused = focused && g_variant_get_boolean(focused);
        g_clear_pointer(&focused, g_variant_unref);

        if (is_focused) {
            char app[256] = {0};
            char title[512] = {0};
            gint32 pid = 0;

            copy_field(window, "app-id", app, sizeof app);
            if (!app[0]) copy_field(window, "wm-class", app, sizeof app);
            copy_field(window, "title", title, sizeof title);

            GVariant *pid_v = g_variant_lookup_value(window, "pid", G_VARIANT_TYPE_INT32);
            if (pid_v) { pid = g_variant_get_int32(pid_v); g_variant_unref(pid_v); }

            char *lower = g_ascii_strdown(app, -1);
            if (g_str_has_suffix(lower, ".desktop")) lower[strlen(lower) - 8] = '\0';

            char *app_json = json_escape(lower);
            char *title_json = json_escape(title);
            char *json = g_strdup_printf(
                "{\"app\": \"%s\", \"title\": \"%s\", \"pid\": %d}",
                app_json, title_json, pid);
            g_free(app_json);
            g_free(title_json);
            g_free(lower);
            g_variant_unref(window);
            return json;
        }
        g_variant_unref(window);
    }
    return NULL;
}

int main(void) {
    GError *error = NULL;

    GDBusConnection *bus = g_bus_get_sync(G_BUS_TYPE_SESSION, NULL, &error);
    if (!bus) {
        g_printerr("bus: %s\n", error ? error->message : "unavailable");
        g_clear_error(&error);
        return 1;
    }

    GDBusProxy *proxy = g_dbus_proxy_new_sync(bus, G_DBUS_PROXY_FLAGS_NONE, NULL,
                                              "org.cinnamon.Muffin.Debug",
                                              "/org/cinnamon/Muffin/Debug",
                                              "org.cinnamon.Muffin.Debug",
                                              NULL, &error);
    if (!proxy) {
        g_printerr("proxy: %s\n", error ? error->message : "unavailable");
        g_clear_error(&error);
        g_object_unref(bus);
        return 2;
    }

    GVariant *reply = g_dbus_proxy_call_sync(proxy, "ListWindows", NULL,
                                              G_DBUS_CALL_FLAGS_NONE, 2000, NULL, &error);
    if (!reply) {
        g_printerr("call: %s\n", error ? error->message : "failed");
        g_clear_error(&error);
        g_object_unref(proxy);
        g_object_unref(bus);
        return 3;
    }

    GVariant *windows = g_variant_get_child_value(reply, 0);
    char *json = focused_json(windows);
    int rc = 4;
    if (json) { printf("%s\n", json); g_free(json); rc = 0; }

    g_variant_unref(windows);
    g_variant_unref(reply);
    g_object_unref(proxy);
    g_object_unref(bus);
    return rc;
}
