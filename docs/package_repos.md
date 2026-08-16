# Package Repositories Setup (Private Notes)

## 1. APT Personal Repo (GitHub Pages)

**What:** Signed APT repository at `https://adityakrishnan005-a11y.github.io/screenguard`. Users add it once, then `apt install/update` works natively.

### Setup

1. **Generate GPG key:**
   ```
   gpg --full-generate-key   # RSA 4096, no passphrase for CI
   gpg --export --armor YOUR_KEY_ID > key.asc
   ```

2. **Add GitHub Secrets:**
   - `GPG_PRIVATE_KEY`: export with `gpg --export --armor YOUR_KEY_ID`
   - `GPG_PASSPHRASE`: empty if no passphrase

3. **Create GitHub Actions workflow** `.github/workflows/apt-repo.yml`:
   ```yaml
   name: Update APT Repo
   on:
     release:
       types: [published]
   jobs:
     build:
       runs-on: ubuntu-latest
       permissions:
         contents: write
       steps:
         - uses: actions/checkout@v4
         - name: Download .deb from release
           run: gh release download ${{ github.event.release.tag_name }} -p '*.deb' -D debs/
           env:
             GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
         - name: Import GPG key
           run: echo "${{ secrets.GPG_PRIVATE_KEY }}" | gpg --batch --import
         - name: Generate APT metadata
           run: |
             mkdir -p repo/dists/apt/main/binary-amd64
             cp debs/*.deb repo/dists/apt/main/binary-amd64/
             cd repo
             apt-ftparchive release dists/apt > dists/apt/Release
             gpg --batch --yes --passphrase "" -abs -o dists/apt/Release.gpg dists/apt/Release
             gpg --batch --yes --passphrase "" --clearsign -o dists/apt/InRelease dists/apt/Release
             apt-ftparchive contents dists/apt/main/binary-amd64/ > dists/apt/main/binary-amd64/Packages
             gzip -k -f dists/apt/main/binary-amd64/Packages
             gpg --export --armor > repo/key.asc
         - name: Deploy to gh-pages
           uses: peaceiris/actions-gh-pages@v4
           with:
             github_token: ${{ secrets.GITHUB_TOKEN }}
             publish_dir: repo
   ```

4. **Enable GitHub Pages:** Settings → Pages → Source: `gh-pages` branch.

### User one-liner

```bash
# One-time setup
curl -fsSL https://adityakrishnan005-a11y.github.io/screenguard/key.asc | sudo gpg --dearmor -o /etc/apt/keyrings/screenguard.gpg
echo "deb [signed-by=/etc/apt/keyrings/screenguard.gpg] https://adityakrishnan005-a11y.github.io/screenguard apt main" | sudo tee /etc/apt/sources.list.d/screenguard.list
sudo apt update && sudo apt install screenguard

# Updates
sudo apt update && sudo apt upgrade screenguard
```

---

## 2. Fedora Copr

**What:** Fedora's built-in community repo system (like Ubuntu's PPA). Hosted by Fedora, free, high trust.

### Setup

1. **Create Fedora account** at `https://accounts.fedoraproject.org/`

2. **Create a Copr repo** at `https://copr.fedoraproject.org/` → "New Repository" → name it `screenguard`

3. **Write an RPM spec file** (`packaging/screenguard.spec`):
   ```
   Name:           screenguard
   Version:        0.1.0
   Release:        1%{?dist}
   Summary:        Digital Wellbeing for Linux
   License:        GPLv3
   URL:            https://github.com/adityakrishnan005-a11y/ScreenGuard
   Source0:        %{name}-%{version}.tar.gz

   %description
   ScreenGuard — screen time tracking, daily app limits, and focus mode for Linux.

   %install
   mkdir -p %{buildroot}/opt/screenguard
   cp -r * %{buildroot}/opt/screenguard/
   mkdir -p %{buildroot}/usr/bin
   ln -s /opt/screenguard/screenguard %{buildroot}/usr/bin/screenguard
   ...

   %files
   /opt/screenguard
   /usr/bin/screenguard
   ...
   ```

4. **Create source tarball** + upload:
   ```
   tar czf screenguard-0.1.0.tar.gz --transform 's,.,screenguard-0.1.0,' .
   copr-cli build TheTechAmbivert/screenguard screenguard-0.1.0.tar.gz
   ```

5. **Or use the web UI** — upload spec + tarball directly.

### User one-liner

```bash
# One-time setup
sudo dnf copr enable TheTechAmbivert/screenguard

# Install/update
sudo dnf install screenguard

# Updates
sudo dnf update screenguard
```

---

## 3. Official Repos (future roadmap)

- **Debian:** File an ITP bug on `bugs.debian.org`, get a Debian Maintainer to sponsor. Takes 3-6 months.
- **Ubuntu:** Flows from Debian automatically, or request via Ubuntu's `udd-import`.
- **Fedora:** Submit Package Review on `src.fedoraproject.org`. Requires a sponsor. Takes 2-4 weeks.
- **AUR:** Already has `screenguard-bin` (documented in README).
