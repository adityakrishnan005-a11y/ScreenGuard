# AGENTS(debugging).md — ScreenGuard Debugging & Diagnostic Reference

This document provides runtime debugging, tracing, and diagnostic procedures for ScreenGuard daemons, display server backends, and storage layers.

---

## 1. Display Backend Diagnostics

ScreenGuard delegates window tracking to backend implementations depending on the active session type (`$XDG_SESSION_TYPE`).

### X11 Backend (`X11Backend`)
* **Active Window Tracing**:
  ```bash
  # Check active window ID
  xdotool getactivewindow
  # Inspect WM_CLASS and title of focused window
  xprop -id $(xdotool getactivewindow) WM_CLASS _NET_WM_NAME
  ```
* **Idle Time Inspection**:
  ```bash
  # Verify idle timer reporting (returns milliseconds)
  xprintidle
  ```
* **Common Failure Modes**:
  * Missing dependencies: Ensure `xdotool`, `xprop`, and `xprintidle` are in `$PATH`.
  * Virtual screens / nested sessions returning `0` or null window handles.

### GNOME Wayland Backend (`GnomeWaylandBackend`)
* **GNOME Shell Extension Interface**:
  ```bash
  # Test D-Bus interface accessibility
  gdbus call --session \
    --dest org.gnome.Shell.Extensions.ScreenGuard \
    --object-path /org/gnome/Shell/Extensions/ScreenGuard \
    --method org.gnome.Shell.Extensions.ScreenGuard.GetActiveWindow
  ```
* **AT-SPI Python Fallback Helper**:
  ```bash
  # Run the standalone active window diagnostic helper
  python3 bin/active_window_helper.py
  ```
  * Verify PyAT-SPI accessibility bindings are active (`python3-pyatspi` on Debian/Fedora, `python-atspi` on Arch).
  * Ensure AT-SPI bus is running (`/usr/libexec/at-spi-bus-launcher` or `systemctl --user status at-spi-dbus-bus`).

---

## 2. Daemon & Service Diagnostics

### Systemd User Service
* **Inspect Daemon Status & Logs**:
  ```bash
  systemctl --user status screenguard-daemon
  journalctl --user -u screenguard-daemon -f -o cat
  ```
* **Manual Debug Mode**:
  Run the compiled binary directly in a terminal to observe live polling and state transitions:
  ```bash
  screenguard-daemon --verbose
  ```

---

## 3. Database & Lock Troubleshooting

ScreenGuard persists window durations to SQLite using WAL mode (`~/.local/share/screenguard/usage.db`).

* **Inspect Database Integrity & Pragma Settings**:
  ```bash
  sqlite3 ~/.local/share/screenguard/usage.db "PRAGMA journal_mode; PRAGMA integrity_check;"
  ```
* **Active Sessions & Durations**:
  ```bash
  # View latest 10 recorded sessions
  sqlite3 ~/.local/share/screenguard/usage.db \
    "SELECT id, app_name, start_time, end_time, duration_ms FROM sessions ORDER BY start_time DESC LIMIT 10;"
  ```
* **Diagnosing Locking (`SQLITE_BUSY`)**:
  * The daemon and Flutter GUI both open SQLite with `PRAGMA busy_timeout=5000;`.
  * If write transactions stall, verify that no orphaned processes hold open write transactions on `usage.db-wal` or `usage.db-shm`.

---

## 4. Application Identity & Desktop Entry Resolution

* **Desktop File Lookup Order**:
  1. `$XDG_DATA_HOME/applications/` (`~/.local/share/applications/`)
  2. `/usr/local/share/applications/`
  3. `/usr/share/applications/`
  4. Flatpak exports: `/var/lib/flatpak/exports/share/applications/` and `~/.local/share/flatpak/exports/share/applications/`
* **StartupWMClass Matching**:
  * If an app appears as `Unknown` or raw process name, verify if its `.desktop` entry defines `StartupWMClass=` matching the window's `WM_CLASS`.
  * For Electron applications with dynamic or non-standard class names, inspect the alias mappings in `lib/services/app_resolver.dart`.

---

## 5. Build & Environment Verification

* **Required Toolchain Packages**:
  * Build: `clang`, `cmake`, `ninja`, `pkg-config`, `libgtk-3-dev`, `libsqlite3-dev`
  * Runtime: `xdotool`, `xprop`, `xprintidle`, `python3-pyatspi` / `python-atspi`
