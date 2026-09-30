# Contributing to ScreenGuard 🛡️

First off, thank you for considering contributing to ScreenGuard! Open-source tools for the Linux desktop thrive on community collaboration, testing, and feedback.

Whether you're fixing a bug, reporting a display-server quirk, improving documentation, or adding new packaging targets, your help is warmly welcomed.

---

## Table of Contents
1. [Code of Conduct](#code-of-conduct)
2. [How Can I Contribute?](#how-can-i-contribute)
   * [Reporting Bugs & Display Server Issues](#reporting-bugs--display-server-issues)
   * [Suggesting Features](#suggesting-features)
   * [Packaging & Distribution](#packaging--distribution)
3. [Development Setup](#development-setup)
   * [Prerequisites](#prerequisites)
   * [Building & Running the Flutter App](#building--running-the-flutter-app)
   * [Compiling the Background Daemon](#compiling-the-background-daemon)
4. [Testing & Quality Checks](#testing--quality-checks)
5. [Commit Conventions](#commit-conventions)
6. [Submitting a Pull Request](#submitting-a-pull-request)

---

## Code of Conduct

This project and everyone participating in it is governed by our [Code of Conduct](CODE_OF_CONDUCT.md). By participating, you are expected to uphold this code.

---

## How Can I Contribute?

### Reporting Bugs & Display Server Issues

Before creating a bug report, please check existing [GitHub Issues](https://github.com/adityakrishnan005-a11y/ScreenGuard/issues) to see if it has already been reported.

When creating a new issue, please use our issue templates and include:
* **Linux Distribution & Version** (e.g., Fedora 41, Ubuntu 24.04, Arch Linux).
* **Desktop Environment & Version** (e.g., GNOME 47, KDE Plasma 6.2, XFCE 4.18).
* **Display Server** (Wayland or X11 — run `echo $XDG_SESSION_TYPE`).
* **ScreenGuard Version** (e.g., `v0.1.0`, `v0.1.1-beta.4`).
* **Steps to Reproduce** and **Expected vs Actual Behavior**.
* **Logs & Proof**:
  * For daemon issues: `systemctl --user status screenguard` or running `screenguard-daemon` in a terminal.
  * For X11 window tracking/minimization issues: please attach a screenshot or screen recording showing the behavior.

### Suggesting Features

Feature requests are tracked in [GitHub Issues](https://github.com/adityakrishnan005-a11y/ScreenGuard/issues). Please describe:
* The problem or limitation you are facing.
* The proposed feature or enhancement.
* Any alternative solutions or mockups you have in mind.

### Packaging & Distribution

Help is always welcome for expanding ScreenGuard packaging to new distributions and package formats (Flatpak/Flathub, Snap, openSUSE OBS, Gentoo ebuilds, etc.). Check the `packaging/` directory for existing NFPM and spec templates.

---

## Development Setup

### Prerequisites

To build and run ScreenGuard from source, you need:
* **Flutter SDK** (3.24+ recommended with Linux desktop support enabled: `flutter config --enable-linux-desktop`)
* **Dart SDK** (included with Flutter)
* **C/C++ Build Tools**: `clang`, `cmake`, `ninja-build`, `pkg-config`
* **Development Libraries**:
  * **Debian/Ubuntu**: `sudo apt install clang cmake ninja-build pkg-config libgtk-3-dev libsqlite3-dev libayatana-appindicator3-dev xdotool x11-utils`
  * **Fedora**: `sudo dnf install clang cmake ninja-build pkgconfig gtk3-devel sqlite-devel libayatana-appindicator-gtk3-devel xdotool xprop`
  * **Arch Linux**: `sudo pacman -S clang cmake ninja pkgconf gtk3 sqlite xdotool xorg-xprop libayatana-appindicator`

### Building & Running the Flutter App

```bash
# 1. Clone the repository
git clone https://github.com/adityakrishnan005-a11y/ScreenGuard.git
cd ScreenGuard

# 2. Get Flutter dependencies
flutter pub get

# 3. Run the GUI in development mode
flutter run -d linux
```

### Compiling the Background Daemon

The background tracker service is located in `bin/daemon.dart`:

```bash
# Compile native standalone daemon binary
dart compile exe bin/daemon.dart -o build/screenguard-daemon

# Run the daemon locally for testing
./build/screenguard-daemon
```

---

## Testing & Quality Checks

Before submitting changes, ensure everything compiles cleanly and passes analyzer checks:

```bash
# Run Dart analyzer
flutter analyze

# Run unit tests
flutter test
```

---

## Commit Conventions

We follow [Conventional Commits](https://www.conventionalcommits.org/) to keep the git history clean, readable, and structured:

* `feat:` A new feature (e.g., `feat(ui): add dark theme toggle`)
* `fix:` A bug fix (e.g., `fix(daemon): prevent duplicate process lock`)
* `docs:` Documentation only changes (e.g., `docs: update installation instructions`)
* `build:` Changes that affect the build system or packaging (e.g., `build(rpm): update spec dependencies`)
* `ci:` Changes to CI configuration files and scripts (e.g., `ci: add automated repo signing`)
* `refactor:` Code changes that neither fix a bug nor add a feature

---

## Submitting a Pull Request

1. **Fork** the repository and create your branch from `main` (or `beta` for pre-release features):
   ```bash
   git checkout -b feature/my-cool-feature
   ```
2. **Make your changes** cleanly and test them on your Linux environment.
3. **Commit** your changes using conventional commit messages.
4. **Push** to your fork:
   ```bash
   git push origin feature/my-cool-feature
   ```
5. **Open a Pull Request** against the ScreenGuard repository with a clear title and description of the changes.
