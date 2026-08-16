# ScreenGuard — Setup & Build Guide

## 1. Install the Flutter SDK
Download the stable Flutter SDK and add `flutter/bin` to your PATH:
```
git clone https://github.com/flutter/flutter.git -b stable ~/flutter
export PATH="$HOME/flutter/bin:$PATH"
flutter doctor
```
Required for Linux desktop builds: clang, cmake, ninja, pkg-config, GTK 3 dev, libsqlite3.

### Per-distro build deps
- **Ubuntu/Debian:** `sudo apt install clang cmake ninja-build pkg-config libgtk-3-dev libsqlite3-dev`
- **Arch:** `sudo pacman -S clang cmake ninja pkgconf gtk3 sqlite`
- **Fedora:** `sudo dnf install clang cmake ninja-build pkgconf-pkg-config gtk3-devel sqlite-devel`

### Runtime deps — X11 backend (used automatically on X11 sessions)
- **Ubuntu/Debian:** `sudo apt install xdotool x11-utils xprintidle`
- **Arch:** `sudo pacman -S xdotool xorg-xprop xprintidle`  (xprintidle is in AUR)
- **Fedora:** X11 is only a fallback (GNOME runs on Wayland by default). `xorg-x11-utils`
  (provides `xprop`) installs via `dnf`; `xprintidle` is **not** packaged for Fedora, so
  on X11 idle detection falls back to 0. `xdotool` is optional.

### Runtime deps — GNOME Wayland backend (used automatically on Wayland sessions)
Window detection uses AT-SPI; idle detection uses the Mutter IdleMonitor D-Bus API.
No GNOME Shell extension is required.
- **Ubuntu/Debian:** `sudo apt install python3 python3-pyatspi`
- **Arch:** `sudo pacman -S python python-atspi`
- **Fedora:** `sudo dnf install python3 python3-pyatspi`

The helper `bin/active_window_helper.py` must be reachable by the daemon (see "Install & autostart").

Enable Linux desktop: `flutter config --enable-linux-desktop`.

## 2. Build
```
cd screenguard
flutter pub get
flutter build linux --release
dart compile exe bin/daemon.dart -o build/linux/x64/release/bundle/screenguard-daemon
```

## 2.5 Fedora: Flatpak accessibility (required for app tracking)
Fedora ships most user apps as **Flatpaks**, and Flatpak apps are sandboxed off the
AT-SPI accessibility bus by default. ScreenGuard relies on AT-SPI to read the focused
window, so without this fix every Flatpak shows up as `unknown` (only the native
ScreenGuard bundle is visible). This is Fedora-specific, not a ScreenGuard bug.

The fix grants Flatpaks access to the AT-SPI bus and turns on `toolkit-accessibility`
system-wide. It is applied **automatically by the package postinstall**
(`tools/enable_fedora_a11y.sh`), so a normal `dnf install` / `apt install` is enough.
To apply it manually (or re-apply after a Flatpak oddity):
```
sudo /usr/share/screenguard/enable_fedora_a11y.sh
```
What it does (idempotent, safe to re-run):
- `flatpak override --system --talk-name=org.a11y.Bus` (+ `org.a11y.atspi.Registry`,
  `org.a11y.atspi`) — the "authenticator" rule that un-sandboxes AT-SPI for all current
  and future Flatpaks.
- `flatpak override --user ...` for the installing user.
- Writes `/etc/dconf/db/local.d/00-screenguard` (`toolkit-accessibility=true`) and runs
  `dconf update` — system-wide, for all users.

Already-running Flatpaks pick up AT-SPI on their next focus / relaunch. App names for
Flatpak apps are resolved from their `.desktop` files in the Flatpak exports dirs
(`/var/lib/flatpak/exports/share/applications`,
`~/.local/share/flatpak/exports/share/applications`), which `app_resolver.dart` now
scans.

## 3. Run (dev)
Terminal 1 — daemon:
```
dart run bin/daemon.dart
```
Terminal 2 — GUI:
```
flutter run -d linux
```
The daemon writes to `~/.local/share/screenguard/usage.db`; the GUI reads it.

## 4. Install & autostart (systemd --user)
The Flutter GUI is a *bundle* (executable + `lib/` + `data/`), so deploy the whole
bundle to `/opt/screenguard` and symlink the binary; the daemon is a standalone executable.
```
# GUI bundle + symlink
sudo mkdir -p /opt/screenguard
sudo cp -a build/linux/x64/release/bundle/. /opt/screenguard/
sudo ln -sf /opt/screenguard/screenguard /usr/bin/screenguard
# Daemon (standalone AOT executable)
sudo install -Dm755 build/linux/x64/release/bundle/screenguard-daemon /usr/bin/screenguard-daemon
# AT-SPI helper (required on GNOME Wayland)
sudo install -Dm755 bin/active_window_helper.py /usr/share/screenguard/active_window_helper.py
# systemd user unit + desktop entry
sudo install -Dm644 linux/screenguard.service /usr/lib/systemd/user/screenguard.service
sudo install -Dm644 linux/screenguard.desktop /usr/share/applications/screenguard.desktop
systemctl --user daemon-reload
systemctl --user enable --now screenguard.service
```

## 5. Packaging
- **.deb / .rpm:** `nfpm package -f packaging/nfpm.deb.yaml -p deb` and `-f packaging/nfpm.rpm.yaml -p rpm`.
  Both configs ship `bin/active_window_helper.py` → `/usr/share/screenguard/`, the GUI
  bundle → `/opt/screenguard` (+ `/usr/bin/screenguard` symlink), the standalone daemon
  → `/usr/bin/screenguard-daemon`, and `tools/enable_fedora_a11y.sh` →
  `/usr/share/screenguard/`. The package `postinstall` runs that script, so installing
  the package enables Flatpak tracking automatically (see §2.5). After a Flutter rebuild,
  **recompile the daemon before packaging** (see §2), because `flutter build linux`
  wipes the bundle (including the previously compiled `screenguard-daemon`).
- **AUR:** place `PKGBUILD` in an AUR repo; `makepkg -si`. Add `python-atspi` to `depends`
  and apply the equivalent AT-SPI grant (e.g. run `enable_fedora_a11y.sh` or grant
  `org.a11y.Bus` to Flatpaks).

## 6. How backend selection works
`Tracker._selectBackend()` auto-detects the session:
- If `WAYLAND_DISPLAY` (or `XDG_SESSION_TYPE=wayland`) is set → `GnomeWaylandBackend`.
- Otherwise → `X11Backend` (xprop/xdotool/xprintidle).

The daemon resolves `active_window_helper.py` in this order:
`$SCREENGUARD_HELPER` env → next to the running executable → `../bin/` next to the
executable → `bin/` in the current directory → `/usr/share/screenguard/` →
`/usr/lib/screenguard/`. When launched from the project root (dev) it finds
`bin/active_window_helper.py`; when installed it finds `/usr/share/screenguard/`.

## 7. Notes
- GNOME on Wayland is supported via AT-SPI + Mutter IdleMonitor (no extension needed).
  Other Wayland compositors (KDE, etc.) are not yet supported; the X11 fallback only
  works under X11 / XWayland.
- Flatpak apps on Fedora are sandboxed off AT-SPI by default and would appear as
  `unknown`. The package postinstall (`enable_fedora_a11y.sh`) grants them AT-SPI access
  system-wide; re-run `sudo /usr/share/screenguard/enable_fedora_a11y.sh` if needed.
- `toolkit-accessibility` is enabled system-wide by that script (via dconf). It currently
  also works when `false`, but a future GTK change may require it, so leaving it on is safest.
- Idle threshold defaults to 5 min (`idleThresholdMs` in `Tracker`).
- App names/icons come from installed `.desktop` files (`StartupWMClass` -> `Name`/`Icon`). Electron exceptions (VS Code, Slack, etc.) are handled by a small built-in const map in `app_resolver.dart`. A proper in-app alias/rename UI is deferred.
