#!/usr/bin/env bash
# ScreenGuard — build from source and install in one step.
# Run from the repository root (or anywhere; it finds the repo by itself):
#
#   ./tools/build-and-install.sh [install.sh options]
#
# All extra flags are forwarded to install.sh:
#   --prefix DIR   Install to a custom prefix (default: ~/.local)
#   --system       System-wide install to /usr/local (needs sudo)
#   --yes          Non-interactive: assume "yes" to autostart prompt
#   --no-daemon    Install files only, skip autostart setup
#
# Flutter is located automatically. Override with FLUTTER_BIN env var:
#   FLUTTER_BIN=/path/to/flutter ./tools/build-and-install.sh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUNDLE="$REPO_ROOT/build/linux/x64/release/bundle"

log()  { echo "[screenguard-build] $*"; }
die()  { echo "[screenguard-build] ERROR: $*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# 1. Locate Flutter
# ---------------------------------------------------------------------------
find_flutter() {
  # Explicit override wins
  if [ -n "${FLUTTER_BIN:-}" ]; then
    [ -x "$FLUTTER_BIN" ] || die "FLUTTER_BIN='$FLUTTER_BIN' is not executable."
    echo "$FLUTTER_BIN"; return
  fi
  # Already on PATH
  if command -v flutter >/dev/null 2>&1; then
    echo "flutter"; return
  fi
  # Common locations
  for candidate in \
      "$HOME/flutter/bin/flutter" \
      "$HOME/snap/flutter/common/flutter/bin/flutter" \
      "/opt/flutter/bin/flutter" \
      "/usr/local/flutter/bin/flutter"; do
    if [ -x "$candidate" ]; then echo "$candidate"; return; fi
  done
  die "flutter not found. Install Flutter or set FLUTTER_BIN=/path/to/flutter."
}

find_dart() {
  if command -v dart >/dev/null 2>&1; then echo "dart"; return; fi
  # Dart ships inside Flutter SDK
  local flutter_bin
  flutter_bin="$(find_flutter)"
  local dart_candidate
  dart_candidate="$(dirname "$flutter_bin")/dart"
  if [ -x "$dart_candidate" ]; then echo "$dart_candidate"; return; fi
  die "dart not found. It should ship with your Flutter SDK."
}

FLUTTER="$(find_flutter)"
DART="$(find_dart)"
log "using flutter: $FLUTTER"
log "using dart:   $DART"

# ---------------------------------------------------------------------------
# 2. Build Flutter GUI
# ---------------------------------------------------------------------------
log "building Flutter release bundle..."
(cd "$REPO_ROOT" && "$FLUTTER" build linux --release)

# ---------------------------------------------------------------------------
# 3. Compile daemon
# ---------------------------------------------------------------------------
log "compiling background daemon..."
"$DART" compile exe "$REPO_ROOT/bin/daemon.dart" -o "$BUNDLE/screenguard-daemon"

# ---------------------------------------------------------------------------
# 3b. Compile C notification helper
# ---------------------------------------------------------------------------
log "compiling C notification helper..."
C_COMPILER="cc"
command -v cc >/dev/null 2>&1 || C_COMPILER="gcc"
if pkg-config --exists gio-2.0 2>/dev/null; then
  $C_COMPILER -O2 -Wall -Wextra $(pkg-config --cflags --libs gio-2.0) -o "$BUNDLE/screenguard-notify" "$REPO_ROOT/src/notify.c" \
    && log "notification helper compiled successfully" \
    || log "WARNING: notification helper compilation failed"
else
  log "WARNING: pkg-config gio-2.0 not found — skipping screenguard-notify build"
fi

# ---------------------------------------------------------------------------
# 3c. Compile C process killer (TERM -> tree KILL -> wineserver -k)
# ---------------------------------------------------------------------------
log "compiling C process killer..."
C_COMPILER="cc"
command -v cc >/dev/null 2>&1 || C_COMPILER="gcc"
if command -v "$C_COMPILER" >/dev/null 2>&1; then
  $C_COMPILER -O2 -Wall -Wextra -std=c99 -o "$BUNDLE/screenguard-killer" "$REPO_ROOT/src/killer.c" \
    && log "process killer compiled successfully" \
    || log "WARNING: process killer compilation failed (Close-app falls back to basic kill)"
else
  log "WARNING: no C compiler found — skipping screenguard-killer build (Close-app falls back to basic kill)"
fi

# ---------------------------------------------------------------------------
# 3d. Compile Cinnamon focus helper (muffin's debug D-Bus interface)
# ---------------------------------------------------------------------------
# Cinnamon hides the real focus window from the X server, so tracking there
# needs this helper. It is harmless on every other desktop: the Cinnamon
# backend only runs it when XDG_CURRENT_DESKTOP says Cinnamon.
log "compiling Cinnamon focus helper..."
C_COMPILER="cc"
command -v cc >/dev/null 2>&1 || C_COMPILER="gcc"
if command -v "$C_COMPILER" >/dev/null 2>&1 && pkg-config --exists gio-2.0 2>/dev/null; then
  $C_COMPILER -O2 -Wall -Wextra $(pkg-config --cflags --libs gio-2.0) -o "$BUNDLE/cinnamon_focus" "$REPO_ROOT/bin/cinnamon_focus.c" \
    && log "Cinnamon focus helper compiled successfully" \
    || log "WARNING: Cinnamon focus helper compilation failed (Cinnamon falls back to X11 focus)"
else
  log "WARNING: no C compiler or pkg-config gio-2.0 — skipping cinnamon_focus build"
fi

# ---------------------------------------------------------------------------
# 3e. Compile digiwelld (native front door + supervisor + crash budget)
# ---------------------------------------------------------------------------
log "compiling C supervisor..."
C_COMPILER="cc"
command -v cc >/dev/null 2>&1 || C_COMPILER="gcc"
if command -v "$C_COMPILER" >/dev/null 2>&1; then
  $C_COMPILER -O2 -Wall -Wextra -o "$BUNDLE/digiwelld" "$REPO_ROOT/src/digiwelld.c" \
    && log "digiwelld compiled successfully" \
    || log "WARNING: digiwelld compilation failed (GUI falls back to direct daemon access)"
else
  log "WARNING: no C compiler found — skipping digiwelld build"
fi

# ---------------------------------------------------------------------------
# 3f. Compile digiwelld session worker (durable session journal + recovery)
# ---------------------------------------------------------------------------
log "compiling C session worker..."
C_COMPILER="cc"
command -v cc >/dev/null 2>&1 || C_COMPILER="gcc"
if command -v "$C_COMPILER" >/dev/null 2>&1; then
  $C_COMPILER -O2 -Wall -Wextra -std=c99 -o "$BUNDLE/digiwelld-session" "$REPO_ROOT/src/session.c" \
    && log "session worker compiled successfully" \
    || log "WARNING: session worker compilation failed (Dart session memory stays authoritative)"
else
  log "WARNING: no C compiler found — skipping digiwelld-session build"
fi

# ---------------------------------------------------------------------------
# 3g. Compile digiwelld usage worker (read-only SQLite read model)
# ---------------------------------------------------------------------------
log "compiling C usage worker..."
C_COMPILER="cc"
command -v cc >/dev/null 2>&1 || C_COMPILER="gcc"
if command -v "$C_COMPILER" >/dev/null 2>&1; then
  $C_COMPILER -O2 -Wall -Wextra -std=c99 -o "$BUNDLE/digiwelld-usage" "$REPO_ROOT/src/usage.c" -lsqlite3 \
    && log "usage worker compiled successfully" \
    || log "WARNING: usage worker compilation failed (usage stays on the daemon)"
else
  log "WARNING: no C compiler found — skipping digiwelld-usage build"
fi

# ---------------------------------------------------------------------------
# 3h. Compile digiwelld policy worker (policy intent + focus state machine)
# ---------------------------------------------------------------------------
log "compiling C policy worker..."
C_COMPILER="cc"
command -v cc >/dev/null 2>&1 || C_COMPILER="gcc"
if command -v "$C_COMPILER" >/dev/null 2>&1; then
  $C_COMPILER -O2 -Wall -Wextra -std=c99 -o "$BUNDLE/digiwelld-policy" "$REPO_ROOT/src/policy.c" -lsqlite3 \
    && log "policy worker compiled successfully" \
    || log "WARNING: policy worker compilation failed (policy stays on the daemon)"
else
  log "WARNING: no C compiler found — skipping digiwelld-policy build"
fi

# ---------------------------------------------------------------------------
# 3i. Compile digiwelld store worker (single SQLite writer: sessions + events)
# ---------------------------------------------------------------------------
log "compiling C store worker..."
C_COMPILER="cc"
command -v cc >/dev/null 2>&1 || C_COMPILER="gcc"
if command -v "$C_COMPILER" >/dev/null 2>&1; then
  $C_COMPILER -O2 -Wall -Wextra -std=c99 -o "$BUNDLE/digiwelld-store" "$REPO_ROOT/src/store.c" -lsqlite3 \
    && log "store worker compiled successfully" \
    || log "WARNING: store worker compilation failed (sessions stay on the daemon)"
else
  log "WARNING: no C compiler found — skipping digiwelld-store build"
fi

# ---------------------------------------------------------------------------
# 4. Run install.sh from inside the bundle dir
# ---------------------------------------------------------------------------
INSTALL_SH="$REPO_ROOT/tools/install.sh"
[ -x "$INSTALL_SH" ] || die "tools/install.sh not found or not executable."

log "copying install.sh into bundle dir..."
cp "$INSTALL_SH" "$BUNDLE/install.sh"
chmod +x "$BUNDLE/install.sh"
cp "$REPO_ROOT/tools/migrate.sh" "$BUNDLE/migrate.sh"
chmod +x "$BUNDLE/migrate.sh"

log "handing off to install.sh..."
echo ""
exec "$BUNDLE/install.sh" "$@"
