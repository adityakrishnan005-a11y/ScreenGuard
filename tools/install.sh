#!/usr/bin/env bash
# ScreenGuard tarball installer.
# Run from the extracted release tarball directory:
#   tar -xzf screenguard-<version>-x86_64.tar.gz && cd <dir> && ./install.sh
#
# - Copies the bundle to a stable location (default: ~/.local/opt/screenguard)
# - Symlinks screenguard + screenguard-daemon into <prefix>/bin
# - Asks (first-run consent) whether the tracking daemon should run in the
#   background always; on "yes" installs a systemd user unit, falling back
#   to an XDG autostart entry when systemd --user is unavailable.
# - Idempotent: safe to re-run. Supports --uninstall to remove everything.
set -euo pipefail

PREFIX="${HOME}/.local"
ASSUME_YES=0
SKIP_DAEMON=0
UNINSTALL=0
SYSTEM=0

usage() {
  cat <<EOF
Usage: $0 [options]

Options:
  --prefix DIR     Install prefix (default: \$HOME/.local).
                   Binaries land in <prefix>/bin, bundle in <prefix>/opt/screenguard.
  --system         System-wide install (shortcut for --prefix /usr/local, needs root).
  --yes            Non-interactive: assume "yes" to the daemon autostart prompt.
  --no-daemon      Install files only, skip the daemon autostart prompt entirely.
  --uninstall      Remove everything this script installed, then exit.
  -h, --help       Show this help.
EOF
}

log() { echo "[screenguard-install] $*"; }
die() { echo "[screenguard-install] ERROR: $*" >&2; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    --prefix) PREFIX="${2:?--prefix needs a directory}"; shift 2 ;;
    --system) SYSTEM=1; PREFIX="/usr/local"; shift ;;
    --yes) ASSUME_YES=1; shift ;;
    --no-daemon) SKIP_DAEMON=1; shift ;;
    --uninstall) UNINSTALL=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown option: $1 (see --help)" ;;
  esac
done

if [ "$SYSTEM" -eq 1 ] && [ "$(id -u)" -ne 0 ]; then
  die "--system needs root (re-run with sudo)."
fi

APP_DIR="$PREFIX/opt/screenguard"
BIN_DIR="$PREFIX/bin"
DAEMON_BIN="$APP_DIR/screenguard-daemon"

if [ "$SYSTEM" -eq 1 ]; then
  UNIT_DIR="/etc/systemd/user"
  AUTOSTART_DIR="/etc/xdg/autostart"
else
  UNIT_DIR="${HOME}/.config/systemd/user"
  AUTOSTART_DIR="${HOME}/.config/autostart"
fi
UNIT_FILE="$UNIT_DIR/screenguard.service"
AUTOSTART_FILE="$AUTOSTART_DIR/screenguard-daemon.desktop"

do_uninstall() {
  log "uninstalling ScreenGuard..."
  if command -v systemctl >/dev/null 2>&1; then
    if [ "$SYSTEM" -eq 1 ]; then
      systemctl --global disable screenguard.service 2>/dev/null || true
    else
      systemctl --user disable --now screenguard.service 2>/dev/null || true
    fi
  fi
  pkill -f "$DAEMON_BIN" 2>/dev/null || true
  rm -f "$UNIT_FILE" "$AUTOSTART_FILE" "$BIN_DIR/screenguard" "$BIN_DIR/screenguard-daemon"
  rm -rf "$APP_DIR"
  if command -v systemctl >/dev/null 2>&1 && [ "$SYSTEM" -eq 0 ]; then
    systemctl --user daemon-reload 2>/dev/null || true
  fi
  log "uninstalled. (Your tracking database at ~/.local/share/screenguard/ was left untouched.)"
}

if [ "$UNINSTALL" -eq 1 ]; then
  do_uninstall
  exit 0
fi

# --- 1. Locate the bundle (script must run from the extracted tarball) ---
SRC_DIR="$(cd "$(dirname "$0")" && pwd)"
for f in screenguard screenguard-daemon; do
  [ -x "$SRC_DIR/$f" ] || die "'$f' not found next to $0 — run this script from the extracted tarball directory."
done

# --- 2. Install files ---
log "installing bundle to $APP_DIR ..."
mkdir -p "$APP_DIR" "$BIN_DIR"
cp -a "$SRC_DIR/screenguard" "$SRC_DIR/screenguard-daemon" "$APP_DIR/"
[ -d "$SRC_DIR/data" ] && cp -a "$SRC_DIR/data" "$APP_DIR/"
[ -d "$SRC_DIR/lib" ] && cp -a "$SRC_DIR/lib" "$APP_DIR/"
chmod +x "$APP_DIR/screenguard" "$APP_DIR/screenguard-daemon"
ln -sf "$APP_DIR/screenguard" "$BIN_DIR/screenguard"
ln -sf "$APP_DIR/screenguard-daemon" "$BIN_DIR/screenguard-daemon"
log "binaries linked: $BIN_DIR/screenguard, $BIN_DIR/screenguard-daemon"
case ":$PATH:" in
  *":$BIN_DIR:"*) ;;
  *) log "NOTE: $BIN_DIR is not on your PATH. Add this to ~/.bashrc:  export PATH=\"\$PATH:$BIN_DIR\"" ;;
esac

# --- 3. First-run consent: background daemon, always? ---
if [ "$SKIP_DAEMON" -eq 1 ]; then
  log "skipping daemon autostart (--no-daemon). Start tracking manually with:  $DAEMON_BIN &"
  exit 0
fi

ANSWER=""
if [ "$ASSUME_YES" -eq 1 ]; then
  ANSWER="y"
else
  echo ""
  echo "Run the ScreenGuard tracking daemon in the background, always"
  echo "(starts on login, restarts on failure)?  [Y/n]"
  read -r ANSWER </dev/tty || ANSWER="y"
fi

case "$ANSWER" in
  [Nn]|[Nn][Oo])
    log "daemon autostart declined. Start tracking manually with:  $DAEMON_BIN &"
    exit 0
    ;;
esac

# --- 4. Install autostart: systemd user unit, XDG autostart as fallback ---
HAVE_SYSTEMD_USER=0
if command -v systemctl >/dev/null 2>&1; then
  if [ "$SYSTEM" -eq 1 ] || systemctl --user show-environment >/dev/null 2>&1; then
    HAVE_SYSTEMD_USER=1
  fi
fi

if [ "$HAVE_SYSTEMD_USER" -eq 1 ]; then
  mkdir -p "$UNIT_DIR"
  cat > "$UNIT_FILE" <<EOF
[Unit]
Description=ScreenGuard Tracker Daemon
After=default.target

[Service]
Type=simple
ExecStart=$DAEMON_BIN
Restart=always
RestartSec=3

[Install]
WantedBy=default.target graphical-session.target
EOF
  if [ "$SYSTEM" -eq 1 ]; then
    systemctl daemon-reload 2>/dev/null || true
    systemctl --global enable screenguard.service 2>/dev/null \
      && log "enabled screenguard.service globally (starts on every user login)" \
      || log "WARNING: could not enable globally; start manually with:  $DAEMON_BIN &"
  else
    systemctl --user daemon-reload 2>/dev/null || true
    systemctl --user enable --now screenguard.service 2>/dev/null \
      && log "daemon installed and started (systemd user service, starts on login)" \
      || log "WARNING: systemctl --user failed; falling back to XDG autostart"
  fi
fi

# XDG autostart fallback: used when systemd --user is unavailable/failed,
# and always installed user-wide so non-systemd desktops (and the
# Cinnamon/XFCE/MATE case) start the daemon too.
UNIT_ACTIVE=0
if [ "$HAVE_SYSTEMD_USER" -eq 1 ] && [ "$SYSTEM" -eq 0 ]; then
  systemctl --user is-active --quiet screenguard.service 2>/dev/null && UNIT_ACTIVE=1 || true
fi
if [ "$UNIT_ACTIVE" -eq 0 ]; then
  mkdir -p "$AUTOSTART_DIR"
  cat > "$AUTOSTART_FILE" <<EOF
[Desktop Entry]
Type=Application
Name=ScreenGuard Daemon
Comment=ScreenGuard background screen time tracker
Exec=$DAEMON_BIN
Icon=screenguard
Terminal=false
Hidden=false
NoDisplay=true
X-GNOME-Autostart-enabled=true
EOF
  if [ "$UNIT_ACTIVE" -eq 0 ] && [ "$HAVE_SYSTEMD_USER" -eq 0 ]; then
    log "no systemd user session: installed XDG autostart entry ($AUTOSTART_FILE)"
  else
    log "installed belt-and-braces XDG autostart entry ($AUTOSTART_FILE)"
  fi
fi

# --- 5. Verify ---
if pgrep -f "$DAEMON_BIN" >/dev/null 2>&1; then
  log "verified: screenguard-daemon is running (pid $(pgrep -f "$DAEMON_BIN" | head -n 1))."
else
  log "starting daemon now..."
  "$DAEMON_BIN" >/dev/null 2>&1 &
  sleep 1
  if pgrep -f "$DAEMON_BIN" >/dev/null 2>&1; then
    log "verified: screenguard-daemon is running."
  else
    log "WARNING: could not confirm the daemon is running. Try:  $DAEMON_BIN &"
  fi
fi

log "done. Launch the GUI with 'screenguard' (or $APP_DIR/screenguard)."
