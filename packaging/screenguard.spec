Name:           screenguard
Version:        0.1.0
Release:        1%{?dist}
Summary:        Digital Wellbeing for Linux — Screen time tracking, daily app limits & focus mode
License:        GPLv3
URL:            https://github.com/adityakrishnan005-a11y/ScreenGuard
Source0:        %{url}/releases/download/v%{version}/screenguard-%{version}-x86_64.tar.gz

BuildArch:      x86_64
Requires:       xdotool
Requires:       gtk3
Requires:       sqlite
Requires:       gnome-shell

%description
ScreenGuard is an open-source, local-first screen-time tracker and app-limit
tool for Linux desktops. It provides per-app time tracking, a Flutter dashboard
with daily/weekly breakdowns, daily app-limit lockouts, and a Focus/Pomodoro
timer. Works on GNOME Wayland (via a bundled Shell extension) and X11.

%prep
%setup -q -n screenguard

%install
# Main bundle
install -d %{buildroot}/opt/screenguard
cp -r * %{buildroot}/opt/screenguard/

# Binaries
install -d %{buildroot}/usr/bin
ln -s /opt/screenguard/screenguard %{buildroot}/usr/bin/screenguard
ln -s /opt/screenguard/screenguard-daemon %{buildroot}/usr/bin/screenguard-daemon

# Systemd user service
install -Dm644 linux/screenguard.service %{buildroot}/usr/lib/systemd/user/screenguard.service

# Desktop entry
install -Dm644 linux/screenguard.desktop %{buildroot}/usr/share/applications/screenguard.desktop

# GNOME Shell extension
install -d %{buildroot}/usr/share/gnome-shell/extensions/screenguard@screenguard.app
install -Dm644 extension/metadata.json %{buildroot}/usr/share/gnome-shell/extensions/screenguard@screenguard.app/metadata.json
install -Dm755 extension/extension.js %{buildroot}/usr/share/gnome-shell/extensions/screenguard@screenguard.app/extension.js

%files
%license LICENSE
%doc README.md
/opt/screenguard
/usr/bin/screenguard
/usr/bin/screenguard-daemon
/usr/lib/systemd/user/screenguard.service
/usr/share/applications/screenguard.desktop
/usr/share/gnome-shell/extensions/screenguard@screenguard.app/

%post
echo ""
echo "ScreenGuard installed!"
echo "  1. Enable the service: systemctl --user enable --now screenguard.service"
echo "  2. Enable the GNOME extension (Extensions app or: gnome-extensions enable screenguard@screenguard.app)"
echo "  3. Log out and back in for the extension to load."
echo ""

%changelog
* Sat Aug 16 2025 Aditya Krishnan <aditya.krishnan005@gmail.com> - 0.1.0-1
- Initial release
