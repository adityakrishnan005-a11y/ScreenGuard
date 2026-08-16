# Reddit Launch — ScreenGuard (Private Post Drafts)

**Username:** `TheTechAmbivert` (use same on HN)
**Repo:** https://github.com/adityakrishnan005-a11y/ScreenGuard

## Posting rules
- One sub every 2-3 days (don't blast all at once).
- Tailor each (drafts below are already different per sub).
- Engage in comments; follow 9-to-1.
- Never ask for upvotes.

---

## 1) r/opensource

**Title:** `I built ScreenGuard: an open-source (GPLv3) screen-time tracker and app-limit tool for Linux`

**Body:**
> Hey all — I built ScreenGuard because I wanted Android's Digital Wellbeing on my Linux desktop and nothing open-source did it well.
>
> What it does: always-on `systemd --user` daemon tracks per-app screen time; Flutter dashboard with daily/weekly breakdowns, app-share charts, and 30-day totals; daily app-limit lockouts and a Focus/Pomodoro mode.
>
> How it's built (all local, no telemetry/cloud): Flutter UI + a Dart daemon, SQLite on disk. On GNOME Wayland it ships a tiny Shell extension that exposes the focused window over D-Bus (avoids AT-SPI's Flatpak/Electron blind spots); X11 uses standard EWMH.
>
> Status (v0.1.0): GNOME Wayland is the mature path; X11 works but is newer/"community testing"; KDE Plasma + Hyprland/Sway backends on the roadmap. Packaged as .deb / .rpm / AUR.
>
> Repo + install: https://github.com/adityakrishnan005-a11y/ScreenGuard
> Contributors and feedback welcome — especially on X11 edge cases and more-distro packaging.

---

## 2) r/FlutterDev

**Title:** `Showcase: ScreenGuard — a full Flutter Linux desktop app (screen-time tracker) using a GNOME Shell extension for Wayland window tracking`

**Body:**
> Sharing ScreenGuard, a complete Flutter desktop app for Linux (screen-time tracking + app limits + focus mode).
>
> The interesting bit for Flutter devs is window/app tracking on Wayland. AT-SPI is unreliable there (misses Flatpaks/Electron, needs sandbox holes), so instead I ship a small GNOME Shell extension that hooks `global.display` focus-window and exposes the active window over D-Bus; the Dart daemon reads that. X11 falls back to EWMH `_NET_ACTIVE_WINDOW`.
>
> Packaging: build the Linux bundle, compile the daemon with `dart compile exe`, then ship .deb/.rpm (via nfpm) + an AUR bin.
>
> Would love feedback from others shipping Flutter on Linux — especially desktop packaging gotchas. Repo: https://github.com/adityakrishnan005-a11y/ScreenGuard

---

## 3) r/gnome

**Title:** `I wrote a GNOME Shell extension that exposes the focused window over D-Bus — used by my screen-time tracker ScreenGuard`

**Body:**
> I built a small GNOME Shell extension (GNOME 44+) for ScreenGuard, an open-source local-first screen-time tracker.
>
> The extension listens to `global.display` `notify::focus-window` and returns the focused app's id/title/pid via a D-Bus interface (`GetActiveWindow`). This replaces AT-SPI entirely — no Flatpak/Electron blind spots, no a11y sandbox grants. The tracker daemon just calls the D-Bus method.
>
> It needs to be enabled, and you log out/in for it to load (Wayland can't reload the shell live).
>
> Looking for testers on GNOME 44-50, and thoughts on whether a standardized "focused window" D-Bus interface would be broadly useful. Extension source + project: https://github.com/adityakrishnan005-a11y/ScreenGuard

---

## 4) r/Fedora

**Title:** `Packaged ScreenGuard (open-source screen-time tracker) as an rpm for Fedora — packaging feedback welcome`

**Body:**
> I'm on Fedora and built ScreenGuard — an open-source, local-first screen-time tracker / Digital Wellbeing for Linux (per-app time, dashboard, daily limits, focus mode).
>
> Install from the release:
> ```
> sudo dnf install ./dist/screenguard-0.1.0-1.x86_64.rpm
> systemctl --user enable --now screenguard.service
> ```
> On GNOME Wayland it uses a bundled Shell extension for accurate tracking (no AT-SPI); X11 works via EWMH. Everything stays local (SQLite, no telemetry).
>
> Would Fedora users mind testing the rpm and the GNOME extension and reporting any packaging/issues? Thanks! Repo/releases: https://github.com/adityakrishnan005-a11y/ScreenGuard

---

## 5) r/Ubuntu

**Title:** `Open-source screen-time tracker for Ubuntu/Debian — .deb available (ScreenGuard)`

**Body:**
> ScreenGuard is an open-source, local-first screen-time tracker + app-limit/focus tool for Linux. I packaged it as a .deb for Ubuntu/Debian.
>
> Install from the release:
> ```
> sudo apt install ./dist/screenguard_0.1.0_amd64.deb
> systemctl --user enable --now screenguard.service
> ```
> On GNOME Wayland it uses a bundled Shell extension for accurate tracking; X11 is supported too (newer). All data stays local (SQLite, no telemetry/cloud).
>
> Ubuntu GNOME users: would appreciate testing the .deb and the extension and any feedback. Thanks! Repo/releases: https://github.com/adityakrishnan005-a11y/ScreenGuard
