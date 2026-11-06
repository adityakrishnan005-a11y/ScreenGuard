# openSUSE Build Service (OBS) — publishing guide

Once your OBS account exists (https://build.opensuse.org — free signup, no
domain verification), publish the package from `packaging/obs/`:

## 1. Create the package

In OBS web UI or CLI:

```sh
osc checkout home:YOUR_USERNAME/screenguard   # osc creates it as needed
```

Or purely on the web first: *Your Home → Create package → id `screenguard`*.

Copy every file from `packaging/obs/` on top:

```sh
cp packaging/obs/* ~/obs/home:YOUR_USERNAME/screenguard/
```

## 2. Fetch the tarball via the `_service`

The `_service` file pins the release tarball.

```sh
cd ~/obs/home:YOUR_USERNAME/screenguard
osc service runall        # downloads screenguard-1.1.2-x86_64.tar.gz
osc add / osc addremove   # stage newly downloaded files
osc commit -m "screenguard 1.1.2"
```

> When you tag a new release: bump `Version:` in the spec, bump the URL in
> `_service`, re-run `osc service runall`, commit.

## 3. Add build repositories

OBS web UI: project → *Repositories → Add*. Recommended set:

- `openSUSE:Tumbleweed` (standard)
- `openSUSE:Leap:16.0`
- `openSUSE:Leap:15.6`

Watch the first build; fix the two **TODO** items in the spec:

- the exact openSUSE name of the AT-SPI python bindings
- any rpmlint message `screenguard-rpmlintrc` did not already cover

## 4. After green builds

- package page becomes instantly one-click-installable at
  `software.opensuse.org/download.html?project=home:YOUR_USERNAME&package=screenguard`
- once stable, consider requesting inclusion into `devel:tools` (community
  devel project) — that is the upstream path to openSUSE:Factory
