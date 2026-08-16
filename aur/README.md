# Arch User Repository (AUR) Publishing Guide

Two AUR package recipes are prepared:

1. **`screenguard-bin`**: Downloads pre-compiled release binary (fast install for Arch users).
2. **`screenguard-git`**: Compiles ScreenGuard from source.

## How to Submit to AUR

### 1. SSH Key Setup
Add your SSH public key to your [AUR Account](https://aur.archlinux.org/).

### 2. Submit `screenguard-bin` (recommended — pre-built)
```bash
git clone ssh://aur@aur.archlinux.org/screenguard-bin.git
cd screenguard-bin
cp /path/to/screenguard/aur/screenguard-bin/PKGBUILD .
makepkg --printsrcinfo > .SRCINFO
git add PKGBUILD .SRCINFO
git commit -m "Initial release v0.1.0"
git push origin master
```

### 3. Submit `screenguard-git` (builds from source)
```bash
git clone ssh://aur@aur.archlinux.org/screenguard-git.git
cd screenguard-git
cp /path/to/screenguard/aur/screenguard-git/PKGBUILD .
makepkg --printsrcinfo > .SRCINFO
git add PKGBUILD .SRCINFO
git commit -m "Initial release v0.1.0"
git push origin master
```

## Install (for users)

```bash
# Pre-built binary (recommended)
yay -S screenguard-bin
# or
paru -S screenguard-bin

# Build from source
yay -S screenguard-git
# or
paru -S screenguard-git
```

## Updating AUR Packages

When a new release is published:
1. Update `pkgver` in the PKGBUILD
2. Run `makepkg --printsrcinfo > .SRCINFO`
3. Commit and push
