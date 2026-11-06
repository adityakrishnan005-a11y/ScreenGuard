# Nixpkgs — packaging guide (Flutter app, following the Saber model)

ScreenGuard is a Flutter desktop app, and nixpkgs is the only major
from-source package ecosystem that has a packaged Flutter SDK. The in-tree
reference implementation is Saber:

- `pkgs/by-name/sa/saber/package.nix` (`flutter344.buildFlutterApplication`)

`packaging/nix/package.nix` mirrors that shape.

## Mechanics — verified against nixpkgs master sources (no local Nix needed)

- `postBuild` **is** a real hook: the linux `buildPhase` in
  `pkgs/development/compilers/flutter/build-support/build-flutter-application.nix`
  ends with `runHook postBuild` (after `flutter build linux`).
- The linux `installPhase` moves the bundle to `$out/app/$pname` and
  auto-symlinks every top-level executable into `$out/bin`. Do **not** create
  those symlinks manually — they collide.
- `dartFixupHook` (`pkgs/build-support/dart/build-dart-application/hooks/`)
  wraps every `$out/bin/*` entry: `runtimeDependencies` becomes
  `LD_LIBRARY_PATH`, and `extraWrapProgramArgs` is passed to `wrapProgram`.
  Helper tools the daemon shells out to (`xdotool`, `xprop`, `xprintidle`,
  python) therefore go on **PATH** via `extraWrapProgramArgs` +
  `lib.makeBinPath`, *not* in `runtimeDependencies`.
- The daemon is a plain `dart compile exe bin/daemon.dart` (not part of the
  flutter build; see `tools/build-tarball.sh`). `buildFlutterApplication` sets
  `dontDartBuild`, but `dart-config-hook` still assembles the pub2nix package
  config, so `package:screenguard/*` imports resolve offline in `postBuild`.
- `bin/active_window_helper.py` is located via the running binary's directory
  first (`gnome_wayland_backend.dart`), so installing it into
  `$out/app/screenguard/` next to the daemon works.
- Newer Flutters than 344 exist in the trunk (`versions/`: 3_29..3_47) but
  Saber deliberately stays on 344 for the linux build; revisit only if ofBorg
  forces a change.

## 1. Metadata JSONs — already generated

`pubspec.lock.json` (44 packages) and `git-hashes.json` (`{}`, no git deps)
are committed. Regenerate after dependency changes:

```sh
yq eval --output-format=json --prettyPrint pubspec.lock > packaging/nix/pubspec.lock.json
```

## 2. Source hash

`src` uses the **repo source tree at the tag** (not the release bundle), which
is what `fetchFromGitHub` downloads. Compute it on any machine — no Nix
required:

```sh
curl -sL https://github.com/adityakrishnan005-a11y/ScreenGuard/archive/refs/tags/v1.1.2.tar.gz -o /tmp/sg.tar.gz
python3 tools/github-nar-hash.py /tmp/sg.tar.gz
# -> sha256-EwZX80LSUa1v84dAyjFdJpLEXqvi/m49tPbL2xQY/9Y=
```

`tools/github-nar-hash.py` reproduces Nix's fetchFromGitHub serialization
byte-for-byte (calibrated against the saber-notes/saber store hash), so its
output is trustworthy for future version bumps. Double-check on a Nix box
anytime with `nix flake prefetch`.

## 3. Local-test build inside a nixpkgs checkout

```sh
git clone https://github.com/NixOS/nixpkgs && cd nixpkgs
mkdir -p pkgs/by-name/sc/screenguard
cp ~/screenguard/packaging/nix/{package.nix,pubspec.lock.json,git-hashes.json} pkgs/by-name/sc/screenguard/
nix-build -A screenguard   # pkgs/by-name auto-includes the package
```

Expected iteration points (what ofBorg would reveal):

- the manual `dart compile exe` in `postBuild` (extent of the flutter-dart
  wrapper's tolerance for bare `dart compile`)
- runtime interpreter/lib paths
- the `flutter344` pin

## 4. PR to nixpkgs

Requirements (from nixpkgs policy):

- branch per PR (`screenguard`), commit message: `screenguard: init at 1.1.2`
- ofBorg builds it for x86_64 + aarch64 automatically
- run `nixpkgs-review` before requesting review, describe test setup in the PR body
- consider adding yourself under `maintainers` later if you want
- after merge, every Nix user can install with `nix profile install nixpkgs#screenguard`

## Notes

- No GUI "software store" in NixOS; reach is `search.nixos.org` + the nixpkgs
  catalog. This is a credibility + tiling-WM-audience play, not a store play.
- Keep the metainfo/desktop files exactly as in the repo — they are shared
  with all other packaging formats on purpose.
