Name:           screenguard
Version:        0.1.0
Release:        1%{?dist}
Summary:        Digital Wellbeing for Linux — Screen Time Tracking, Daily App Limits & Focus Mode
License:        GPL-3.0-or-later
URL:            https://github.com/adityakrishnan005-a11y/ScreenGuard

# Pre-built release bundle (Flutter + Dart daemon binary)
Source0:        https://github.com/adityakrishnan005-a11y/ScreenGuard/releases/download/v%{version}/screenguard-%{version}-x86_64.tar.gz

# Supporting files — pulled from git repo raw URLs
Source1:        https://raw.githubusercontent.com/adityakrishnan005-a11y/ScreenGuard/main/linux/screenguard.service
Source2:        https://raw.githubusercontent.com/adityakrishnan005-a11y/ScreenGuard/main/linux/screenguard.desktop
Source3:        https://raw.githubusercontent.com/adityakrishnan005-a11y/ScreenGuard/main/bin/active_window_helper.py

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
mkdir -p bundle
tar -xzf %{SOURCE0} -C bundle

%build
# Nothing to build — binary release

%install
# Main application bundle → /opt/screenguard
install -d %{buildroot}/opt/screenguard
cp -r bundle/* %{buildroot}/opt/screenguard/

# Symlink GUI binary into PATH
install -d %{buildroot}%{_bindir}
ln -sf /opt/screenguard/screenguard %{buildroot}%{_bindir}/screenguard

# Daemon binary
install -Dm755 bundle/screenguard-daemon %{buildroot}%{_bindir}/screenguard-daemon

# systemd user service
install -Dm644 %{SOURCE1} %{buildroot}%{_userunitdir}/screenguard.service

# .desktop launcher
install -Dm644 %{SOURCE2} %{buildroot}%{_datadir}/applications/screenguard.desktop

# Active window helper script
install -Dm755 %{SOURCE3} %{buildroot}%{_datadir}/screenguard/active_window_helper.py

%files
/opt/screenguard/
%{_bindir}/screenguard
%{_bindir}/screenguard-daemon
%{_userunitdir}/screenguard.service
%{_datadir}/applications/screenguard.desktop
%{_datadir}/screenguard/active_window_helper.py

%post
%systemd_user_post screenguard.service

%preun
%systemd_user_preun screenguard.service

%changelog
* Sat Aug 16 2026 Aditya Krishnan <aditya.krishnan005@gmail.com> - 0.1.0-1
- Initial release of ScreenGuard v0.1.0
- Digital Wellbeing Dashboard with weekly charts and 30-day totals
- Per-app daily time limits with lockout screen
- Focus Mode Pomodoro timer with distraction blocker
- GNOME Wayland (D-Bus Shell Extension) and X11 (EWMH) support
