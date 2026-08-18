Name:           screenguard
Version:        0.1.0
Release:        1%{?dist}
Summary:        Digital Wellbeing for Linux — Screen Time Tracking, Daily App Limits & Focus Mode
License:        GPL-3.0-or-later
URL:            https://github.com/adityakrishnan005-a11y/ScreenGuard

# Pre-built release bundle (Flutter + Dart daemon binary + resources)
Source0:        https://github.com/adityakrishnan005-a11y/ScreenGuard/releases/download/v%{version}/screenguard-%{version}-x86_64.tar.gz

ExclusiveArch:  x86_64

BuildRequires:  systemd-rpm-macros
Requires:       xdotool
Requires:       xprop
Requires:       python3
Requires:       python3-pyatspi
Requires:       gtk3
Requires:       sqlite-libs

# Flutter bundles its own shared libs — disable stripping and provides checks
%global debug_package %{nil}
%global __os_install_post %{nil}

%description
ScreenGuard is an open-source, privacy-first Digital Wellbeing application for Linux.
It provides per-app daily screen time limits with lockout screens, an interactive
weekly dashboard with 30-day history, and a Focus Mode / Pomodoro timer with
automatic distraction app blocking. Data is stored 100%% locally in SQLite.
Supports GNOME Wayland (via D-Bus Shell Extension) and all X11 desktops (EWMH).

%prep
%setup -q -n screenguard

%build
# Nothing to build — binary release

%install
# Main application bundle → /opt/screenguard
install -d %{buildroot}/opt/screenguard
cp -a screenguard screenguard-daemon data lib %{buildroot}/opt/screenguard/

# Symlinks in PATH
install -d %{buildroot}%{_bindir}
ln -sf /opt/screenguard/screenguard %{buildroot}%{_bindir}/screenguard
ln -sf /opt/screenguard/screenguard-daemon %{buildroot}%{_bindir}/screenguard-daemon

# App icon
install -Dm644 linux/resources/icon.png %{buildroot}%{_datadir}/icons/hicolor/256x256/apps/screenguard.png

# systemd user service
install -Dm644 linux/screenguard.service %{buildroot}%{_userunitdir}/screenguard.service

# .desktop launcher
install -Dm644 linux/screenguard.desktop %{buildroot}%{_datadir}/applications/screenguard.desktop

# Helper scripts
install -Dm755 bin/active_window_helper.py %{buildroot}%{_datadir}/screenguard/active_window_helper.py
install -Dm755 tools/enable_fedora_a11y.sh %{buildroot}%{_datadir}/screenguard/enable_fedora_a11y.sh

# GNOME Shell extension
install -d %{buildroot}%{_datadir}/gnome-shell/extensions/screenguard@screenguard.app
install -Dm644 extension/metadata.json %{buildroot}%{_datadir}/gnome-shell/extensions/screenguard@screenguard.app/metadata.json
install -Dm755 extension/extension.js %{buildroot}%{_datadir}/gnome-shell/extensions/screenguard@screenguard.app/extension.js

%files
%license LICENSE
%doc README.md
/opt/screenguard/
%{_bindir}/screenguard
%{_bindir}/screenguard-daemon
%{_userunitdir}/screenguard.service
%{_datadir}/applications/screenguard.desktop
%{_datadir}/icons/hicolor/256x256/apps/screenguard.png
%{_datadir}/screenguard/
%{_datadir}/gnome-shell/extensions/screenguard@screenguard.app/

%post
%systemd_user_post screenguard.service

%preun
%systemd_user_preun screenguard.service

%changelog
* Mon Aug 17 2026 Aditya Krishnan <aditya.krishnan005@gmail.com> - 0.1.0-1
- Initial release of ScreenGuard v0.1.0
- Digital Wellbeing Dashboard with weekly charts and 30-day totals
- Per-app daily time limits with lockout screen
- Focus Mode Pomodoro timer with distraction blocker
- GNOME Wayland (D-Bus Shell Extension) and X11 (EWMH) support
