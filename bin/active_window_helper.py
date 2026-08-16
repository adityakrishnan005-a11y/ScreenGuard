#!/usr/bin/env python3
"""AT-SPI helper for ScreenGuard on Wayland (GNOME).

Prints a single JSON line describing the currently focused application window:
  {"app": <app-id or wm_class>, "title": <window title>, "pid": <int|null>}

No GNOME Shell extension or gdbus Eval is required. AT-SPI works on GNOME
Wayland out of the box; enabling org.gnome.desktop.interface
toolkit-accessibility gives fuller application-window data.
"""
import json
import pyatspi

# Shell/desktop/panel actors that are not real user applications.
EXCLUDE_APPS = {
    "gnome-shell", "gnome-shell-wayland", "mutter", "desktop", "panel",
    "gnome-shell-calendar-server", "xdamage", "xwayland",
}


def get_pid(app):
    try:
        return int(app.processId)
    except Exception:
        try:
            return int(app.getProcessId())
        except Exception:
            return None


def real_window_roles():
    return {
        "frame", "window", "dialog", "alert",
        "document web", "page tab", "embedded", "application",
        "root pane", "panel", "section", "scroll pane"
    }


def find_focused(node, allow_any_role=False):
    try:
        focused = node.getState().contains(pyatspi.STATE_FOCUSED)
    except Exception:
        focused = False

    if focused:
        try:
            app = node.getApplication()
            app_name = (app.name or "").strip()
        except Exception:
            app_name = ""
        if app_name and app_name.lower() not in EXCLUDE_APPS:
            role = ""
            try:
                role = node.getRoleName()
            except Exception:
                role = ""
            if allow_any_role or role in real_window_roles():
                try:
                    title = node.name or ""
                except Exception:
                    title = ""
                return (app_name, title, get_pid(app))

    try:
        for i in range(node.childCount):
            r = find_focused(node.getChildAtIndex(i), allow_any_role)
            if r:
                return r
    except Exception:
        pass
    return None


def main():
    try:
        desktop = pyatspi.Registry.getDesktop(0)
    except Exception:
        print(json.dumps({"app": "unknown", "title": None, "pid": None}))
        return

    result = find_focused(desktop, allow_any_role=False)
    if not result:
        result = find_focused(desktop, allow_any_role=True)
    if result:
        app_name, title, pid = result
        print(json.dumps({"app": app_name, "title": title or None, "pid": pid}))
    else:
        print(json.dumps({"app": "unknown", "title": None, "pid": None}))


if __name__ == "__main__":
    main()
