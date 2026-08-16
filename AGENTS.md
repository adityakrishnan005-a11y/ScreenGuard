# AGENTS.md — ScreenGuard Conventions & Decisions

## Project
Screen time tracker for Linux (Flutter desktop + Dart daemon). Root: `/home/aditya/screenguard`.

## Hard Decisions (do not re-litigate)
- Display targets: **X11 and GNOME Wayland**. `WindowBackend` interface with `X11Backend` (xdotool/xprop/xprintidle) and `GnomeWaylandBackend` (GNOME Shell Extension D-Bus service `screenguard@screenguard.app` with AT-SPI helper fallback + Mutter IdleMonitor). Other Wayland compositors (KDE/Sway) still TODO.
- Always-on daemon via `systemd --user`; GUI only reads DB.
- SQLite (`sqlite3` package) with WAL; single shared DB at `~/.local/share/screenguard/usage.db` (or `$XDG_DATA_HOME/screenguard`). Do NOT use sqflite/path_provider.
- App display names come from `.desktop` files (`Name=`, matched via `StartupWMClass`), i.e. the OS/desktop-provided label (Android Digital Wellbeing equivalent). A small built-in const map in `app_resolver.dart` covers Electron exceptions (VS Code/Slack/etc.) where `WM_CLASS` != a `.desktop`. No hand-edited override JSON (clunky); an in-app alias/rename UI is deferred.
- Native packaging: deb (Ubuntu), rpm (Fedora), AUR (Arch). No Flatpak/snap for v1 (sandbox blocks subprocess access).

## Code Style
- Dart/Flutter defaults (flutter_lints). No comments unless asked.
- State management: `provider`.
- Charts: `fl_chart`.
- Subprocess calls (xdotool/xprop/xprintidle/gdbus/python3 helper): via `dart:io` `Process.run`, never shell-strings.
- Times stored as epoch **milliseconds** (int) in DB.

## DB Rules
- Open with `PRAGMA journal_mode=WAL; PRAGMA busy_timeout=5000;`
- `sessions` table is append/close only; never UPDATE durations after close except on the open row.

## Build / Run
- Daemon entry: `bin/daemon.dart` (compiled/run separately from GUI).
- GUI entry: `lib/main.dart`.
- X11 runtime: `xdotool`, `xprop`, `xprintidle`.
- GNOME Wayland runtime: `python3` + `python3-pyatspi` (Fedora) / `python3-pyatspi` (Debian/Ubuntu) / `python-atspi` (Arch); helper `bin/active_window_helper.py` resolves from CWD `bin/` or `/usr/share/screenguard/`.

## Session Start Checklist (survive compaction)
1. Read `PLAN.md` + `TODO.md`.
2. Continue the topmost pending `TODO.md` item.
3. Update `TODO.md` as items complete.

## Toolchain (if missing)
- Install Flutter SDK + Dart, plus clang, cmake, libgtk-3-dev, pkg-config, ninja, libsqlite3-dev.
- Install runtime: xdotool, xprop (x11-utils/xorg-xprop), xprintidle.
