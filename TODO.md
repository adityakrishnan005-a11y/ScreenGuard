# TODO.md — ScreenGuard (live task list)

## Done
- [x] Persist plan files (PLAN.md / AGENTS.md / TODO.md)
- [x] Scaffold project tree at /home/aditya/screenguard
- [x] pubspec.yaml + all lib/ source (models, db, backend, tracker, resolver, widgets, screens, main)
- [x] Daemon entry (bin/daemon.dart)
- [x] Linux integration (screenguard.service, .desktop)
- [x] Packaging configs (nfpm.deb.yaml, nfpm.rpm.yaml, PKGBUILD)
- [x] docs/SETUP.md
- [x] Install Flutter 3.47 / Dart 3.13 + clang + xdotool (sudo)
- [x] flutter analyze: No issues found
- [x] Build GUI: build/linux/x64/release/bundle/screenguard  OK
- [x] Compile daemon: build/linux/x64/release/bundle/screenguard-daemon  OK
- [x] Runtime validation: daemon polled 12s, wrote 1 session w/ correct duration (~12s) to ~/.local/share/screenguard/usage.db
- [x] GNOME Wayland backend: `bin/active_window_helper.py` (AT-SPI) + `GnomeWaylandBackend` (Mutter IdleMonitor)
- [x] Backend auto-detect in `Tracker._selectBackend()` (WAYLAND_DISPLAY/XDG_SESSION_TYPE -> Wayland, else X11)
- [x] Live Wayland validation: focused `gnome-calculator` detected, Mutter idle read (~140s), DB row app=gnome-calculator -> "Gnome-calculator"
- [x] flutter analyze: No issues found (after const fixes + Wayland backend)
- [x] Cleanup pass: AGENTS.md updated (Wayland + pyatspi + sqlite3); dropped dead `lib/services/idle.dart`; reconciled PLAN §7 deps with real pubspec.
- [x] Override strategy: dropped hand-edited `linux/mapping_overrides.json`; app names come from `.desktop` (OS label) + built-in const map for Electron exceptions (research: Android DW uses OS label, ActivityWatch uses in-app categories — both avoid clunky JSON).
- [x] Daemon robustness: subprocess calls now time-bounded (helper 5s kill-on-timeout, gdbus 3s, x11 3s); SIGTERM now exits cleanly (~1s) and closes the open session (was hanging before due to missing helper timeout).
- [x] Sleep/resume handling: tracker closes the open session at the last good tick when a >30s gap is detected, then starts fresh.
- [x] Automated tests added (14 passing): `test/app_resolver_test.dart`, `test/db_test.dart`, `test/tracker_test.dart` (transition logic + fake backend), `test/widget_test.dart` (dashboard smoke test). `flutter analyze` clean.
- [x] Fixed Debian/Ubuntu dep name `python3-pyatspi2` -> `python3-pyatspi` in SETUP.md + nfpm.deb.yaml.
- [x] Live re-validation on Wayland: gnome-calculator tracked (idle via Mutter ~370s), SIGTERM produced two properly-closed sessions (ended_at set).
- [x] Packaging built: `nfpm` installed via `go install`; `.rpm` (x86_64) + `.deb` (amd64) produced in `dist/`. Both ship full GUI bundle at `/opt/screenguard` + `/usr/bin/screenguard` symlink, standalone daemon at `/usr/bin/screenguard-daemon`, AT-SPI helper at `/usr/share/screenguard/`, systemd unit + desktop.
- [x] Real install + autostart: deployed to system paths (GUI bundle → `/opt/screenguard`, symlink, daemon, helper, service, desktop) and `systemctl --user enable --now screenguard.service`. Service runs, selects `GnomeWaylandBackend`, tracks sessions to `~/.local/share/screenguard/usage.db`. GUI launches successfully (fixed the "only /usr/bin/screenguard" bug — Flutter needs its sibling `lib/`+`data/`).
- [x] `_selectBackend` now also honors `XDG_SESSION_TYPE=wayland` (robust under systemd --user where WAYLAND_DISPLAY may be absent).
- [x] **Fedora Flatpak tracking fix (root cause: Flatpaks are sandboxed off the AT-SPI bus → reported as `unknown`).** New `tools/enable_fedora_a11y.sh` grants AT-SPI bus access to all Flatpaks (`flatpak override --system/user --talk-name=org.a11y.Bus` + `org.a11y.atspi.Registry`/`org.a11y.atspi`) and enables `toolkit-accessibility` system-wide via dconf (`/etc/dconf/db/local.d/00-screenguard` + `dconf update`). Verified: after the grant, `io.github.alainm23.planify` (a Flatpak) appears in the AT-SPI tree.
- [x] Wired the a11y script into `nfpm.{rpm,deb}.yaml` as a shipped file (`/usr/share/screenguard/enable_fedora_a11y.sh`) **and** as `postinstall`, so `dnf install`/`apt install` enables Flatpak tracking automatically (deep, system-level integration, per user direction — no sandbox gap).
- [x] `tracker.dart`: no longer opens a session for `unknown`/empty app (closes the open session instead) — stops `unknown` rows in the dashboard.
- [x] `db.dart`: dashboard aggregate queries now filter `app != 'unknown'` (covers any pre-existing rows too).
- [x] `app_resolver.dart`: now scans Flatpak export `.desktop` dirs (`/var/lib/flatpak/exports/share/applications`, `~/.local/share/flatpak/exports/share/applications`) so Flatpak apps resolve to friendly names (`com.spotify.Client`→`Spotify`, `org.signal.Signal`→`Signal`); added const overrides for the user's Flatpaks and a smarter reverse-domain humanize fallback.
- [x] Rebuilt GUI bundle + recompiled daemon (note: `flutter build linux` wipes the bundle, so daemon must be recompiled after), repackaged `.rpm`/`.deb`, reinstalled (postinstall ran), restarted `screenguard.service`. Service active on the new binary, selects `GnomeWaylandBackend`. `flutter test` 14/14 pass.
- [x] **GNOME Shell Extension D-Bus Backend implementation**: Added GNOME Shell Extension `screenguard@screenguard.app` (`extension/metadata.json`, `extension/extension.js`) exporting D-Bus service `org.gnome.Shell.Extensions.ScreenGuard.GetActiveWindow`. Updated `GnomeWaylandBackend` to query D-Bus first for 100% reliable tracking of Spotify, Flatpaks, and Electron apps, with AT-SPI fallback. Updated `active_window_helper.py` to support deep child roles. Repackaged `.rpm` and `.deb` in `dist/`. `flutter test` 14/14 pass, `flutter analyze` clean.
- [x] **Daily App Time Limits & Lockout Screen**: Added `app_limits` table to SQLite schema with CRUD methods. Implemented 90% warning notification and 100% window minimization + `--times-up` GUI trigger in `tracker.dart`. Created `TimesUpScreen` with *Add 15 Minutes*, *Edit Limit*, and *Back to Dashboard* options. Created `AppLimitDialog` and integrated into `AppDetailScreen`. Added `MinimizeActiveWindow` D-Bus method to GNOME Shell extension and `X11Backend`. `flutter test` 14/14 pass, `flutter analyze` clean. Rebuilt release bundle and `.rpm`/`.deb` packages.
- [x] **Focus Mode (Pomodoro Timer & Distraction Blocker)**: Created `FocusScreen` with animated circular timer widget (15m, 25m Pomodoro, 45m Deep Work, 60m), completed sessions counter, and Distracting Apps checklist. Added `active_focus_state`, `distracting_apps`, and `focus_sessions` tables to `db.dart`. Implemented automatic minimization & notification when switching to distracting apps in `tracker.dart`. Added `MainShell` navigation bar. `flutter test` 14/14 pass, `flutter analyze` clean. Rebuilt release bundle and `.rpm`/`.deb` packages.
- [x] **Week Slider & 14-Day Per-Day App History**: Added `getWeekData(weekOffset)`, `perAppForDate(dateStr)`, and `last30DaysTotalMs()` to `db.dart`. Built week-by-week bar chart slider with `<` / `>` navigation arrows. Added interactive bar selection in `DayChart` to inspect per-app usage for any day in history. Added **Past 30 Days** total and daily average hero card. `flutter test` 14/14 pass, `flutter analyze` clean. Rebuilt release bundle and `.rpm`/`.deb` packages.

## Known gaps (real-world, non-blocking)
- [ ] xprintidle not in Fedora repos → on X11 idle defaults to 0. Install via RPM Fusion for real X11 idle detection (Wayland uses Mutter, no xprintidle needed).
- [ ] `flutter build linux` wipes the bundle; recompile daemon AFTER gui build (SETUP documents this).
- [ ] KDE / Sway Wayland backends not implemented (GNOME Wayland + X11 only for v1).
- [ ] In-app alias/rename UI (ActivityWatch-style) deferred — currently names come from `.desktop` + const map.
- [ ] AUR `PKGBUILD` not built/validated on this Fedora box (deferred; uses `python-atspi` dep + helper).

## Deferred (post-MVP)
- [ ] KDE/Sway Wayland backends
- [ ] In-app alias/rename settings screen
- [ ] Focus mode (Pomodoro + app blocking)
- [ ] Break reminders (notifications)
- [ ] Parental controls
- [ ] Expanded reports (monthly, categories)
- [ ] Settings screen (idle threshold, daily goal)

## Session Start Checklist (survive compaction)
1. Read PLAN.md + TODO.md.
2. Continue topmost pending TODO item.
3. Keep PLAN.md as source of truth.
