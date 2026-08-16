# ScreenGuard — Screen Time Tracker for Linux (Final Plan)

> Source of truth. Re-read this file at the start of every session to survive context compaction.

## 0. Locked Decisions
| Topic | Decision |
|---|---|
| Build vs fork | Build from scratch |
| UI framework | Flutter (Linux desktop) |
| Use cases | All (personal wellbeing + parental + productivity) — MVP scope limited |
| MVP scope | Core tracking + dashboard only (no focus mode / parental yet) |
| Tracking model | Always-on daemon via `systemd --user`, starts at login |
| Display target (v1) | X11 **and GNOME Wayland** — `WindowBackend` interface with `X11Backend` + `GnomeWaylandBackend` |
| Wayland | GNOME implemented via AT-SPI + Mutter IdleMonitor (no extension). Other compositors (KDE/Sway) still TODO. |
| Packaging | Native: `.deb` (Ubuntu/Debian), AUR (Arch), `.rpm` (Fedora) |
| App name/icon | `.desktop` lookup (`StartupWMClass`->`Name`+`Icon`) + tiny override JSON + fallbacks |
| Android DW | Not portable (needs Android `UsageStatsManager`); we only mimic the UI/UX |

## 1. Architecture
```
Flutter GUI (read)  <-->  SQLite (WAL)  <--  screenguard-daemon (write)
                                         (systemd --user, 3s poll)
daemon -> auto-detect session:
            WAYLAND_DISPLAY set  -> GnomeWaylandBackend (AT-SPI helper + Mutter IdleMonitor)
            else                 -> X11Backend (xdotool/xprop/xprintidle)
```

## 2. Window Detection
### X11 backend (`X11Backend`)
| Need | Command |
|---|---|
| Active window ID | `xprop -root _NET_ACTIVE_WINDOW` |
| App class | `xprop -id <wid> WM_CLASS` |
| Title | `xprop -id <wid> _NET_WM_NAME` |
| PID | `xprop -id <wid> _NET_WM_PID` |
| Idle (ms) | `xprintidle` |

### GNOME Wayland backend (`GnomeWaylandBackend`)
No GNOME Shell extension required.
| Need | Method |
|---|---|
| Active window app/class | `bin/active_window_helper.py` (Python + `pyatspi`): AT-SPI `getDesktop(0)`, pick last focused `frame`, return `WM_CLASS`/`gtk-application-id`/`WM_NAME` as JSON |
| Idle (ms) | D-Bus `org.gnome.Mutter.IdleMonitor.GetIdletime` via `gdbus` |

The helper is spawned per poll (3s) with a 5s timeout; on any failure the tick is skipped and retried.

Interface `WindowBackend { getActiveWindow(); getIdleMs(); }` -> `X11Backend` (X11) and `GnomeWaylandBackend` (GNOME Wayland). `KdeWaylandBackend`/`WlrBackend` still TODO.

## 3. Database (SQLite, WAL)
```sql
CREATE TABLE sessions (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  app TEXT NOT NULL, app_name TEXT, title TEXT, pid INTEGER,
  started_at INTEGER NOT NULL, ended_at INTEGER,
  duration_ms INTEGER, idle INTEGER DEFAULT 0
);
CREATE INDEX idx_sessions_started ON sessions(started_at);
CREATE INDEX idx_sessions_app ON sessions(app);
CREATE TABLE settings (key TEXT PRIMARY KEY, value TEXT);
```
Open with `PRAGMA journal_mode=WAL; PRAGMA busy_timeout=5000;` (concurrent daemon-write / GUI-read).

Dashboard SQL:
```sql
-- Today total (active)
SELECT COALESCE(SUM(duration_ms),0) FROM sessions WHERE idle=0
 AND started_at >= strftime('%s','now','start of day')*1000;
-- Per-app today top 10
SELECT app, app_name, SUM(duration_ms) t FROM sessions WHERE idle=0
 AND started_at >= strftime('%s','now','start of day')*1000
 GROUP BY app ORDER BY t DESC LIMIT 10;
-- Yesterday total
SELECT COALESCE(SUM(duration_ms),0) FROM sessions WHERE idle=0
 AND started_at BETWEEN strftime('%s','now','start of day','-1 day')*1000
                     AND strftime('%s','now','start of day')*1000;
-- Last 7 days
SELECT date(started_at/1000,'unixepoch') d, SUM(duration_ms) t FROM sessions
 WHERE idle=0 AND started_at >= strftime('%s','now','-6 day','start of day')*1000
 GROUP BY d ORDER BY d;
```

## 4. Daemon Design (edge-case aware)
- Poll every 3s; keep in-memory `currentApp`, `currentIdle`, `currentStart`.
- Transitions: app changed -> close old / open new. Idle crossed threshold -> close old / open new with `idle` flipped. No change -> extend in memory only.
- SIGTERM: close open session before exit.
- Sleep/resume: if gap > threshold, close previous at sleep time, start fresh.
- Default idle threshold 5 min (override in `settings` later).

## 5. App Name/Icon Mapping (low-maintenance)
 1. `WM_CLASS` -> find `.desktop` whose `StartupWMClass` matches -> read `Name=` + `Icon=`.
 2. Fallback: match desktop filename (`firefox.desktop`).
 3. Fallback: small built-in const map in `app_resolver.dart` for known Electron/runtime exceptions (`code`->VS Code, `slack`->Slack, `discord`, `steam`, `telegram`, `spotify`; wine/proton games). No external override file — it's clunky to hand-edit.
 4. Fallback: capitalize raw class.
Desktop files exist on all target distros (freedesktop.org spec). An in-app alias/rename UI (ActivityWatch-style) is deferred.

## 6. Flutter UI (MVP)
- Dashboard: Today total + goal progress bar; per-app list w/ duration + proportional bar; 7-day bar chart (fl_chart); "up/down % vs yesterday" badge.
- App detail: tap app -> its daily history.
- Widgets: `usage_bar`, `app_list`, `day_chart`, `delta_badge`.

## 7. Tech Stack
```
flutter (Linux desktop)
sqlite3 ^2.4.0, fl_chart ^0.66.0, provider ^6.1.0
```
Daemon = separate Dart entry `bin/daemon.dart` (systemd-launched, not the Flutter process).
Subprocess calls use `dart:io` `Process.run` directly (no `process_run` / `path_provider` / `intl` deps).

## 8. Build & Runtime Deps (per distro)
| | Build | Runtime (X11) | Runtime (GNOME Wayland) |
|---|---|---|---|
| Ubuntu/Debian | clang, cmake, libgtk-3-dev, pkg-config, ninja, libsqlite3-dev | `xdotool`, `x11-utils`(xprop), `xprintidle` | `python3`, `python3-pyatspi2` |
| Arch | same | `xdotool`, `xorg-xprop`, `xprintidle`(AUR) | `python`, `python-atspi` |
| Fedora | same | `xdotool`, `xorg-x11-utils`, `xprintidle` | `python3`, `python3-pyatspi` |

## 9. Packaging
- `.deb` + `.rpm` via `nfpm` (one yaml). AUR via `PKGBUILD` wrapping prebuilt binary.
- Each package installs: `/usr/bin/screenguard`, `/usr/bin/screenguard-daemon`,
  `/usr/share/screenguard/active_window_helper.py` (the AT-SPI helper),
  `/usr/lib/systemd/user/screenguard.service`, `/usr/share/applications/screenguard.desktop`.
- Declare runtime deps above (`xdotool`/`xprop`/`xprintidle` for X11; `python3-pyatspi` for Wayland).

systemd unit:
```ini
[Unit]
Description=ScreenGuard Tracker
After=graphical-session.target
PartOf=graphical-session.target
[Service]
ExecStart=/usr/bin/screenguard-daemon
Restart=on-failure
RestartSec=5
[Install]
WantedBy=graphical-session.target
```

## 10. Project Structure
```
screenguard/
├── bin/daemon.dart
├── bin/active_window_helper.py
├── lib/
│   ├── main.dart
│   ├── models/session.dart
│   ├── services/{db.dart, tracker.dart, idle.dart,
│   │             backend/window_backend.dart, backend/x11_backend.dart,
│   │             backend/gnome_wayland_backend.dart}
│   ├── screens/{dashboard.dart, app_detail.dart}
│   ├── widgets/{usage_bar.dart, app_list.dart, day_chart.dart, delta_badge.dart}
│   └── utils/format.dart
├── linux/{screenguard.service, screenguard.desktop}
├── packaging/{nfpm.yaml, PKGBUILD}
└── pubspec.yaml
```

## 11. Execution Phases (ordered)
1. Scaffold Flutter Linux project + add deps.
2. Write PLAN.md, AGENTS.md, TODO.md (persist plan — anti-compaction).
3. DB layer (db.dart) + aggregate queries.
4. WindowBackend interface + X11Backend (xdotool/xprop/xprintidle).
5. Daemon loop + systemd unit + autostart.
6. App name/icon mapping (.desktop lookup + overrides).
7. Dashboard UI + app detail.
 8. Packaging: nfpm deb+rpm, AUR PKGBUILD.
 9. ~~Wayland (GNOME) backend~~ DONE — AT-SPI helper + Mutter IdleMonitor.
 10. (Deferred) KDE/Sway Wayland backends, focus mode, parental controls, reports expansion.

## 12. Anti-Compaction Strategy
- PLAN.md is the source of truth; re-read at session start.
- TODO.md is the live task list.
- AGENTS.md holds conventions/decisions so they aren't re-litigated.
- Files persist; chat context may compress — the disk is the memory.

## 13. Risks / Open Items
- `xprintidle` packaging on Fedora/Arch may need extra repo — note in packaging docs.
- GNOME Wayland done (AT-SPI + Mutter). KDE/Sway Wayland backends still TODO; X11 fallback only works under X11/XWayland.
- AT-SPI currently works even with `toolkit-accessibility=false`; a future GTK change may require enabling it.
- Focus mode / parental controls deferred per MVP scope.
