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
ORIG_ARGS=("$@")  # captured before arg parsing shifts them away

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

# Print PIDs of daemon processes belonging to THIS install. Matches on the
# resolved executable or on any argv element equal to one of the known
# launch paths — exact string equality only, never substring/regex, so
# unrelated commands that merely mention the path (our own shell, greps)
# can never match. Covers daemons launched via the install dir, via the
# bin symlink, via the systemd unit (same ExecStart path), and script
# wrappers (interpreter in argv[0], script path in later argv elements).
daemon_pids() { # $1 = DAEMON_BIN, $2 = bin-symlink path
  local want1="$1" want2="$2" target d pid exe arg
  target="$(readlink -f "$want1" 2>/dev/null || echo "$want1")"
  for d in /proc/[0-9]*; do
    pid="${d#/proc/}"
    case "$pid" in *[!0-9]*) continue ;; esac
    if [ "$pid" = "$$" ]; then continue; fi
    exe="$(readlink "$d/exe" 2>/dev/null || true)"
    if [ -n "$exe" ] && [ "$exe" = "$target" ]; then
      echo "$pid"
      continue
    fi
    # Catch stray daemons from OTHER installs (e.g. a distro package at
    # /usr/bin shadowing this prefix): same binary name, different path.
    # Without this, the stale daemon keeps the single-instance lock and the
    # freshly installed one silently exits while we report success.
    if [ -n "$exe" ] && [ "${exe##*/}" = "screenguard-daemon" ]; then
      echo "$pid"
      continue
    fi
    while IFS= read -r arg; do
      if [ "$arg" = "$want1" ] || [ "$arg" = "$want2" ]; then
        echo "$pid"
        break
      fi
    done < <(tr '\0' '\n' < "$d/cmdline" 2>/dev/null) 2>/dev/null
  done
  return 0
}

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

# --- 0. Escape the caller's blast radius. When the in-app updater launches
# us, we run inside the GUI's systemd scope. This very script's migration
# sweep (section 1c) terminates that GUI, and the desktop session then tears
# the whole app scope down (GNOME stops the unit; KillMode=control-group)
# killing us mid-install — observed as: old instances stopped, but files
# never copied and the updater silently aborted. Re-launch the real work in
# a fresh transient service of its own, unreachable from the app's teardown.
# The recursion barrier is the cgroup we are in (not an env var): only a
# run inside our own screenguard-install-*.service unit counts as detached.
case "$(cat /proc/self/cgroup 2>/dev/null)" in *screenguard-install-*) SG_INSTALL_DETACHED=1 ;; esac
RESULT_FILE=""
if [ "${SG_INSTALL_DETACHED:-0}" != "1" ] \
   && command -v systemd-run >/dev/null 2>&1 \
   && [ -n "${XDG_RUNTIME_DIR:-}" ] \
   && systemctl --user show-environment >/dev/null 2>&1; then
  # A transient service gets its own cgroup: when the desktop later tears
  # down the caller's app scope (or the updater closes the GUI), the
  # installation continues undisturbed. Output is relayed via a result
  # file because transient-service stdout goes to the journal, not to us.
  # (-E forwards the env into the unit — plain `VAR=x systemd-run` does not.)
  RESULT_FILE="${XDG_RUNTIME_DIR}/screenguard-install-result"
  rm -f "$RESULT_FILE"
  systemd-run --user --quiet --wait --collect \
    -E "SG_INSTALL_DETACHED=1" \
    -E "SG_INSTALL_RESULT=$RESULT_FILE" \
    --unit="screenguard-install-$$.service" bash "$0" "${ORIG_ARGS[@]}" >/dev/null 2>&1
  wrap_rc=$?
  if [ -f "$RESULT_FILE" ]; then
    cat "$RESULT_FILE"
    inner_rc="$(sed -n 's/^SG_INSTALL_EXITCODE=//p' "$RESULT_FILE" | tail -n 1)"
    case "$inner_rc" in '' | *[!0-9]*) inner_rc="$wrap_rc" ;; esac
    rm -f "$RESULT_FILE"
    exit "$inner_rc"
  fi
  # Scope mode unavailable (old systemd etc.) — fall through and run inline.
  rm -f "$RESULT_FILE"
fi

if [ "${SG_INSTALL_DETACHED:-0}" = "1" ]; then
  # Running detached: route all output to the result file and record our
  # exit code for the wrapper to relay.
  RESULT_FILE="${SG_INSTALL_RESULT:-${XDG_RUNTIME_DIR:-/tmp}/screenguard-install-result}"
  exec >"$RESULT_FILE" 2>&1
  trap 'echo; echo "SG_INSTALL_EXITCODE=$?"' EXIT
fi

APP_DIR="$PREFIX/opt/screenguard"
BIN_DIR="$PREFIX/bin"
DAEMON_BIN="$APP_DIR/screenguard-daemon"
WATCHDOG_BIN="$APP_DIR/screenguard-watchdog"
NOTIFY_BIN="$APP_DIR/screenguard-notify"
KILLER_BIN="$APP_DIR/screenguard-killer"

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
  for _pid in $(daemon_pids "$DAEMON_BIN" "$BIN_DIR/screenguard-daemon"); do
    kill -9 "$_pid" 2>/dev/null || true
  done
  rm -f "$UNIT_FILE" "$AUTOSTART_FILE" "$BIN_DIR/screenguard" "$BIN_DIR/screenguard-daemon" "$BIN_DIR/screenguard-watchdog" "$BIN_DIR/screenguard-notify" "$BIN_DIR/screenguard-killer"
  rm -rf "$APP_DIR"
  if [ "$SYSTEM" -eq 1 ]; then
    # Remove the system entry only when no package manager owns the install.
    if rpm -q screenguard >/dev/null 2>&1 || dpkg -s screenguard >/dev/null 2>&1; then
      log "leaving /usr/share/applications/screenguard.desktop (package-managed)"
    else
      rm -f "/usr/share/applications/screenguard.desktop" && log "removed system menu entry"
    fi
  else
    rm -f "${XDG_DATA_HOME:-$HOME/.local/share}/applications/screenguard.desktop" \
      && log "removed user menu entry"
  fi
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

# --- 1b. Capture autostart state BEFORE the migration sweep below stops
# all instances, so a previously running daemon can be restarted after the
# files are replaced. (Matching helper daemon_pids() is defined near the
# top of this script.)
DAEMON_WAS_RUNNING=0
if [ -n "$(daemon_pids "$DAEMON_BIN" "$BIN_DIR/screenguard-daemon")" ]; then
  DAEMON_WAS_RUNNING=1
fi
UNIT_WAS_ENABLED=0
if [ -f "$UNIT_FILE" ] && command -v systemctl >/dev/null 2>&1; then
  if [ "$SYSTEM" -eq 1 ]; then
    systemctl --global is-enabled --quiet screenguard.service 2>/dev/null && UNIT_WAS_ENABLED=1 || true
  else
    systemctl --user is-enabled --quiet screenguard.service 2>/dev/null && UNIT_WAS_ENABLED=1 || true
  fi
fi

# --- 1c. Migration sweep. Stops watchdogs, daemons and GUIs from ANY
# install (the running GUI itself must not hold the copied binary open —
# "Text file busy" — so during an in-app update the app closes and the
# new version appears on next launch), and flags a package-managed copy
# in /opt/screenguard when one exists. Same logic the RPM/DEB scriptlets
# run, shared via tools/migrate.sh.
if [ -f "$SRC_DIR/migrate.sh" ]; then
  bash "$SRC_DIR/migrate.sh" stop || true
  bash "$SRC_DIR/migrate.sh" untangle-user || true
fi

# --- 1d. Stop the unit and any surviving daemon before copying.
# Overwriting a running executable fails with "Text file busy", so updates
# (re-runs) must stop it first. The migration sweep already stopped most or
# all of these; the steps below make it certain.
if [ -f "$UNIT_FILE" ] && command -v systemctl >/dev/null 2>&1; then
  if [ "$SYSTEM" -eq 1 ]; then
    systemctl stop screenguard.service 2>/dev/null || true
  else
    systemctl --user stop screenguard.service 2>/dev/null || true
  fi
fi
if [ "$DAEMON_WAS_RUNNING" -eq 1 ]; then
  for _pid in $(daemon_pids "$DAEMON_BIN" "$BIN_DIR/screenguard-daemon"); do
    kill "$_pid" 2>/dev/null || true
  done
  sleep 2
  for _pid in $(daemon_pids "$DAEMON_BIN" "$BIN_DIR/screenguard-daemon"); do
    kill -9 "$_pid" 2>/dev/null || true
  done
  if [ -z "$(daemon_pids "$DAEMON_BIN" "$BIN_DIR/screenguard-daemon")" ]; then
    log "stopped running daemon for safe file replacement"
  else
    die "could not stop the running daemon; close ScreenGuard first and re-run"
  fi
fi

# --- 2. Install files ---
log "installing bundle to $APP_DIR ..."
mkdir -p "$APP_DIR" "$BIN_DIR"
cp -a "$SRC_DIR/screenguard" "$SRC_DIR/screenguard-daemon" "$APP_DIR/"
[ -f "$SRC_DIR/screenguard-watchdog" ] && cp -a "$SRC_DIR/screenguard-watchdog" "$APP_DIR/" && chmod +x "$APP_DIR/screenguard-watchdog"
[ -f "$SRC_DIR/screenguard-notify" ] && cp -a "$SRC_DIR/screenguard-notify" "$APP_DIR/" && chmod +x "$APP_DIR/screenguard-notify"
[ -f "$SRC_DIR/screenguard-killer" ] && cp -a "$SRC_DIR/screenguard-killer" "$APP_DIR/" && chmod +x "$APP_DIR/screenguard-killer"
[ -d "$SRC_DIR/data" ] && cp -a "$SRC_DIR/data" "$APP_DIR/"
[ -d "$SRC_DIR/lib" ]  && cp -a "$SRC_DIR/lib"  "$APP_DIR/"
chmod +x "$APP_DIR/screenguard" "$APP_DIR/screenguard-daemon"
ln -sf "$APP_DIR/screenguard" "$BIN_DIR/screenguard"
ln -sf "$APP_DIR/screenguard-daemon" "$BIN_DIR/screenguard-daemon"
[ -f "$WATCHDOG_BIN" ] && ln -sf "$WATCHDOG_BIN" "$BIN_DIR/screenguard-watchdog"
[ -f "$NOTIFY_BIN" ] && ln -sf "$NOTIFY_BIN" "$BIN_DIR/screenguard-notify"
[ -f "$KILLER_BIN" ] && ln -sf "$KILLER_BIN" "$BIN_DIR/screenguard-killer"
log "binaries linked: $BIN_DIR/screenguard, $BIN_DIR/screenguard-daemon"
[ -f "$WATCHDOG_BIN" ] && log "watchdog linked: $BIN_DIR/screenguard-watchdog"
[ -f "$NOTIFY_BIN" ] && log "notification helper linked: $BIN_DIR/screenguard-notify"
[ -f "$KILLER_BIN" ] && log "process killer linked: $BIN_DIR/screenguard-killer"

# --- 2b. Register/refresh the application-menu launcher. For user installs
# this entry takes precedence over a package's /usr/share entry, so after a
# tarball self-update the menu launches the NEW version instead of a parked
# package-managed copy. A --system tarball install only fills the entry in
# when no package manager already owns one.
DESKTOP_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/applications"
DESKTOP_FILE="$DESKTOP_DIR/screenguard.desktop"
if [ "$SYSTEM" -eq 1 ]; then
  DESKTOP_DIR="/usr/share/applications"
  DESKTOP_FILE="$DESKTOP_DIR/screenguard.desktop"
  [ -e "$DESKTOP_FILE" ] || { mkdir -p "$DESKTOP_DIR" 2>/dev/null; MARK_DESKTOP=1; }
fi
if [ "$SYSTEM" -eq 0 ] || [ "${MARK_DESKTOP:-0}" = "1" ]; then
  mkdir -p "$DESKTOP_DIR" 2>/dev/null || true
  cat > "$DESKTOP_FILE" <<EOF
[Desktop Entry]
Name=ScreenGuard (Digital Wellbeing)
Comment=ScreenGuard — Digital Wellbeing for Linux
Exec=$APP_DIR/screenguard
Icon=screenguard
Terminal=false
Type=Application
Categories=Utility;Clock;System;
StartupWMClass=screenguard
StartupNotify=true
Keywords=screenguard;screen;time;wellbeing;focus;limit;
EOF
  chmod 644 "$DESKTOP_FILE" 2>/dev/null || true
  if command -v update-desktop-database >/dev/null 2>&1; then
    update-desktop-database "$DESKTOP_DIR" 2>/dev/null || true
  fi
  log "menu launcher registered: $DESKTOP_FILE"
fi
case ":$PATH:" in
  *":$BIN_DIR:"*) ;;
  *) log "NOTE: $BIN_DIR is not on your PATH. Add this to ~/.bashrc:  export PATH=\"\$PATH:$BIN_DIR\"" ;;
esac

# --- 3. First-run consent: background daemon, always? ---
# On updates (re-runs) an existing autostart configuration means the user
# already answered: preserve it instead of asking again.
PRESERVE_CHOICE=0
if [ -f "$UNIT_FILE" ] || [ -f "$AUTOSTART_FILE" ]; then
  PRESERVE_CHOICE=1
  log "existing autostart configuration found — keeping your previous choice (no prompt)"
fi

if [ "$SKIP_DAEMON" -eq 1 ]; then
  if [ "$DAEMON_WAS_RUNNING" -eq 1 ]; then
    "$DAEMON_BIN" >/dev/null 2>&1 &
    log "files updated; restarted daemon in background as it was running before"
  else
    log "skipping daemon autostart (--no-daemon). Start tracking manually with:  $DAEMON_BIN &"
  fi
  exit 0
fi

SHOULD_ENABLE=0
if [ "$PRESERVE_CHOICE" -eq 1 ]; then
  SHOULD_ENABLE="$UNIT_WAS_ENABLED"
else
  ANSWER=""
  if [ "$ASSUME_YES" -eq 1 ]; then
    ANSWER="y"
  else
    echo ""
    echo "Run the ScreenGuard tracking daemon in the background, always"
    echo "(starts on login, restarts on failure)?  [Y/n]"
    # Prefer the controlling terminal so piped stdin stays usable; fall back
    # to stdin, then to the documented default (yes).
    read -r ANSWER </dev/tty 2>/dev/null || read -r ANSWER 2>/dev/null || ANSWER="y"
  fi

  case "$ANSWER" in
    [Nn]|[Nn][Oo])
      log "daemon autostart declined. Start tracking manually with:  $DAEMON_BIN &"
      exit 0
      ;;
  esac
  SHOULD_ENABLE=1
fi

# --- 4. Install autostart: systemd user unit, XDG autostart as fallback ---
HAVE_SYSTEMD_USER=0
if command -v systemctl >/dev/null 2>&1; then
  if [ "$SYSTEM" -eq 1 ] || systemctl --user show-environment >/dev/null 2>&1; then
    HAVE_SYSTEMD_USER=1
  fi
fi

ENABLE_FAILED=0
if [ "$HAVE_SYSTEMD_USER" -eq 1 ]; then
  mkdir -p "$UNIT_DIR"
  cat > "$UNIT_FILE" <<EOF
[Unit]
Description=ScreenGuard Tracker Daemon
PartOf=graphical-session.target
After=graphical-session.target

[Service]
Type=simple
ExecStart=$DAEMON_BIN
TimeoutStopSec=10
Restart=always
RestartSec=3

[Install]
WantedBy=graphical-session.target
EOF
  if [ "$SYSTEM" -eq 1 ]; then
    systemctl daemon-reload 2>/dev/null || true
    if [ "$SHOULD_ENABLE" -eq 1 ]; then
      systemctl --global enable screenguard.service 2>/dev/null \
        && log "enabled screenguard.service globally (starts on every user login)" \
        || { ENABLE_FAILED=1; log "WARNING: could not enable globally; falling back to XDG autostart"; }
    else
      log "service file refreshed; left disabled as before (enable with: systemctl enable screenguard.service)"
    fi
  else
    systemctl --user daemon-reload 2>/dev/null || true
    if [ "$SHOULD_ENABLE" -eq 1 ]; then
      systemctl --user enable --now screenguard.service 2>/dev/null \
        && log "daemon installed and started (systemd user service, starts on login)" \
        || { ENABLE_FAILED=1; log "WARNING: systemctl --user failed; falling back to XDG autostart"; }
    else
      log "service file refreshed; left disabled as before (enable with: systemctl --user enable --now screenguard.service)"
    fi
  fi
fi

# XDG autostart entry: used when systemd --user is unavailable or enabling
# failed, or to refresh a pre-existing XDG-only setup. Skipped when the
# systemd unit is actively managing the daemon (avoids double launches).
UNIT_ACTIVE=0
if [ "$HAVE_SYSTEMD_USER" -eq 1 ] && [ "$SYSTEM" -eq 0 ]; then
  systemctl --user is-active --quiet screenguard.service 2>/dev/null && UNIT_ACTIVE=1 || true
fi
WANT_XDG=0
XDG_REASON=""
if [ "$HAVE_SYSTEMD_USER" -eq 0 ]; then
  WANT_XDG=1; XDG_REASON="no systemd user session: installed XDG autostart entry ($AUTOSTART_FILE)"
elif [ "$ENABLE_FAILED" -eq 1 ]; then
  WANT_XDG=1; XDG_REASON="systemd enable failed: installed XDG autostart entry ($AUTOSTART_FILE)"
elif [ "$UNIT_ACTIVE" -eq 0 ] && [ "$PRESERVE_CHOICE" -eq 1 ] && [ -f "$AUTOSTART_FILE" ]; then
  WANT_XDG=1; XDG_REASON="refreshed existing XDG autostart entry ($AUTOSTART_FILE)"
fi
if [ "$WANT_XDG" -eq 1 ]; then
  mkdir -p "$AUTOSTART_DIR"
  # Use the watchdog as supervisor when available; falls back to daemon directly
  XDG_EXEC="$DAEMON_BIN"
  [ -x "$WATCHDOG_BIN" ] && XDG_EXEC="$WATCHDOG_BIN"
  cat > "$AUTOSTART_FILE" <<EOF
[Desktop Entry]
Type=Application
Name=ScreenGuard Daemon
Comment=ScreenGuard background screen time tracker
Exec=$XDG_EXEC
Icon=screenguard
Terminal=false
Hidden=false
NoDisplay=true
X-GNOME-Autostart-enabled=true
EOF
  log "$XDG_REASON"
  [ -x "$WATCHDOG_BIN" ] && log "watchdog will supervise daemon (auto-restart on crash)"
elif [ "$UNIT_ACTIVE" -eq 1 ] && [ -f "$AUTOSTART_FILE" ]; then
  # Systemd owns autostart now; drop the shadow XDG entry so the daemon
  # isn't launched twice at login (single-instance lock would save us,
  # but one mechanism is cleaner).
  rm -f "$AUTOSTART_FILE"
  log "removed redundant XDG autostart entry (systemd unit is active)"
fi

# --- 5. Verify ---
_RUNNING_PIDS="$(daemon_pids "$DAEMON_BIN" "$BIN_DIR/screenguard-daemon")"
if [ -n "$_RUNNING_PIDS" ]; then
  log "verified: screenguard-daemon is running (pid $(echo "$_RUNNING_PIDS" | head -n 1))."
else
  log "starting daemon now..."
  "$DAEMON_BIN" >/dev/null 2>&1 &
  sleep 1
  _RUNNING_PIDS="$(daemon_pids "$DAEMON_BIN" "$BIN_DIR/screenguard-daemon")"
  if [ -n "$_RUNNING_PIDS" ]; then
    log "verified: screenguard-daemon is running."
  else
    log "WARNING: could not confirm the daemon is running. Try:  $DAEMON_BIN &"
  fi
fi

log "done. Launch the GUI with 'screenguard' (or $APP_DIR/screenguard)."
