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
      # ...but only within THIS session. daemon.lock lives in
      # $XDG_RUNTIME_DIR, so a daemon running under a different runtime dir
      # (another login, a sandbox, an isolated test) cannot block us and
      # killing it would be trespassing. An unreadable/absent value keeps the
      # historical behaviour (assume ours) so stale-lock protection is never
      # lost to a missing /proc entry.
      # `cat` (not `< file`) so an unreadable root process's environ fails
      # silently instead of printing "Permission denied" for every pid.
      _pid_rt="$(cat "$d/environ" 2>/dev/null | tr '\0' '\n' \
        | sed -n 's/^XDG_RUNTIME_DIR=//p' | head -n 1)"
      if [ -n "$_pid_rt" ] && [ -n "${XDG_RUNTIME_DIR:-}" ] \
         && [ "$_pid_rt" != "$XDG_RUNTIME_DIR" ]; then
        continue
      fi
      echo "$pid"
      continue
    fi
    # The cmdline can disappear between readdir and this open (a dying
    # process); bail silently instead of printing an open error per race.
    [ -r "$d/cmdline" ] || continue
    while IFS= read -r arg; do
      if [ "$arg" = "$want1" ] || [ "$arg" = "$want2" ]; then
        echo "$pid"
        break
      fi
    done < <(tr '\0' '\n' < "$d/cmdline" 2>/dev/null) 2>/dev/null
  done
  return 0
}

# Echo pids whose resolved executable basename is exactly one of the names
# given. Used to stop the supervisor and its worker without pgrep -f, which
# can match our own command line.
exe_pids() { # $@ = basenames; only this session's processes
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
          echo "$pid"
        fi
        break
      fi
    done
  done
  return 0
}

# Echo paired "-E" "VAR=value" arguments for session variables currently
# set. Transient services do NOT inherit the caller's environment unless
# forwarded with -E, and the end-of-install notification + GUI relaunch
# need the display/session variables (the user-manager environment does
# not carry them). Runs inside set -euo pipefail: always exits 0.
forward_env_args() {
  local _v _val _kv
  for _v in WAYLAND_DISPLAY DISPLAY XDG_SESSION_TYPE XDG_SESSION_DESKTOP \
            XDG_CURRENT_DESKTOP DBUS_SESSION_BUS_ADDRESS PATH; do
    eval "_val=\${$_v:-}"
    [ -n "$_val" ] || continue
    printf '%s\n' "-E" "$_v=$_val"
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
  mapfile -t DETACH_ENV < <(forward_env_args)
  systemd-run --user --quiet --wait --collect \
    -E "SG_INSTALL_DETACHED=1" \
    -E "SG_INSTALL_RESULT=$RESULT_FILE" \
    "${DETACH_ENV[@]}" \
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
NOTIFY_BIN="$APP_DIR/screenguard-notify"
KILLER_BIN="$APP_DIR/screenguard-killer"
DIGIWELLD_BIN="$APP_DIR/digiwelld"
SESSION_WORKER_BIN="$APP_DIR/digiwelld-session"
USAGE_WORKER_BIN="$APP_DIR/digiwelld-usage"
POLICY_WORKER_BIN="$APP_DIR/digiwelld-policy"
STORE_WORKER_BIN="$APP_DIR/digiwelld-store"

if [ "$SYSTEM" -eq 1 ]; then
  UNIT_DIR="/etc/systemd/user"
  AUTOSTART_DIR="/etc/xdg/autostart"
else
  UNIT_DIR="${HOME}/.config/systemd/user"
  AUTOSTART_DIR="${HOME}/.config/autostart"
fi
UNIT_FILE="$UNIT_DIR/screenguard.service"
DIGIWELLD_UNIT_FILE="$UNIT_DIR/digiwelld.service"
# Pre-rename units are removed as part of the upgrade, never left to race.
LEGACY_BROKER_UNIT_FILE="$UNIT_DIR/screenguard-broker.service"
AUTOSTART_FILE="$AUTOSTART_DIR/screenguard-daemon.desktop"

do_uninstall() {
  log "uninstalling ScreenGuard..."
  if command -v systemctl >/dev/null 2>&1; then
    if [ "$SYSTEM" -eq 1 ]; then
      systemctl --global disable screenguard.service digiwelld.service screenguard-broker.service 2>/dev/null || true
    else
      systemctl --user disable --now digiwelld.service 2>/dev/null || true
      systemctl --user disable --now screenguard-broker.service 2>/dev/null || true
      systemctl --user disable --now screenguard.service 2>/dev/null || true
    fi
  fi
  # Stop the supervisor before the daemon: a live supervisor would respawn
  # the daemon we just killed. TERM lets it close sessions through the worker.
  for _pid in $(exe_pids digiwelld screenguard-broker screenguard-watchdog); do
    kill -TERM "$_pid" 2>/dev/null || true
  done
  sleep 1
  for _pid in $(exe_pids digiwelld screenguard-broker screenguard-watchdog digiwelld-session digiwelld-usage digiwelld-policy digiwelld-store); do
    kill -9 "$_pid" 2>/dev/null || true
  done
  for _pid in $(daemon_pids "$DAEMON_BIN" "$BIN_DIR/screenguard-daemon"); do
    kill -9 "$_pid" 2>/dev/null || true
  done
  rm -f "$UNIT_FILE" "$DIGIWELLD_UNIT_FILE" "$LEGACY_BROKER_UNIT_FILE" "$AUTOSTART_FILE" "$BIN_DIR/screenguard" "$BIN_DIR/screenguard-daemon" "$BIN_DIR/screenguard-watchdog" "$BIN_DIR/screenguard-notify" "$BIN_DIR/screenguard-killer" "$BIN_DIR/screenguard-broker" "$BIN_DIR/digiwelld" "$BIN_DIR/digiwelld-session" "$BIN_DIR/digiwelld-usage" "$BIN_DIR/digiwelld-policy" "$BIN_DIR/digiwelld-store" "$BIN_DIR/cinnamon_focus"
  # Remove the shadow of a distro autostart entry, but only if this installer
  # wrote it (never delete a user's own file).
  if [ -f "$AUTOSTART_DIR/screenguard-autostart.desktop" ] \
     && grep -q "Shadowed by the ScreenGuard install" "$AUTOSTART_DIR/screenguard-autostart.desktop" 2>/dev/null; then
    rm -f "$AUTOSTART_DIR/screenguard-autostart.desktop"
  fi
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

# --- 1a. Choose the unit that owns the daemon. digiwelld is the front door:
# it owns the socket, the uid check, the routing table, the storage lock, the
# crash budget and the daemon supervision. So when a digiwelld binary is
# present, the digiwelld unit is what gets enabled and the plain daemon unit
# is only written as a manual fallback. Both units carry Conflicts= so they
# can never run at the same time (two daemons would fight over daemon.lock).
HAVE_DIGIWELLD=0
if [ -x "$SRC_DIR/digiwelld" ]; then
  HAVE_DIGIWELLD=1
fi

# The native session worker is optional: when present, digiwelld supervises
# it and the daemon is told to write durable session state through it.
SESSION_WORKER_ARG=""
if [ -x "$SRC_DIR/digiwelld-session" ]; then
  SESSION_WORKER_ARG="--session-worker $SESSION_WORKER_BIN"
fi
# Same optional-worker rule for the usage read model: the supervisor routes the
# usage domain to it and treats the Dart daemon as the writer.
USAGE_WORKER_ARG=""
if [ -x "$SRC_DIR/digiwelld-usage" ]; then
  USAGE_WORKER_ARG="--usage-worker $USAGE_WORKER_BIN"
fi
# The policy worker owns policy writes and the focus state machine. It is the
# only process allowed to advance getActiveFocusState().
POLICY_WORKER_ARG=""
if [ -x "$SRC_DIR/digiwelld-policy" ]; then
  POLICY_WORKER_ARG="--policy-worker $POLICY_WORKER_BIN"
fi
# The store worker is the single SQLite writer for sessions and events. It
# creates the database and its schema on first boot.
STORE_WORKER_ARG=""
if [ -x "$SRC_DIR/digiwelld-store" ]; then
  STORE_WORKER_ARG="--store-worker $STORE_WORKER_BIN"
fi
OWNER_UNIT_NAME="screenguard.service"
OWNER_UNIT_FILE="$UNIT_FILE"
if [ "$HAVE_DIGIWELLD" -eq 1 ]; then
  OWNER_UNIT_NAME="digiwelld.service"
  OWNER_UNIT_FILE="$DIGIWELLD_UNIT_FILE"
fi

# --- 1b. Capture autostart state BEFORE the migration sweep below stops
# all instances, so a previously running daemon can be restarted after the
# files are replaced. (Matching helper daemon_pids() is defined near the
# top of this script.)
DAEMON_WAS_RUNNING=0
if [ -n "$(daemon_pids "$DAEMON_BIN" "$BIN_DIR/screenguard-daemon")" ]; then
  DAEMON_WAS_RUNNING=1
fi
UNIT_WAS_ENABLED=0
AUTOSTART_WAS_CONFIGURED=0
if [ -f "$UNIT_FILE" ] || [ -f "$DIGIWELLD_UNIT_FILE" ] \
   || [ -f "$LEGACY_BROKER_UNIT_FILE" ] || [ -f "$AUTOSTART_FILE" ]; then
  AUTOSTART_WAS_CONFIGURED=1
fi
if [ "$AUTOSTART_WAS_CONFIGURED" -eq 1 ] && command -v systemctl >/dev/null 2>&1; then
  for _unit in "$OWNER_UNIT_NAME" digiwelld.service screenguard-broker.service screenguard.service; do
    if [ "$SYSTEM" -eq 1 ]; then
      systemctl --global is-enabled --quiet "$_unit" 2>/dev/null && UNIT_WAS_ENABLED=1 || true
    else
      systemctl --user is-enabled --quiet "$_unit" 2>/dev/null && UNIT_WAS_ENABLED=1 || true
    fi
  done
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
if command -v systemctl >/dev/null 2>&1; then
  if [ "$SYSTEM" -eq 1 ]; then
    systemctl stop digiwelld.service screenguard-broker.service screenguard.service 2>/dev/null || true
  else
    systemctl --user stop digiwelld.service screenguard-broker.service screenguard.service 2>/dev/null || true
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
[ -f "$SRC_DIR/screenguard-notify" ] && cp -a "$SRC_DIR/screenguard-notify" "$APP_DIR/" && chmod +x "$APP_DIR/screenguard-notify"
[ -f "$SRC_DIR/screenguard-killer" ] && cp -a "$SRC_DIR/screenguard-killer" "$APP_DIR/" && chmod +x "$APP_DIR/screenguard-killer"
[ -f "$SRC_DIR/digiwelld" ] && cp -a "$SRC_DIR/digiwelld" "$APP_DIR/" && chmod +x "$APP_DIR/digiwelld"
[ -f "$SRC_DIR/digiwelld-session" ] && cp -a "$SRC_DIR/digiwelld-session" "$APP_DIR/" && chmod +x "$APP_DIR/digiwelld-session"
[ -f "$SRC_DIR/digiwelld-usage" ] && cp -a "$SRC_DIR/digiwelld-usage" "$APP_DIR/" && chmod +x "$APP_DIR/digiwelld-usage"
[ -f "$SRC_DIR/digiwelld-policy" ] && cp -a "$SRC_DIR/digiwelld-policy" "$APP_DIR/" && chmod +x "$APP_DIR/digiwelld-policy"
[ -f "$SRC_DIR/digiwelld-store" ] && cp -a "$SRC_DIR/digiwelld-store" "$APP_DIR/" && chmod +x "$APP_DIR/digiwelld-store"
[ -f "$SRC_DIR/cinnamon_focus" ] && cp -a "$SRC_DIR/cinnamon_focus" "$APP_DIR/" && chmod +x "$APP_DIR/cinnamon_focus"
[ -d "$SRC_DIR/data" ] && cp -a "$SRC_DIR/data" "$APP_DIR/"
[ -d "$SRC_DIR/lib" ]  && cp -a "$SRC_DIR/lib"  "$APP_DIR/"
chmod +x "$APP_DIR/screenguard" "$APP_DIR/screenguard-daemon"
ln -sf "$APP_DIR/screenguard" "$BIN_DIR/screenguard"
ln -sf "$APP_DIR/screenguard-daemon" "$BIN_DIR/screenguard-daemon"
[ -f "$NOTIFY_BIN" ] && ln -sf "$NOTIFY_BIN" "$BIN_DIR/screenguard-notify"
[ -f "$KILLER_BIN" ] && ln -sf "$KILLER_BIN" "$BIN_DIR/screenguard-killer"
[ -f "$DIGIWELLD_BIN" ] && ln -sf "$DIGIWELLD_BIN" "$BIN_DIR/digiwelld"
[ -f "$SESSION_WORKER_BIN" ] && ln -sf "$SESSION_WORKER_BIN" "$BIN_DIR/digiwelld-session"
[ -f "$USAGE_WORKER_BIN" ] && ln -sf "$USAGE_WORKER_BIN" "$BIN_DIR/digiwelld-usage"
[ -f "$POLICY_WORKER_BIN" ] && ln -sf "$POLICY_WORKER_BIN" "$BIN_DIR/digiwelld-policy"
[ -f "$STORE_WORKER_BIN" ] && ln -sf "$STORE_WORKER_BIN" "$BIN_DIR/digiwelld-store"
[ -f "$APP_DIR/cinnamon_focus" ] && ln -sf "$APP_DIR/cinnamon_focus" "$BIN_DIR/cinnamon_focus"

# The standalone watchdog and the broker were merged into digiwelld. Remove
# their binaries and links unconditionally so an old copy can never be
# launched by a stale desktop entry, unit, or shell alias. These names are
# legacy-only: this version never builds or starts them.
rm -f "$APP_DIR/screenguard-watchdog" "$APP_DIR/screenguard-broker" \
      "$BIN_DIR/screenguard-watchdog" "$BIN_DIR/screenguard-broker"

log "binaries linked: $BIN_DIR/screenguard, $BIN_DIR/screenguard-daemon"
[ -f "$NOTIFY_BIN" ] && log "notification helper linked: $BIN_DIR/screenguard-notify"
[ -f "$KILLER_BIN" ] && log "process killer linked: $BIN_DIR/screenguard-killer"
[ -f "$DIGIWELLD_BIN" ] && log "supervisor linked: $BIN_DIR/digiwelld (socket, auth, routing, crash budget)"
[ -f "$SESSION_WORKER_BIN" ] && log "session worker linked: $BIN_DIR/digiwelld-session (supervised by digiwelld)"
[ -f "$USAGE_WORKER_BIN" ] && log "usage worker linked: $BIN_DIR/digiwelld-usage (read-only usage domain)"
[ -f "$POLICY_WORKER_BIN" ] && log "policy worker linked: $BIN_DIR/digiwelld-policy (policy intent + focus state machine)"
[ -f "$STORE_WORKER_BIN" ] && log "store worker linked: $BIN_DIR/digiwelld-store (single writer for sessions and events)"
[ -f "$APP_DIR/cinnamon_focus" ] && log "Cinnamon focus helper installed: $APP_DIR/cinnamon_focus"

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
if [ "$AUTOSTART_WAS_CONFIGURED" -eq 1 ]; then
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
# A distro package may ship /etc/xdg/autostart/screenguard-autostart.desktop
# pointing at /usr/bin/screenguard-daemon. If it runs alongside this install,
# the package daemon grabs daemon.lock first and the local daemon exits on
# every start. Shadow the system entry on user installs so only one runs.
if [ "$SYSTEM" -eq 0 ] && [ -f "/etc/xdg/autostart/screenguard-autostart.desktop" ]; then
  mkdir -p "$AUTOSTART_DIR"
  cat > "$AUTOSTART_DIR/screenguard-autostart.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=ScreenGuard Daemon (shadowed)
Comment=Shadowed by the ScreenGuard install in $PREFIX; the daemon is started by this install instead.
Exec=/usr/bin/screenguard-daemon
Hidden=true
X-GNOME-Autostart-enabled=false
EOF
  log "shadowed the distro autostart entry (/etc/xdg/autostart/screenguard-autostart.desktop) so two daemons cannot fight over the lock"
fi

HAVE_SYSTEMD_USER=0
if command -v systemctl >/dev/null 2>&1; then
  if [ "$SYSTEM" -eq 1 ] || systemctl --user show-environment >/dev/null 2>&1; then
    HAVE_SYSTEMD_USER=1
  fi
fi

ENABLE_FAILED=0
if [ "$HAVE_SYSTEMD_USER" -eq 1 ]; then
  mkdir -p "$UNIT_DIR"
  # The broker unit is replaced by digiwelld.service. Remove it before
  # daemon-reload so a stale wants-symlink cannot start the old binary.
  rm -f "$LEGACY_BROKER_UNIT_FILE"
  if [ "$HAVE_DIGIWELLD" -eq 1 ]; then
    cat > "$DIGIWELLD_UNIT_FILE" <<EOF
[Unit]
Description=ScreenGuard Supervisor (native socket, auth, routing, daemon supervision)
PartOf=graphical-session.target
After=graphical-session.target
# Never run next to the standalone daemon unit: digiwelld spawns and
# supervises its own daemon, and two daemons would race on daemon.lock.
Conflicts=screenguard.service

[Service]
Type=simple
# %t is the per-user runtime dir (XDG_RUNTIME_DIR). digiwelld creates
# %t/screenguard itself with mode 0700 and the control socket with 0600.
ExecStart=$DIGIWELLD_BIN --runtime %t/screenguard --daemon $DAEMON_BIN $SESSION_WORKER_ARG $USAGE_WORKER_ARG $POLICY_WORKER_ARG $STORE_WORKER_ARG
# digiwelld never exits on its own; if it dies, systemd brings it back and
# it re-owns the socket, the crash budget and the daemon.
Restart=always
RestartSec=2
# digiwelld forwards SIGTERM to its children and waits up to 5s for each.
TimeoutStopSec=15
KillMode=control-group

[Install]
WantedBy=graphical-session.target
EOF
  fi
  cat > "$UNIT_FILE" <<EOF
[Unit]
Description=ScreenGuard Tracker Daemon
PartOf=graphical-session.target
After=graphical-session.target
Conflicts=digiwelld.service

[Service]
Type=simple
ExecStart=$DAEMON_BIN
TimeoutStopSec=10
# on-failure, not always: the daemon exits 0 when another instance already
# owns daemon.lock (e.g. a distro package's autostart). Restart=always turned
# that into an endless 3-second restart loop, spamming the journal hundreds of
# times. A real crash still exits non-zero and is restarted.
Restart=on-failure
RestartSec=3

[Install]
WantedBy=graphical-session.target
EOF
  if [ "$SYSTEM" -eq 1 ]; then
    systemctl daemon-reload 2>/dev/null || true
    if [ "$SHOULD_ENABLE" -eq 1 ]; then
      systemctl --global disable screenguard.service screenguard-broker.service digiwelld.service 2>/dev/null || true
      systemctl --global enable "$OWNER_UNIT_NAME" 2>/dev/null \
        && log "enabled $OWNER_UNIT_NAME globally (starts on every user login)" \
        || { ENABLE_FAILED=1; log "WARNING: could not enable globally; falling back to XDG autostart"; }
    else
      log "service file refreshed; left disabled as before (enable with: systemctl enable $OWNER_UNIT_NAME)"
    fi
  else
    systemctl --user daemon-reload 2>/dev/null || true
    if [ "$SHOULD_ENABLE" -eq 1 ]; then
      # Disable first: an existing wants-symlink pointing at ANOTHER copy
      # of this unit (e.g. a package-owned /usr/lib unit) is not re-pointed
      # by enabled-with-no-change, so at the next login systemd started the
      # stale binary, which grabbed the single-instance lock and
      # crash-looped the freshly installed daemon (seen live: 102 restarts
      # of the new unit, "Another daemon instance is already running").
      systemctl --user disable screenguard.service screenguard-broker.service digiwelld.service 2>/dev/null || true
      systemctl --user enable --now "$OWNER_UNIT_NAME" 2>/dev/null \
        && log "installed and started (systemd user service $OWNER_UNIT_NAME, starts on login)" \
        || { ENABLE_FAILED=1; log "WARNING: systemctl --user failed; falling back to XDG autostart"; }
    else
      log "service file refreshed; left disabled as before (enable with: systemctl --user enable --now $OWNER_UNIT_NAME)"
    fi
  fi
fi

# XDG autostart entry: used when systemd --user is unavailable or enabling
# failed, or to refresh a pre-existing XDG-only setup. Skipped when the
# systemd unit is actively managing the daemon (avoids double launches).
UNIT_ACTIVE=0
if [ "$HAVE_SYSTEMD_USER" -eq 1 ] && [ "$SYSTEM" -eq 0 ]; then
  systemctl --user is-active --quiet "$OWNER_UNIT_NAME" 2>/dev/null && UNIT_ACTIVE=1 || true
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
  # Prefer digiwelld (it owns the socket and supervises the daemon with a
  # crash budget). The bare daemon is only a last-resort fallback.
  XDG_EXEC="$DAEMON_BIN"
  if [ -x "$DIGIWELLD_BIN" ]; then
    XDG_EXEC="$DIGIWELLD_BIN --daemon $DAEMON_BIN $SESSION_WORKER_ARG $USAGE_WORKER_ARG $POLICY_WORKER_ARG $STORE_WORKER_ARG"
  fi
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
  if [ -x "$DIGIWELLD_BIN" ]; then
    log "digiwelld will own the socket and supervise the daemon (crash budget, auto-restart)"
  fi
elif [ "$UNIT_ACTIVE" -eq 1 ] && [ -f "$AUTOSTART_FILE" ]; then
  # Systemd owns autostart now; drop the shadow XDG entry so the daemon
  # isn't launched twice at login (single-instance lock would save us,
  # but one mechanism is cleaner).
  rm -f "$AUTOSTART_FILE"
  log "removed redundant XDG autostart entry (systemd unit is active)"
fi

# --- 5. Own the daemon. Anything running the OLD binary (respawned behind
# our back mid-install, or started by another install's unit) must not
# survive: it either holds the single-instance lock, so the fresh unit's
# daemon exits and systemd crash-loops it forever (seen live: 102 restarts),
# or runs stale code next to a new GUI (version skew). Sweep, then verify.
sleep 1
for _pid in $(daemon_pids "$DAEMON_BIN" "$BIN_DIR/screenguard-daemon"); do
  _exe="$(readlink "/proc/$_pid/exe" 2>/dev/null || true)"
  if [ "$_exe" != "$DAEMON_BIN" ]; then
    kill -9 "$_pid" 2>/dev/null || true
    log "stopped stale daemon pid $_pid ($_exe)."
  fi
done
sleep 1
_RUNNING_PIDS="$(daemon_pids "$DAEMON_BIN" "$BIN_DIR/screenguard-daemon")"
if [ -n "$_RUNNING_PIDS" ]; then
  log "verified: screenguard-daemon is running (pid $(echo "$_RUNNING_PIDS" | head -n 1))."
else
  log "starting daemon now..."
  # Spawn detached — a plain background child would be killed when this
  # transient service's cgroup is torn down on exit. A transient unit of
  # its own lives until the next login/logout cycle.
  if [ "$HAVE_SYSTEMD_USER" -eq 1 ] && command -v systemd-run >/dev/null 2>&1 && [ "$SYSTEM" -eq 0 ]; then
    mapfile -t DAEMON_ENV < <(forward_env_args)
    if [ -x "$DIGIWELLD_BIN" ]; then
      log "starting digiwelld now (it owns the socket and supervises the daemon)..."
      systemd-run --user --quiet --collect --unit="screenguard-digiwelld-$$.service" \
        "${DAEMON_ENV[@]}" "$DIGIWELLD_BIN" --daemon "$DAEMON_BIN" $SESSION_WORKER_ARG $USAGE_WORKER_ARG $POLICY_WORKER_ARG $STORE_WORKER_ARG >/dev/null 2>&1 || true
    else
      systemd-run --user --quiet --collect --unit="screenguard-daemon-$$.service" \
        "${DAEMON_ENV[@]}" "$DAEMON_BIN" >/dev/null 2>&1 || true
    fi
  elif [ -x "$DIGIWELLD_BIN" ]; then
    # No systemd user session: start the same thing the XDG autostart entry
    # starts — digiwelld, which owns the socket, the crash budget and the
    # daemon. Starting the bare daemon here would run without auth/routing
    # until the next login, and its lock would then make digiwelld's daemon
    # exit cleanly.
    log "starting digiwelld (it owns the socket and supervises the daemon)..."
    if command -v setsid >/dev/null 2>&1; then
      setsid "$DIGIWELLD_BIN" --daemon "$DAEMON_BIN" $SESSION_WORKER_ARG $USAGE_WORKER_ARG $POLICY_WORKER_ARG $STORE_WORKER_ARG >/dev/null 2>&1 &
    else
      nohup "$DIGIWELLD_BIN" --daemon "$DAEMON_BIN" $SESSION_WORKER_ARG $USAGE_WORKER_ARG $POLICY_WORKER_ARG $STORE_WORKER_ARG >/dev/null 2>&1 &
    fi
  elif command -v setsid >/dev/null 2>&1; then
    setsid "$DAEMON_BIN" >/dev/null 2>&1 &
  else
    "$DAEMON_BIN" >/dev/null 2>&1 &
  fi
  sleep 1
  _RUNNING_PIDS="$(daemon_pids "$DAEMON_BIN" "$BIN_DIR/screenguard-daemon")"
  if [ -n "$_RUNNING_PIDS" ]; then
    log "verified: screenguard-daemon is running."
  else
    log "WARNING: could not confirm the daemon is running. Try:  $DAEMON_BIN &"
  fi
fi

# --- 6. Announce. The updater's GUI was closed by the migration sweep (or
# by the user), so from the user's view the app just vanished: this is the
# proof the update landed — a desktop notification, then the NEW GUI is
# relaunched automatically. Skipped for root/system installs: under a
# pkexec scriptlet no user session environment is guaranteed.
if [ "$SYSTEM" -eq 0 ]; then
  mapfile -t REOPEN_ENV < <(forward_env_args)
  if [ "${#REOPEN_ENV[@]}" -gt 0 ]; then
    _NOTIFY=""
    for _n in "$APP_DIR/screenguard-notify" "$HOME/.local/bin/screenguard-notify" \
              /opt/screenguard/screenguard-notify /usr/bin/screenguard-notify; do
      [ -x "$_n" ] && { _NOTIFY="$_n"; break; }
    done
    if [ -n "$_NOTIFY" ]; then
      "$_NOTIFY" -t "ScreenGuard updated" \
        -b "Installed successfully — reopening ScreenGuard." \
        -i screenguard -u normal -e 8000 >/dev/null 2>&1 || true
      log "update notification sent."
    fi
    if [ "$HAVE_SYSTEMD_USER" -eq 1 ] && command -v systemd-run >/dev/null 2>&1 && [ -f "$APP_DIR/screenguard" ]; then
      # Own transient unit (own cgroup): survives THIS service's exit and,
      # with --collect, vanishes again when the user closes the GUI.
      systemd-run --user --quiet --collect --unit="screenguard-gui-$$.service" \
        "${REOPEN_ENV[@]}" "$APP_DIR/screenguard" >/dev/null 2>&1 \
        && log "reopened the GUI from the new install." \
        || log "could not auto-reopen; use the app menu to open it."
    elif [ -x "$APP_DIR/screenguard" ] && command -v setsid >/dev/null 2>&1; then
      # No systemd to detach into: own session is enough for a GUI.
      setsid "$APP_DIR/screenguard" >/dev/null 2>&1 \
        && log "reopened the GUI from the new install." \
        || log "could not auto-reopen; use the app menu to open it."
    fi
  fi
fi

# --- 7. Housekeeping. When the updater's own process was killed mid-flight
# (old betas), its staging dir was never cleaned up; drop it here — but
# only when we ARE that staging dir (manual/dev runs elsewhere untouched).
_UPDATER_CACHE="${XDG_CACHE_HOME:-$HOME/.cache}/screenguard/update"
_CASE_DIR="$(cd "$(dirname "$0")" 2>/dev/null && pwd)" || _CASE_DIR=""
if [ -n "$_CASE_DIR" ] && [ "$_CASE_DIR" = "$_UPDATER_CACHE" ]; then
  rm -rf "$_UPDATER_CACHE" 2>/dev/null || true
  log "cleaned the updater staging directory."
fi

log "done. Launch the GUI with 'screenguard' (or $APP_DIR/screenguard)."
