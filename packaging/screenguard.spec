Name:           screenguard
Version:        0.1.1
Release:        2%{?dist}
Summary:        Digital Wellbeing for Linux - Screen Time Tracking, Daily App Limits & Focus Mode
License:        GPL-3.0-or-later
URL:            https://github.com/adityakrishnan005-a11y/ScreenGuard

# Pre-built release bundle (Flutter + Dart daemon binary + resources)
Source0:        https://github.com/adityakrishnan005-a11y/ScreenGuard/releases/download/v%{version}/screenguard-%{version}-x86_64.tar.gz

# Supporting files, pinned to the release tag
Source1:        https://raw.githubusercontent.com/adityakrishnan005-a11y/ScreenGuard/v%{version}/linux/screenguard.service
Source2:        https://raw.githubusercontent.com/adityakrishnan005-a11y/ScreenGuard/v%{version}/linux/screenguard.desktop
Source3:        https://raw.githubusercontent.com/adityakrishnan005-a11y/ScreenGuard/v%{version}/linux/screenguard-autostart.desktop
Source4:        https://raw.githubusercontent.com/adityakrishnan005-a11y/ScreenGuard/v%{version}/linux/resources/icon.png
Source5:        https://raw.githubusercontent.com/adityakrishnan005-a11y/ScreenGuard/v%{version}/bin/active_window_helper.py
Source6:        https://raw.githubusercontent.com/adityakrishnan005-a11y/ScreenGuard/v%{version}/tools/enable_fedora_a11y.sh
Source7:        https://raw.githubusercontent.com/adityakrishnan005-a11y/ScreenGuard/v%{version}/extension/metadata.json
Source8:        https://raw.githubusercontent.com/adityakrishnan005-a11y/ScreenGuard/v%{version}/extension/extension.js
Source9:        https://raw.githubusercontent.com/adityakrishnan005-a11y/ScreenGuard/v%{version}/linux/50-screenguard.preset
Source10:       https://raw.githubusercontent.com/adityakrishnan005-a11y/ScreenGuard/v%{version}/tools/migrate.sh
Source11:       https://raw.githubusercontent.com/adityakrishnan005-a11y/ScreenGuard/v%{version}/LICENSE
Source12:       https://raw.githubusercontent.com/adityakrishnan005-a11y/ScreenGuard/v%{version}/README.md

ExclusiveArch:  x86_64

BuildRequires:  systemd-rpm-macros
Requires:       xdotool
Requires:       xprop
Requires:       python3
Requires:       python3-pyatspi
Requires:       gtk3
Requires:       sqlite-libs

# Flutter bundles its own shared libs - disable stripping and provides checks
%global debug_package %{nil}
%global __os_install_post %{nil}

%description
ScreenGuard is an open-source, privacy-first Digital Wellbeing application for Linux.
It provides per-app daily screen time limits with lockout screens, an interactive
weekly dashboard with 30-day history, and a Focus Mode / Pomodoro timer with
automatic distraction app blocking. Data is stored 100%% locally in SQLite.
Supports GNOME Wayland (via D-Bus Shell Extension) and all X11 desktops (EWMH).

%prep
mkdir -p bundle
tar -xzf %{SOURCE0} -C bundle

%build
# Nothing to build - binary release

%install
# Main application bundle -> /opt/screenguard
install -d %{buildroot}/opt/screenguard
cp -a bundle/. %{buildroot}/opt/screenguard/

# Symlinks in PATH
install -d %{buildroot}%{_bindir}
for bin in screenguard screenguard-daemon screenguard-watchdog screenguard-notify screenguard-killer; do
  ln -sf /opt/screenguard/$bin %{buildroot}%{_bindir}/$bin
done

# App icon
install -Dm644 %{SOURCE4} %{buildroot}%{_datadir}/icons/hicolor/256x256/apps/screenguard.png

# systemd user service and preset
install -Dm644 %{SOURCE1} %{buildroot}%{_userunitdir}/screenguard.service
install -Dm644 %{SOURCE9} %{buildroot}%{_userpresetdir}/50-screenguard.preset

# Desktop launcher and autostart
install -Dm644 %{SOURCE2} %{buildroot}%{_datadir}/applications/screenguard.desktop
install -Dm644 %{SOURCE3} %{buildroot}%{_sysconfdir}/xdg/autostart/screenguard-autostart.desktop

# Helper scripts
install -Dm755 %{SOURCE5} %{buildroot}%{_datadir}/screenguard/active_window_helper.py
install -Dm755 %{SOURCE6} %{buildroot}%{_datadir}/screenguard/enable_fedora_a11y.sh
install -Dm755 %{SOURCE10} %{buildroot}%{_datadir}/screenguard/migrate.sh

# GNOME Shell extension
install -d %{buildroot}%{_datadir}/gnome-shell/extensions/screenguard@screenguard.app
install -Dm644 %{SOURCE7} %{buildroot}%{_datadir}/gnome-shell/extensions/screenguard@screenguard.app/metadata.json
install -Dm755 %{SOURCE8} %{buildroot}%{_datadir}/gnome-shell/extensions/screenguard@screenguard.app/extension.js

# License and documentation
install -Dm644 %{SOURCE11} LICENSE
install -Dm644 %{SOURCE12} README.md

%files
%license LICENSE
%doc README.md
/opt/screenguard/
%{_bindir}/screenguard
%{_bindir}/screenguard-daemon
%{_bindir}/screenguard-watchdog
%{_bindir}/screenguard-notify
%{_bindir}/screenguard-killer
%{_userunitdir}/screenguard.service
%{_userpresetdir}/50-screenguard.preset
%{_datadir}/applications/screenguard.desktop
%{_sysconfdir}/xdg/autostart/screenguard-autostart.desktop
%{_datadir}/icons/hicolor/256x256/apps/screenguard.png
%{_datadir}/screenguard/
%{_datadir}/gnome-shell/extensions/screenguard@screenguard.app/

%post
%systemd_user_post screenguard.service
/usr/share/screenguard/enable_fedora_a11y.sh || :

%preun
%systemd_user_preun screenguard.service

%changelog
* Sun Oct 25 2026 Aditya Krishnan <aditya.krishnan005@gmail.com> - 0.1.1-2
- Fix in-app update download path corruption ($tmpDir Directory.toString())
- Fix update checker version identity using AppVersion.current
- Fix periodic check scheduler ignoring 'never' frequency
- Dismiss update badge in UI upon successful package install
* Sun Oct 25 2026 Aditya Krishnan <aditya.krishnan005@gmail.com> - 0.1.1-1
- v0.1.1 stable: reliable daily active-install telemetry with dev/CI exclusion
- Clean shutdown on SIGTERM, SIGINT and SIGHUP; no false crash reports on logout
- Installer restart-loop fix and hardened update handoff
- Focus Mode distraction-list cache fix
- Opt-out anonymous diagnostics disclosed in README, Settings and wiki
- Version-gated in-app feedback requests; orphaned sessions closed on next start
- Fix the Copr spec so it installs the release bundle, helpers, extension and service
* Mon Aug 17 2026 Aditya Krishnan <aditya.krishnan005@gmail.com> - 0.1.0-1
- Initial release of ScreenGuard v0.1.0
- Digital Wellbeing Dashboard with weekly charts and 30-day totals
- Per-app daily time limits with lockout screen
- Focus Mode Pomodoro timer with distraction blocker
- GNOME Wayland (D-Bus Shell Extension) and X11 (EWMH) support
