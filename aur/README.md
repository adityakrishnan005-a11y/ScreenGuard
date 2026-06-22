# Arch User Repository (AUR) Publishing Guide 📦

We have prepared two AUR package recipes:

1. **`screenguard-bin`**: Downloads pre-compiled release binary archive (fast install for Arch users).
2. **`screenguard-git`**: Compiles ScreenGuard directly from GitHub source.

---

## How to Submit `screenguard-bin` to AUR:

1. **SSH Key Setup**: Make sure your SSH public key is added to your [AUR Account](https://aur.archlinux.org/).
2. **Clone Empty AUR Repo**:
   ```bash
   git clone ssh://aur@aur.archlinux.org/screenguard-bin.git
   cd screenguard-bin
   ```
3. **Copy PKGBUILD**:
   ```bash
   cp /path/to/screenguard/aur/screenguard-bin/PKGBUILD .
   ```
4. **Generate `.SRCINFO`**:
   ```bash
   makepkg --printsrcinfo > .SRCINFO
   ```
5. **Commit & Push**:
   ```bash
   git add PKGBUILD .SRCINFO
   git commit -m "Initial release v0.1.0"
   git push origin master
   ```

Now any Arch/Manjaro/EndeavourOS user can install ScreenGuard with:
```bash
yay -S screenguard-bin
# or
paru -S screenguard-bin
```
