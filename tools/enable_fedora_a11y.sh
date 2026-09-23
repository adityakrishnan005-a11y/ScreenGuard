#!/usr/bin/env bash
# Enable AT-SPI accessibility for sandboxed (Flatpak) apps on Fedora / GNOME Wayland
# so ScreenGuard can track them, and autostart the tracking daemon.
set -u

log() { echo "[screenguard-a11y] $*"; }

# 1) Allow Flatpak apps to talk to the AT-SPI accessibility bus. Covers all current
#    and future Flatpaks (system + user installs).
for name in org.a11y.Bus org.a11y.atspi.Registry org.a11y.atspi; do
  if command -v flatpak >/dev/null 2>&1; then
    flatpak override --system --talk-name="$name" 2>/dev/null \
      && log "granted system flatpak a11y: $name" || true
  fi
done

# 2) Enable user-level permissions and copy GNOME extension for installing user
REAL_USER="${SUDO_USER:-$(logname 2>/dev/null || true)}"
if [ -n "${REAL_USER:-}" ] && [ "$REAL_USER" != "root" ]; then
  if command -v flatpak >/dev/null 2>&1; then
    for name in org.a11y.Bus org.a11y.atspi.Registry org.a11y.atspi; do
      sudo -u "$REAL_USER" flatpak override --user --talk-name="$name" 2>/dev/null \
        && log "granted user($REAL_USER) flatpak a11y: $name" || true
    done
  fi

  if command -v gsettings >/dev/null 2>&1; then
    sudo -u "$REAL_USER" gsettings set org.gnome.desktop.interface toolkit-accessibility true 2>/dev/null \
      && log "set user($REAL_USER) toolkit-accessibility=true" || true
  fi

  USER_HOME=$(eval echo "~$REAL_USER")
  EXT_DIR="$USER_HOME/.local/share/gnome-shell/extensions/screenguard@screenguard.app"
  if [ ! -d "$EXT_DIR" ] && [ -d "/usr/share/gnome-shell/extensions/screenguard@screenguard.app" ]; then
    sudo -u "$REAL_USER" mkdir -p "$EXT_DIR"
    sudo -u "$REAL_USER" cp -r /usr/share/gnome-shell/extensions/screenguard@screenguard.app/* "$EXT_DIR/" 2>/dev/null || true
    log "installed ScreenGuard GNOME extension for user $REAL_USER"
  fi
  sudo -u "$REAL_USER" gnome-extensions enable screenguard@screenguard.app 2>/dev/null || true
fi

# 3) Enable and start the systemd user daemon for all active desktop user sessions
for udir in /run/user/[0-9]*; do
  [ -d "$udir" ] || continue
  uid=$(basename "$udir")
  [ "$uid" -ge 1000 ] 2>/dev/null || continue
  uname=$(id -nu "$uid" 2>/dev/null || true)
  [ -n "$uname" ] || continue

  sudo -u "$uname" XDG_RUNTIME_DIR="/run/user/$uid" DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$uid/bus" \
    systemctl --user daemon-reload 2>/dev/null || true
  sudo -u "$uname" XDG_RUNTIME_DIR="/run/user/$uid" DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$uid/bus" \
    systemctl --user enable --now screenguard.service 2>/dev/null \
    && log "enabled and started screenguard.service for user $uname (UID: $uid)" || true

  sudo -u "$uname" gnome-extensions enable screenguard@screenguard.app 2>/dev/null || true
done

# Clean up any legacy root global symlinks that prevent user-level disablement
rm -f /etc/systemd/user/default.target.wants/screenguard.service 2>/dev/null || true
rm -f /etc/systemd/user/graphical-session.target.wants/screenguard.service 2>/dev/null || true

# 4) Enable toolkit-accessibility system-wide via a dconf system database
mkdir -p /etc/dconf/db/local.d
cat > /etc/dconf/db/local.d/00-screenguard <<'EOF'
[org/gnome/desktop/interface]
toolkit-accessibility=true
EOF
if command -v dconf >/dev/null 2>&1; then
  dconf update && log "set toolkit-accessibility=true (system-wide)" || true
fi

log "done. ScreenGuard extension, tracking daemon, and Flatpak permissions configured."
log "Ready to use! Open 'ScreenGuard' from your application menu."
