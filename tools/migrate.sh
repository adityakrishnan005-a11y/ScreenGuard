#!/usr/bin/env bash
# ScreenGuard install migration — stop stale instances and reconcile
# multiple/shadowed installs. Runs either as root (RPM/DEB postinst,
# "adopt-package") or as the user (tarball installs via install.sh).
#
# WHY: installs shadow each other. ~/.local (tarball) beats /opt (package)
# for the systemd user unit, the desktop entry and the GNOME extension,
# while a parked package copy keeps a stale binary around — and vice versa
# an old in-app updater can drop a user shadow over a package install.
# This script makes every install path converge to one healthy instance:
#
#   migrate.sh stop            kill watchdogs, daemons and GUIs (any install)
#   migrate.sh untangle-user   pre-flight for user/tarball installs: if a
#                              package install exists, keep going but say
#                              so (newest version wins)
#   migrate.sh adopt-package   root-side (%post/postinst): repair every
#                              desktop user's home so the freshly installed
#                              package becomes the single authority
#                              (removes user shadows, refreshes stale
#                              extension copies, cleans legacy symlinks)
#
# Idempotent; safe when nothing is installed; never touches tracking data
# (~/.local/share/screenguard). Set SG_MIGRATE_DRYRUN=1 to log actions
# without performing them (kills become messages, deletions are skipped).
set -u

DRY=${SG_MIGRATE_DRYRUN:-0}
log() { echo "[screenguard-migrate] $*" >&2; }

# Only signal PIDs whose live executable really is one of ours — kills the
# pkill-matches-my-own-command-line foot-gun.
_is_ours() { # $1: pid -> true when /proc/<pid>/exe basename is screenguard*
  local exe base
  exe="$(readlink -f "/proc/$1/exe" 2>/dev/null)" || return 1
  base="${exe##*/}"
  case "$base" in screenguard*) return 0 ;; *) return 1 ;; esac
}

_kill_one() { # $1 signal, $2 pid
  if [ "$DRY" = 1 ]; then
    log "dryrun: would SIG$1 pid $2"
    return 0
  fi
  kill -"$1" "$2" 2>/dev/null || true
}

# Stop watchdogs first (they would restart the daemon under us), then
# daemons, then GUIs. TERM with a grace window, then KILL the leftovers.
sg_stop_all() {
  local round sig p
  for round in 1 2; do
    sig=TERM
    [ "$round" = 2 ] && sig=KILL
    for p in $(pgrep -f 'screenguard-watchdog' 2>/dev/null || true); do
      _is_ours "$p" && _kill_one "$sig" "$p"
    done
    for p in $(pgrep -f 'screenguard-daemon' 2>/dev/null || true); do
      _is_ours "$p" && _kill_one "$sig" "$p"
    done
    for p in $(pgrep -x screenguard 2>/dev/null || true); do
      _is_ours "$p" && _kill_one "$sig" "$p"
    done
    [ "$DRY" = 1 ] || sleep 2
  done
  return 0
}

# Stop the systemd-user unit (correct context per session) + daemon-reload.
sg_systemd_stop() {
  command -v systemctl >/dev/null 2>&1 || return 0
  if [ "$(id -u)" = 0 ]; then
    local udir uid uname
    for udir in /run/user/[0-9]*; do
      [ -d "$udir" ] || continue
      uid="$(basename "$udir")"
      case "$uid" in '' | *[!0-9]*) continue ;; esac
      [ "$uid" -ge 1000 ] 2>/dev/null || continue
      uname="$(id -nu "$uid" 2>/dev/null)" || continue
      [ -n "$uname" ] || continue
      if [ "$DRY" = 1 ]; then
        log "dryrun: would stop unit + reload for $uname"
      else
        sudo -u "$uname" XDG_RUNTIME_DIR="$udir" \
          DBUS_SESSION_BUS_ADDRESS="unix:path=$udir/bus" \
          systemctl --user stop screenguard.service 2>/dev/null || true
        sudo -u "$uname" XDG_RUNTIME_DIR="$udir" \
          DBUS_SESSION_BUS_ADDRESS="unix:path=$udir/bus" \
          systemctl --user daemon-reload 2>/dev/null || true
      fi
    done
  else
    systemctl --user stop screenguard.service 2>/dev/null || true
    systemctl --user daemon-reload 2>/dev/null || true
  fi
}

# User/tarball pre-flight: steady state = newest wins. If a package install
# exists, the new user install is the one that runs — tell the user to keep
# the package copy in step (or retire it).
sg_untangle_user() {
  if [ -e /opt/screenguard/screenguard-daemon ] || [ -e /opt/screenguard/screenguard ]; then
    log "a package-managed ScreenGuard also exists in /opt/screenguard."
    log "The new install will be the one that runs; keep the package copy in"
    log "step with your package manager afterwards (dnf/apt) or remove it."
  fi
}

# Root-side reconciliation: the freshly installed package becomes the only
# authority for every desktop user with a shadowed/older install.
sg_adopt_package() {
  sg_stop_all
  sg_systemd_stop

  local homes pkg_ext h f bn
  if [ "$(id -u)" = 0 ]; then
    homes="$(getent passwd | awk -F: '$3 >= 1000 && $7 !~ /nologin|false$/ {print $6}')"
  else
    homes="${HOME}"
  fi
  pkg_ext="/usr/share/gnome-shell/extensions/screenguard@screenguard.app"

  for h in $homes; do
    [ -d "$h" ] || continue
    # 1) Remove this user's shadow of the package install.
    if [ "$DRY" = 1 ]; then
      log "dryrun: would clear $h/.local/opt/screenguard + user unit/entry links"
    else
      rm -rf "$h/.local/opt/screenguard" 2>/dev/null
      for f in screenguard screenguard-daemon screenguard-watchdog \
        screenguard-notify screenguard-killer; do
        rm -f "$h/.local/bin/$f" 2>/dev/null
      done
      rm -f "$h/.config/systemd/user/screenguard.service" 2>/dev/null
      rm -f "$h/.config/autostart/screenguard-daemon.desktop" 2>/dev/null
      rm -f "$h/.local/share/applications/screenguard.desktop" 2>/dev/null
      rm -rf "$h/.cache/screenguard/update" 2>/dev/null
    fi

    # 2) Refresh stale user extension copies from the package. GNOME loads
    #    the user dir first, so an older user file must not shadow a newer
    #    packaged one: copy only what the package has that is newer.
    if [ -d "$pkg_ext" ]; then
      local usr_ext="$h/.local/share/gnome-shell/extensions/screenguard@screenguard.app"
      if [ -d "$usr_ext" ]; then
        for f in "$pkg_ext"/*; do
          bn="$(basename "$f")"
          if [ "$f" -nt "$usr_ext/$bn" ]; then
            if [ "$DRY" = 1 ]; then
              log "dryrun: would refresh extension file $bn for $h"
            else
              cp -f "$f" "$usr_ext/$bn" 2>/dev/null &&
                log "refreshed extension file $bn for $(basename "$h")"
            fi
          fi
        done
      else
        if [ "$DRY" = 1 ]; then
          log "dryrun: would install extension copy to $usr_ext"
        else
          mkdir -p "$usr_ext" 2>/dev/null
          cp -a "$pkg_ext"/. "$usr_ext"/ 2>/dev/null &&
            log "installed extension copy for $(basename "$h")"
        fi
      fi
    fi
  done

  # 3) Legacy root symlinks that hijack unit enablement.
  if [ "$(id -u)" = 0 ] && [ "$DRY" != 1 ]; then
    rm -f /etc/systemd/user/default.target.wants/screenguard.service 2>/dev/null
    rm -f /etc/systemd/user/graphical-session.target.wants/screenguard.service 2>/dev/null
  fi

  # 4) Tell every live session the picture changed. The deletions above are
  #    only real to systemd after a daemon-reload: a stale cached unit that
  #    points at a removed install otherwise keeps the manager spawning a
  #    dead path (203/EXEC restart loop) instead of handing control to the
  #    freshly installed package unit.
  if [ "$(id -u)" = 0 ]; then
    local udir uid uname
    for udir in /run/user/[0-9]*; do
      [ -d "$udir" ] || continue
      uid="$(basename "$udir")"
      case "$uid" in '' | *[!0-9]*) continue ;; esac
      [ "$uid" -ge 1000 ] 2>/dev/null || continue
      uname="$(id -nu "$uid" 2>/dev/null)" || continue
      [ -n "$uname" ] || continue
      sudo -u "$uname" XDG_RUNTIME_DIR="$udir" \
        DBUS_SESSION_BUS_ADDRESS="unix:path=$udir/bus" \
        systemctl --user daemon-reload 2>/dev/null || true
    done
  else
    systemctl --user daemon-reload 2>/dev/null || true
  fi
  log "package install is now the single source of ScreenGuard on this system"
}

case "${1:-}" in
  stop)
    sg_systemd_stop
    sg_stop_all
    ;;
  untangle-user) sg_untangle_user ;;
  adopt-package) sg_adopt_package ;;
  *)
    echo "usage: migrate.sh stop|untangle-user|adopt-package" >&2
    exit 2
    ;;
esac
