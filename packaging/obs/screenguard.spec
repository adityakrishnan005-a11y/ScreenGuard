# openSUSE-adapted RPM spec for the openSUSE Build Service (OBS).
#
# Differences vs the Fedora Copr spec (packaging/screenguard.spec):
#   * This file lives in an OBS package directory that also contains the
#     downloaded release tarball (fetched by `_service`, see README).
#   * openSUSE dependency names differ for the AT-SPI Python bindings —
#     see the %if block under Requires.
#   * TODO the first time you build: adjust the python3-atspi name below to
#     whatever resolves on openSUSE:Tumbleweed (check with
#     `osc shells` inside the build, or build.opensuse.org package search).

Name:              screenguard
Version:           1.1.2
Release:           1%{?dist}
Summary:           Digital Wellbeing for Linux (Screen time & Focus)
License:           GPL-3.0-or-later
URL:               https://github.com/adityakrishnan005-a11y/ScreenGuard

# The prebuilt release bundle (Flutter GUI + Dart daemon + C helpers).
# Refresh this version string (and re-run `osc service runall download_url`)
# whenever a new release is tagged.
Source0:           screenguard-%{version}-x86_64.tar.gz

# Supporting files pinned to the release tag (identical to the Copr spec)
Source1:           https://raw.githubusercontent.com/adityakrishnan005-a11y/ScreenGuard/v%{version}/linux/screenguard.service
Source2:           https://raw.githubusercontent.com/adityakrishnan005-a11y/ScreenGuard/v%{version}/linux/screenguard.desktop
Source3:           https://raw.githubusercontent.com/adityakrishnan005-a11y/ScreenGuard/v%{version}/linux/screenguard-autostart.desktop
Source4:           https://raw.githubusercontent.com/adityakrishnan005-a11y/ScreenGuard/v%{version}/linux/resources/icon.png
Source5:           https://raw.githubusercontent.com/adityakrishnan005-a11y/ScreenGuard/v%{version}/bin/active_window_helper.py
Source6:           https://raw.githubusercontent.com/adityakrishnan005-a11y/ScreenGuard/v%{version}/tools/enable_fedora_a11y.sh
Source7:           https://raw.githubusercontent.com/adityakrishnan005-a11y/ScreenGuard/v%{version}/extension/metadata.json
Source8:           https://raw.githubusercontent.com/adityakrishnan005-a11y/ScreenGuard/v%{version}/extension/extension.js
Source9:           https://raw.githubusercontent.com/adityakrishnan005-a11y/ScreenGuard/v%{version}/linux/50-screenguard.preset
Source10:          https://raw.githubusercontent.com/adityakrishnan005-a11y/ScreenGuard/v%{version}/tools/migrate.sh
Source11:          https://raw.githubusercontent.com/adityakrishnan005-a11y/ScreenGuard/v%{version}/LICENSE
Source12:          https://raw.githubusercontent.com/adityakrishnan005-a11y/ScreenGuard/v%{version}/README.md
Source13:          https://raw.githubusercontent.com/adityakrishnan005-a11y/ScreenGuard/v%{version}/packaging/org.screenguard.ScreenGuard.appdata.xml

ExclusiveArch:     x86_64

BuildRequires:     systemd-rpm-macros
Requires:          xdotool
Requires:          xprop
Requires:          python3
Requires:          gtk3

%if 0%{?suse_version}
# openSUSE names differently — verify exact names on first build
Requires:          at-spi2-core
%else
Requires:          python3-pyatspi
Requires:          sqlite-libs
%endif

# Flutter bundles its own shared libraries — disable stripping and provides checks
%global debug_package %{nil}
%global __os_install_post %{nil}

%description
ScreenGuard is an open-source, privacy-first Digital Wellbeing application for Linux.
It provides per-app daily screen time limits with lockout screens, an interactive
weekly dashboard with 30-day history, and a Focus Mode / Pomodoro timer with
automatic distraction app blocking. Data is stored 100%% locally in SQLite.
Supports GNOME and KDE on Wayland (D-Bus Shell extension) and all X11 desktops (EWMH).

%prep
mkdir -p bundle
tar -xzf %{SOURCE0} -C bundle

%build
# Nothing to build — binary release bundle
:

%install
# Main application bundle -> /opt/screenguard
install -d %{buildroot}/opt/screenguard
cp -a bundle/. %{buildroot}/opt/screenguard/

# Symlinks into PATH
install -d %{buildroot}%{_bindir}
for bin in screenguard screenguard-daemon screenguard-watchdog screenguard-notify screenguard-killer; do
  ln -sf /opt/screenguard/$bin %{buildroot}%{_bindir}/$bin
done

# App icon
install -Dpm0644 %{SOURCE4} %{buildroot}%{_datadir}/icons/hicolor/256x256/apps/screenguard.png

# systemd user service and preset
install -Dpm0644 %{SOURCE1} %{buildroot}%{_userunitdir}/screenguard.service
install -Dpm0644 %{SOURCE9} %{buildroot}%{_userpresetdir}/50-screenguard.preset

# Desktop launcher and autostart
install -Dpm0644 %{SOURCE2} %{buildroot}%{_datadir}/applications/screenguard.desktop
install -Dpm0644 %{SOURCE3} %{buildroot}%{_sysconfdir}/xdg/autostart/screenguard-autostart.desktop

# AppStream metadata (GNOME Software / KDE Discover on openSUSE)
install -Dpm0644 %{SOURCE13} %{buildroot}%{_datadir}/metainfo/org.screenguard.ScreenGuard.appdata.xml

# Helper scripts
install -Dpm0755 %{SOURCE5} %{buildroot}%{_datadir}/screenguard/active_window_helper.py
install -Dpm0755 %{SOURCE6} %{buildroot}%{_datadir}/screenguard/enable_fedora_a11y.sh
install -Dpm0755 %{SOURCE10} %{buildroot}%{_datadir}/screenguard/migrate.sh

# GNOME / KDE Shell extension
install -d %{buildroot}%{_datadir}/gnome-shell/extensions/screenguard@screenguard.app
install -pm0644 %{SOURCE7} %{buildroot}%{_datadir}/gnome-shell/extensions/screenguard@screenguard.app/metadata.json
install -pm0755 %{SOURCE8} %{buildroot}%{_datadir}/gnome-shell/extensions/screenguard@screenguard.app/extension.js

# install -Dpm0644 %{SOURCE2} ... (existing install block above this comment)

# Normalize helper shebangs for rpmlint (env-script-interpreter)
sed -i '1s|^#!/usr/bin/env bash$|#!/bin/bash|' %{buildroot}%{_datadir}/screenguard/*.sh
sed -i '1s|^#!/usr/bin/env python3$|#!/usr/bin/python3|' %{buildroot}%{_datadir}/screenguard/*.py
sed -i '1s|^#!/usr/bin/env bash$|#!/bin/bash|' %{buildroot}/opt/screenguard/install.sh %{buildroot}/opt/screenguard/migrate.sh 2>/dev/null || :

# License and documentation
install -Dpm0644 %{SOURCE11} LICENSE
install -Dpm0644 %{SOURCE12} README.md

%check
: # nothing to test (pre-built release bundle)

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
%{_datadir}/metainfo/org.screenguard.ScreenGuard.appdata.xml
%{_sysconfdir}/xdg/autostart/screenguard-autostart.desktop
%dir %{_datadir}/icons/hicolor
%dir %{_datadir}/icons/hicolor/256x256
%dir %{_datadir}/icons/hicolor/256x256/apps
%{_datadir}/icons/hicolor/256x256/apps/screenguard.png
%dir %{_datadir}/gnome-shell
%dir %{_datadir}/gnome-shell/extensions
%dir %{_datadir}/gnome-shell/extensions/screenguard@screenguard.app/
%{_datadir}/gnome-shell/extensions/screenguard@screenguard.app/metadata.json
%{_datadir}/gnome-shell/extensions/screenguard@screenguard.app/extension.js
%{_datadir}/screenguard/

%post
%systemd_user_post screenguard.service
%{_datadir}/screenguard/enable_fedora_a11y.sh || :

%preun
%systemd_user_preun screenguard.service

%changelog
* Fri Nov 6 2026 Aditya Krishnan <aditya.krishnan005@gmail.com> - 1.1.2-1
- Initial OBS packaging (mirrors the Fedora Copr spec v1.1.2, + AppStream metainfo)
