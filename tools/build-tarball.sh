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

echo "[tarball] building Flutter release bundle..."
(cd "$REPO_ROOT" && flutter build linux --release)

echo "[tarball] compiling background daemon..."
dart compile exe "$REPO_ROOT/bin/daemon.dart" -o "$BUNDLE/screenguard-daemon"

echo "[tarball] staging..."
cp -a "$BUNDLE/." "$STAGE/"
cp -a "$REPO_ROOT/tools/install.sh" "$STAGE/install.sh"
chmod +x "$STAGE/install.sh"
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
