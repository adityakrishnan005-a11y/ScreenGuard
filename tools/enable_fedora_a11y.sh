#!/usr/bin/env bash
# Enable AT-SPI accessibility for sandboxed (Flatpak) apps on Fedora / GNOME Wayland
# so ScreenGuard can track them. This is the "authenticator" rule that removes the
# sandbox block: Flatpak apps are denied the AT-SPI bus by default, which is exactly
# why ScreenGuard reported them as "unknown". Idempotent and safe to re-run.
set -u

log() { echo "[screenguard-a11y] $*"; }

# 1) Allow Flatpak apps to talk to the AT-SPI accessibility bus. Covers all current
#    and future Flatpaks (system + user installs). Try the known bus names; the
#    exact one depends on the AT-SPI version, so we grant all three defensively.
for name in org.a11y.Bus org.a11y.atspi.Registry org.a11y.atspi; do
  if command -v flatpak >/dev/null 2>&1; then
    flatpak override --system --talk-name="$name" 2>/dev/null \
      && log "granted system flatpak a11y: $name" || true
  fi
done

# 2) Same for the installing user (covers user-installed Flatpaks).
REAL_USER="${SUDO_USER:-$(logname 2>/dev/null)}"
if [ -n "${REAL_USER:-}" ] && [ "$REAL_USER" != "root" ] && command -v flatpak >/dev/null 2>&1; then
  for name in org.a11y.Bus org.a11y.atspi.Registry org.a11y.atspi; do
    sudo -u "$REAL_USER" flatpak override --user --talk-name="$name" 2>/dev/null \
      && log "granted user($REAL_USER) flatpak a11y: $name" || true
  done

  # Per-user toolkit-accessibility: the system dconf DB isn't always picked up by a
  # live GNOME session, so set it on the user directly as well (GTK/Qt read it).
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

# 3) Enable toolkit-accessibility system-wide via a dconf system database so every
#    user's apps build their accessibility tree (no per-user gsettings fragility).
mkdir -p /etc/dconf/db/local.d
cat > /etc/dconf/db/local.d/00-screenguard <<'EOF'
[org/gnome/desktop/interface]
toolkit-accessibility=true
EOF
if command -v dconf >/dev/null 2>&1; then
  dconf update && log "set toolkit-accessibility=true (system-wide)" || true
fi

log "done. ScreenGuard extension and Flatpak tracking configured."
log "Note: already-running apps pick up AT-SPI on their next focus / relaunch."
