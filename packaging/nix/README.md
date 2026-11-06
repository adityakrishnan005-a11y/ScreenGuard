# Nixpkgs — packaging guide (Flutter app, following the Saber model)

ScreenGuard is a Flutter desktop app, and nixpkgs is the only major
from-source package ecosystem that has a packaged Flutter SDK. The in-tree
reference implementation is Saber:

- `pkgs/by-name/sa/saber/package.nix` (`flutter.buildFlutterApplication`)

`packaging/nix/package.nix` mirrors that shape. Before a real PR, do:

## 1. Generate the two metadata JSONs (from the repo root)

```sh
# pubspec.lock.json — same trick Saber uses (yq from nixpkgs)
yq eval --output-format=json --prettyPrint pubspec.lock > packaging/nix/pubspec.lock.json

# git-hashes.json — helper shipped inside nixpkgs' dart package
dart.fetchGitHashesScript --input packaging/nix/pubspec.lock.json --output packaging/nix/git-hashes.json
```

## 2. Fill the source hash

`src` uses the **repo source tree at the tag** (not the release bundle), which
is what `fetchFromGitHub` downloads. Compute its hash on any machine — no Nix
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

Fix whatever the build complains about. Expect iteration on:

- the `postBuild` hook (compiling `src/*.c` helpers inside the derivation —
  verify whether `buildFlutterApplication` runs `postBuild`, else switch to
  `overrideAttrs`)
- runtime interpreter/lib paths (`active_window_helper.py` needs pyatspi)
- the `flutter344` pin — choose the newest Flutter in nixpkgs at PR time

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
