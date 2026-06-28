Name:           screenguard
Version:        0.1.0
Release:        1%{?dist}
Summary:        Digital Wellbeing for Linux — Screen Time Tracking, Daily App Limits & Focus Mode
License:        GPL-3.0-or-later
URL:            https://github.com/adityakrishnan005-a11y/ScreenGuard
ExclusiveArch:  x86_64

BuildRequires:  systemd-rpm-macros
Requires:       xdotool
Requires:       xorg-x11-utils
Requires:       python3
Requires:       python3-pyatspi
Requires:       gtk3
Requires:       sqlite-libs

%global debug_package %{nil}

%description
ScreenGuard is an open-source, privacy-first Digital Wellbeing application for Linux.
It provides per-app daily screen time limits with lockout screens, an interactive
weekly dashboard with 30-day history, and a Focus Mode / Pomodoro timer with
automatic distraction app blocking. Data is stored 100%% locally in SQLite.
Supports GNOME Wayland (via D-Bus Shell Extension) and all X11 desktops (EWMH).

%prep
# Pre-built binaries are shipped directly from the release archive.
# No compilation needed.

%build
# Nothing to build - binary release

%install
# Install pre-built bundle from the release tarball located at dist/
install -d %{buildroot}%{_prefix}/opt/screenguard
cp -r %{_sourcedir}/bundle/* %{buildroot}%{_prefix}/opt/screenguard/

install -d %{buildroot}%{_bindir}
ln -sf /opt/screenguard/screenguard %{buildroot}%{_bindir}/screenguard
install -Dm755 %{_sourcedir}/bundle/screenguard-daemon %{buildroot}%{_bindir}/screenguard-daemon

install -Dm644 %{_sourcedir}/screenguard.service %{buildroot}%{_userunitdir}/screenguard.service
install -Dm644 %{_sourcedir}/screenguard.desktop %{buildroot}%{_datadir}/applications/screenguard.desktop
install -Dm755 %{_sourcedir}/active_window_helper.py %{buildroot}%{_datadir}/screenguard/active_window_helper.py

%files
%license LICENSE
%{_prefix}/opt/screenguard/
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
