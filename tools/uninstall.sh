#!/usr/bin/env bash
# ScreenGuard uninstaller — standalone, no tarball needed.
# Removes everything installed by install.sh or build-and-install.sh.
#
# Usage:
#   ./tools/uninstall.sh             # removes user-level install (~/.local)
#   ./tools/uninstall.sh --system    # removes system-wide install (/usr/local)
#   ./tools/uninstall.sh --prefix DIR
#
# Your tracking database (~/.local/share/screenguard/) is left untouched.
set -euo pipefail

PREFIX="${HOME}/.local"
SYSTEM=0

log() { echo "[screenguard-uninstall] $*"; }
die() { echo "[screenguard-uninstall] ERROR: $*" >&2; exit 1; }

usage() {
  cat <<EOF
Usage: $0 [options]

Options:
  --prefix DIR   Prefix used at install time (default: \$HOME/.local)
  --system       Remove a system-wide install (shortcut for --prefix /usr/local, needs root)
  -h, --help     Show this help
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --prefix) PREFIX="${2:?--prefix needs a directory}"; shift 2 ;;
    --system) SYSTEM=1; PREFIX="/usr/local"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown option: $1 (see --help)" ;;
  esac
done

if [ "$SYSTEM" -eq 1 ] && [ "$(id -u)" -ne 0 ]; then
  die "--system needs root. Re-run with sudo."
fi

APP_DIR="$PREFIX/opt/screenguard"
BIN_DIR="$PREFIX/bin"
DAEMON_BIN="$APP_DIR/screenguard-daemon"
DAEMON_LINK="$BIN_DIR/screenguard-daemon"

if [ "$SYSTEM" -eq 1 ]; then
  UNIT_DIR="/etc/systemd/user"
  AUTOSTART_DIR="/etc/xdg/autostart"
else
  UNIT_DIR="${HOME}/.config/systemd/user"
  AUTOSTART_DIR="${HOME}/.config/autostart"
fi
UNIT_FILE="$UNIT_DIR/screenguard.service"
AUTOSTART_FILE="$AUTOSTART_DIR/screenguard-daemon.desktop"

# Check something is actually installed
if [ ! -d "$APP_DIR" ] && [ ! -L "$BIN_DIR/screenguard" ] && [ ! -f "$UNIT_FILE" ]; then
  log "nothing found to uninstall under prefix '$PREFIX'."
  log "If you used a custom prefix, pass it with --prefix DIR."
  exit 0
fi

# ---------------------------------------------------------------------------
# 1. Stop & disable the systemd service
# ---------------------------------------------------------------------------
if command -v systemctl >/dev/null 2>&1; then
  if [ "$SYSTEM" -eq 1 ]; then
    systemctl --global disable screenguard.service 2>/dev/null && \
      log "disabled screenguard.service globally" || true
    systemctl stop screenguard.service 2>/dev/null || true
  else
    systemctl --user disable --now screenguard.service 2>/dev/null && \
      log "stopped and disabled screenguard.service (user)" || true
  fi
fi

# ---------------------------------------------------------------------------
# 2. Kill any running daemon process
# ---------------------------------------------------------------------------
_killed=0
for d in /proc/[0-9]*; do
  pid="${d#/proc/}"
  case "$pid" in *[!0-9]*) continue ;; esac
  [ "$pid" = "$$" ] && continue
  exe="$(readlink "$d/exe" 2>/dev/null || true)"
  target="$(readlink -f "$DAEMON_BIN" 2>/dev/null || echo "$DAEMON_BIN")"
  if [ -n "$exe" ] && [ "$exe" = "$target" ]; then
    kill "$pid" 2>/dev/null || kill -9 "$pid" 2>/dev/null || true
    _killed=1
    continue
  fi
  while IFS= read -r arg; do
    if [ "$arg" = "$DAEMON_BIN" ] || [ "$arg" = "$DAEMON_LINK" ]; then
      kill "$pid" 2>/dev/null || kill -9 "$pid" 2>/dev/null || true
      _killed=1
      break
    fi
  done < <(tr '\0' '\n' < "$d/cmdline" 2>/dev/null)
done
[ "$_killed" -eq 1 ] && log "killed running daemon process"

# ---------------------------------------------------------------------------
# 3. Remove files
# ---------------------------------------------------------------------------
removed=0

if [ -f "$UNIT_FILE" ]; then
  rm -f "$UNIT_FILE"
  log "removed $UNIT_FILE"
  if command -v systemctl >/dev/null 2>&1; then
    if [ "$SYSTEM" -eq 1 ]; then
      systemctl daemon-reload 2>/dev/null || true
    else
      systemctl --user daemon-reload 2>/dev/null || true
    fi
  fi
  removed=1
fi

if [ -f "$AUTOSTART_FILE" ]; then
  rm -f "$AUTOSTART_FILE"
  log "removed $AUTOSTART_FILE"
  removed=1
fi

for link in "$BIN_DIR/screenguard" "$BIN_DIR/screenguard-daemon"; do
  if [ -L "$link" ] || [ -f "$link" ]; then
    rm -f "$link"
    log "removed $link"
    removed=1
  fi
done

if [ -d "$APP_DIR" ]; then
  rm -rf "$APP_DIR"
  log "removed $APP_DIR"
  removed=1
fi

# ---------------------------------------------------------------------------
# 4. Done
# ---------------------------------------------------------------------------
if [ "$removed" -eq 1 ]; then
  log "ScreenGuard has been uninstalled."
else
  log "nothing removed (already clean under prefix '$PREFIX')."
fi
log "Your tracking database at ~/.local/share/screenguard/ was left untouched."
