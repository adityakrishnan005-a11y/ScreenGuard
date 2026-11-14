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
DIGIWELLD_UNIT_FILE="$UNIT_DIR/digiwelld.service"
LEGACY_BROKER_UNIT_FILE="$UNIT_DIR/screenguard-broker.service"
AUTOSTART_FILE="$AUTOSTART_DIR/screenguard-daemon.desktop"

# Check something is actually installed
if [ ! -d "$APP_DIR" ] && [ ! -L "$BIN_DIR/screenguard" ] \
   && [ ! -f "$UNIT_FILE" ] && [ ! -f "$DIGIWELLD_UNIT_FILE" ] \
   && [ ! -f "$LEGACY_BROKER_UNIT_FILE" ]; then
  log "nothing found to uninstall under prefix '$PREFIX'."
  log "If you used a custom prefix, pass it with --prefix DIR."
  exit 0
fi

# ---------------------------------------------------------------------------
# 1. Stop & disable the systemd service
# ---------------------------------------------------------------------------
if command -v systemctl >/dev/null 2>&1; then
  if [ "$SYSTEM" -eq 1 ]; then
    systemctl --global disable screenguard.service digiwelld.service screenguard-broker.service 2>/dev/null && \
      log "disabled ScreenGuard user units globally" || true
    systemctl stop digiwelld.service screenguard-broker.service screenguard.service 2>/dev/null || true
  else
    systemctl --user disable --now digiwelld.service 2>/dev/null && \
      log "stopped and disabled digiwelld.service (user)" || true
    systemctl --user disable --now screenguard-broker.service 2>/dev/null || true
    systemctl --user disable --now screenguard.service 2>/dev/null && \
      log "stopped and disabled screenguard.service (user)" || true
  fi
fi

# ---------------------------------------------------------------------------
# 2. Kill any running supervisor, daemon or session worker
# ---------------------------------------------------------------------------
# Supervisors first: a live digiwelld would respawn the daemon we just killed.
# Match by resolved executable basename, never pgrep -f, and stay inside this
# session's XDG_RUNTIME_DIR so another login's install is untouched.
_kill_session_procs() { # $1 = signal, rest = basenames
  local sig="$1"; shift
  local d pid exe base want rt
  [ -n "${XDG_RUNTIME_DIR:-}" ] || return 0
  for d in /proc/[0-9]*; do
    pid="${d#/proc/}"
    case "$pid" in *[!0-9]*) continue ;; esac
    [ "$pid" = "$$" ] && continue
    exe="$(readlink "$d/exe" 2>/dev/null || true)"
    [ -n "$exe" ] || continue
    base="${exe##*/}"
    for want in "$@"; do
      if [ "$base" = "$want" ]; then
        rt="$(cat "$d/environ" 2>/dev/null | tr '\0' '\n' \
          | sed -n 's/^XDG_RUNTIME_DIR=//p' | head -n 1)"
        if [ -z "$rt" ] || [ "$rt" = "$XDG_RUNTIME_DIR" ]; then
          kill "-$sig" "$pid" 2>/dev/null || true
          _killed=1
        fi
        break
      fi
    done
  done
  return 0
}

_killed=0
_kill_session_procs TERM digiwelld screenguard-broker screenguard-watchdog
sleep 1
_kill_session_procs KILL digiwelld digiwelld-session digiwelld-usage digiwelld-policy digiwelld-store screenguard-broker screenguard-watchdog
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
[ "$_killed" -eq 1 ] && log "killed running ScreenGuard processes"

# ---------------------------------------------------------------------------
# 3. Remove files
# ---------------------------------------------------------------------------
removed=0

_unit_removed=0
for _uf in "$UNIT_FILE" "$DIGIWELLD_UNIT_FILE" "$LEGACY_BROKER_UNIT_FILE"; do
  if [ -f "$_uf" ]; then
    rm -f "$_uf"
    log "removed $_uf"
    _unit_removed=1
    removed=1
  fi
done
if [ "$_unit_removed" -eq 1 ] && command -v systemctl >/dev/null 2>&1; then
  if [ "$SYSTEM" -eq 1 ]; then
    systemctl daemon-reload 2>/dev/null || true
  else
    systemctl --user daemon-reload 2>/dev/null || true
  fi
fi

if [ -f "$AUTOSTART_FILE" ]; then
  rm -f "$AUTOSTART_FILE"
  log "removed $AUTOSTART_FILE"
  removed=1
fi

for link in "$BIN_DIR/screenguard" "$BIN_DIR/screenguard-daemon" \
            "$BIN_DIR/screenguard-watchdog" "$BIN_DIR/screenguard-broker" \
            "$BIN_DIR/digiwelld" "$BIN_DIR/digiwelld-session" \
            "$BIN_DIR/digiwelld-usage" "$BIN_DIR/digiwelld-policy" \
            "$BIN_DIR/digiwelld-store"; do
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
