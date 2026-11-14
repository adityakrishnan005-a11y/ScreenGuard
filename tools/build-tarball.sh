#!/usr/bin/env bash
# Build the ScreenGuard release tarball.
# Usage: ./tools/build-tarball.sh <version>
#   e.g. ./tools/build-tarball.sh 0.1.1.beta3
#
# IMPORTANT: <version> must use DOTS, not tildes (0.1.1.beta3, never 0.1.1~beta3).
# The tilde form is the Debian/RPM *package* version (correct in nfpm yamls for
# upgrade sorting), but GitHub release *asset filenames* must match the install
# URLs in the release notes exactly — a mismatch causes 404s on `dnf install`
# / `apt install` / `wget` (seen in v0.1.1-beta.3).
#
# Output: dist/screenguard-<version>-x86_64.tar.gz containing the Flutter
# release bundle + screenguard-daemon + tools/install.sh at its root.
set -euo pipefail

VERSION="${1:?Usage: $0 <version>  (e.g. $0 0.1.1.beta3)}"
if [[ "$VERSION" == *"~"* ]]; then
  echo "ERROR: version '$VERSION' contains '~'. Use dots for tarball filenames (e.g. 0.1.1.beta3)." >&2
  exit 1
fi

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUNDLE="$REPO_ROOT/build/linux/x64/release/bundle"
STAGE="$(mktemp -d)"
OUT="$REPO_ROOT/dist/screenguard-${VERSION}-x86_64.tar.gz"

need() { command -v "$1" >/dev/null 2>&1 || { echo "ERROR: missing required tool: $1" >&2; exit 1; }; }
need flutter; need dart; need tar

CC_BIN="cc"; command -v cc >/dev/null 2>&1 || CC_BIN="gcc"

echo "[tarball] building Flutter release bundle..."
(cd "$REPO_ROOT" && flutter build linux --release)

echo "[tarball] compiling background daemon..."
dart compile exe "$REPO_ROOT/bin/daemon.dart" -o "$BUNDLE/screenguard-daemon"

echo "[tarball] compiling digiwelld (front door + supervisor)..."
if command -v "$CC_BIN" >/dev/null 2>&1; then
  $CC_BIN -O2 -Wall -Wextra -o "$BUNDLE/digiwelld" "$REPO_ROOT/src/digiwelld.c" \
    && echo "[tarball] digiwelld compiled ($(du -h "$BUNDLE/digiwelld" | cut -f1))" \
    || echo "[tarball] WARNING: digiwelld build failed — continuing without it"
else
  echo "[tarball] WARNING: no C compiler — skipping digiwelld (install gcc or clang)"
fi

echo "[tarball] compiling digiwelld session worker..."
if command -v "$CC_BIN" >/dev/null 2>&1; then
  $CC_BIN -O2 -Wall -Wextra -std=c99 -o "$BUNDLE/digiwelld-session" "$REPO_ROOT/src/session.c" \
    && echo "[tarball] session worker compiled ($(du -h "$BUNDLE/digiwelld-session" | cut -f1))" \
    || echo "[tarball] WARNING: session worker build failed — continuing without it"
else
  echo "[tarball] WARNING: no C compiler — skipping digiwelld-session (install gcc or clang)"
fi

echo "[tarball] compiling digiwelld usage worker..."
if command -v "$CC_BIN" >/dev/null 2>&1; then
  $CC_BIN -O2 -Wall -Wextra -std=c99 -o "$BUNDLE/digiwelld-usage" "$REPO_ROOT/src/usage.c" -lsqlite3 \
    && echo "[tarball] usage worker compiled ($(du -h "$BUNDLE/digiwelld-usage" | cut -f1))" \
    || echo "[tarball] WARNING: usage worker build failed — continuing without it"
else
  echo "[tarball] WARNING: no C compiler — skipping digiwelld-usage (install gcc or clang)"
fi

echo "[tarball] compiling digiwelld policy worker..."
if command -v "$CC_BIN" >/dev/null 2>&1; then
  $CC_BIN -O2 -Wall -Wextra -std=c99 -o "$BUNDLE/digiwelld-policy" "$REPO_ROOT/src/policy.c" -lsqlite3 \
    && echo "[tarball] policy worker compiled ($(du -h "$BUNDLE/digiwelld-policy" | cut -f1))" \
    || echo "[tarball] WARNING: policy worker build failed — continuing without it"
else
  echo "[tarball] WARNING: no C compiler — skipping digiwelld-policy (install gcc or clang)"
fi

echo "[tarball] compiling digiwelld store worker..."
if command -v "$CC_BIN" >/dev/null 2>&1; then
  $CC_BIN -O2 -Wall -Wextra -std=c99 -o "$BUNDLE/digiwelld-store" "$REPO_ROOT/src/store.c" -lsqlite3 \
    && echo "[tarball] store worker compiled ($(du -h "$BUNDLE/digiwelld-store" | cut -f1))" \
    || echo "[tarball] WARNING: store worker build failed — continuing without it"
else
  echo "[tarball] WARNING: no C compiler — skipping digiwelld-store (install gcc or clang)"
fi

echo "[tarball] compiling C notification helper..."
if pkg-config --exists gio-2.0 2>/dev/null; then
  $CC_BIN -O2 -Wall -Wextra $(pkg-config --cflags --libs gio-2.0) -o "$BUNDLE/screenguard-notify" "$REPO_ROOT/src/notify.c" \
    && echo "[tarball] notification helper compiled ($(du -h "$BUNDLE/screenguard-notify" | cut -f1))" \
    || echo "[tarball] WARNING: notification helper build failed"
fi

echo "[tarball] compiling C process killer..."
if command -v cc >/dev/null 2>&1 || command -v gcc >/dev/null 2>&1; then
  CC_BIN="cc"; command -v cc >/dev/null 2>&1 || CC_BIN="gcc"
  $CC_BIN -O2 -Wall -Wextra -std=c99 -o "$BUNDLE/screenguard-killer" "$REPO_ROOT/src/killer.c" \
    && echo "[tarball] process killer compiled ($(du -h "$BUNDLE/screenguard-killer" | cut -f1))" \
    || echo "[tarball] WARNING: process killer build failed — continuing without it"
else
  echo "[tarball] WARNING: no C compiler — skipping process killer (install gcc or clang)"
fi

echo "[tarball] staging..."
cp -a "$BUNDLE/." "$STAGE/"
cp -a "$REPO_ROOT/tools/install.sh" "$STAGE/install.sh"
chmod +x "$STAGE/install.sh"
cp -a "$REPO_ROOT/tools/migrate.sh" "$STAGE/migrate.sh"
chmod +x "$STAGE/migrate.sh"
[ -x "$STAGE/screenguard" ] || { echo "ERROR: $STAGE/screenguard missing after build" >&2; exit 1; }
[ -x "$STAGE/screenguard-daemon" ] || { echo "ERROR: $STAGE/screenguard-daemon missing after build" >&2; exit 1; }

echo "[tarball] packing $OUT ..."
mkdir -p "$REPO_ROOT/dist"
tar -czf "$OUT" -C "$STAGE" .
rm -rf "$STAGE"

echo "[tarball] contents:"
tar -tzf "$OUT" | head -n 30
echo "[tarball] done: $OUT"
echo "[tarball] upload this file to the GitHub release WITHOUT renaming it,"
echo "[tarball] and use its exact filename in the release-notes install commands."
