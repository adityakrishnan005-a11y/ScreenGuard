# Package ScreenGuard for Nixpkgs — draft for upstream submission.
#
# Modeled on Saber (pkgs/by-name/sa/saber/package.nix), the canonical
# packaged Flutter desktop app in nixpkgs. Generated files below
# (`pubspec.lock.json`, `git-hashes.json`) must be regenerated with the
# tooling described in README-nix.md before casting a PR.
{
  lib,
  flutter344, # TODO choose the newest pinned Flutter in nixpkgs at PR time
              # (check pkgs/development/compilers/flutter/; it has been
              # flutter343/flutter344 historically)
  fetchFromGitHub,
  dart,
  autoPatchelfHook,
  gtk3,
  glib,
  xdotool,
  xprop,
  xprintidle,
  python3, # TODO the distro packages python3-pyatspi; in nix use
           # `python3.withPackages (p: [ p.pyatspi ])` (verify attr name)
  at-spi2-core,
}:

let
  version = "1.1.2";

  src = fetchFromGitHub {
    owner = "adityakrishnan005-a11y";
    repo = "ScreenGuard";
    tag = "v${version}";
    # Hash of the *source tree* at the tag (NOT the release bundle tarball).
    # Refresh with: python3 tools/github-nar-hash.py <(curl -sL \
    #   https://github.com/adityakrishnan005-a11y/ScreenGuard/archive/refs/tags/v$ver.tar.gz)
    # (calibrated against nix's own fetcher, see tool docstring).
    hash = "sha256-EwZX80LSUa1v84dAyjFdJpLEXqvi/m49tPbL2xQY/9Y=";
  };
in
flutter344.buildFlutterApplication {
  pname = "screenguard";
  inherit version src;

  gitHashes = lib.importJSON ./git-hashes.json;
  pubspecLock = lib.importJSON ./pubspec.lock.json;

  nativeBuildInputs = [ autoPatchelfHook ];

  # Runtime dependencies of the Flutter GTK bundle and the tracking helpers.
  buildInputs = [
    gtk3
    glib
    at-spi2-core
  ];

  runtimeDependencies = [
    xdotool
    xprop
    xprintidle
    python3
    at-spi2-core
  ];

  # TODO verify this hook exists in buildFlutterApplication; if it doesn't,
  # compile via overrideAttrs postBuild / separate derivation.
  postBuild = ''
    # Native helper binaries (C) that ship alongside the Flutter bundle.
    cc src/watchdog.c -O2 -o build/linux/x64/release/bundle/screenguard-watchdog
    cc src/notify.c -O2 -o build/linux/x64/release/bundle/screenguard-notify
    cc src/killer.c -O2 -o build/linux/x64/release/bundle/screenguard-killer
  '';

  postInstall = ''
    install -Dm0644 linux/screenguard.desktop $out/share/applications/screenguard.desktop
    install -Dm0644 packaging/org.screenguard.ScreenGuard.appdata.xml -t $out/share/metainfo
    install -Dm0644 assets/icons/scalable/screenguard.svg $out/share/icons/hicolor/scalable/apps/screenguard.svg
    install -Dm0644 assets/icons/256x256/screenguard.png $out/share/icons/hicolor/256x256/apps/screenguard.png

    # systemd user service + preset (systemd user units ship from $out in nixpkgs)
    install -Dm0644 linux/screenguard.service $out/lib/systemd/user/screenguard.service
    install -Dm0644 linux/50-screenguard.preset $out/lib/systemd/user-preset/50-screenguard.preset

    # Helper scripts used by the daemon
    install -Dm0755 bin/active_window_helper.py $out/share/screenguard/active_window_helper.py
    install -Dm0755 tools/enable_fedora_a11y.sh $out/share/screenguard/enable_fedora_a11y.sh
    install -Dm0755 tools/migrate.sh $out/share/screenguard/migrate.sh

    # PATH symlinks for the daemon and C helpers, mirroring distro packaging
    install -d $out/bin
    for bin in screenguard-daemon screenguard-watchdog screenguard-notify screenguard-killer; do
      ln -s $out/app/screenguard/$bin $out/bin/$bin
    done
  '';

  meta = {
    description = "Digital Wellbeing for Linux — screen time tracking, daily app limits & focus mode";
    homepage = "https://github.com/adityakrishnan005-a11y/ScreenGuard";
    mainProgram = "screenguard";
    license = lib.licenses.gpl3Only;
    maintainers = with lib.maintainers; [ ];
    platforms = [
      "x86_64-linux"
      "aarch64-linux"
    ];
  };
}
