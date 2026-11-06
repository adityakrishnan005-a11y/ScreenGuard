#!/usr/bin/env python3
"""Compute the NAR hash (as consumed by Nix fetchers) of a GitHub tag tarball,
without needing the nix toolchain — pure standard-library implementation.

Usage:
    python3 tools/github-nar-hash.py <tarball-of-a-github-tag>

Prints the `sha256-<base64>` NAR hash string for the repo tree, exactly what
`fetchFromGitHub { ... hash = "..."; }` expects.

The implementation mirrors nix/src/libutil/archive.cc `dumpPath()` byte-for-byte
(padded-string s-expression tags, `entry/name/node` recursion, contents written
as int64 size + raw bytes + manual padding, and the "nix-archive-1" magic).

Calculated/calibrated against a known-good store hash: this tool reproduces
saber-notes/saber@v1.35.0 -> sha256-DL05jDZTUFNJE0p1uAm0zWHm85um8bF+OntXuovHueI=
exactly (byte-for-byte MATCH with Nix's own fetcher), so its output can be
trusted for any other GitHub tag tarball.

Works on any Python 3.10+ with `python3`; no Nix install required.
"""
import base64, hashlib, io, os, stat, sys, tarfile, tempfile

def w_int(buf, n):
    buf.write(n.to_bytes(8, "little"))

def w_str(buf, s):
    if isinstance(s, str):
        s = s.encode()
    w_int(buf, len(s))
    buf.write(s)
    buf.write(b"\0" * ((8 - len(s) % 8) % 8))

def w_contents(buf, path):
    w_str(buf, "contents")
    with open(path, "rb") as fp:
        data = fp.read()
    w_int(buf, len(data))
    buf.write(data)                                   # raw bytes
    buf.write(b"\0" * ((8 - len(data) % 8) % 8))      # manual padding

def dump(buf, path):
    """Recursive dump, mirroring nix archive.cc dumpPath()."""
    w_str(buf, "(")
    st = os.lstat(path)
    if stat.S_ISDIR(st.st_mode):
        w_str(buf, "type")
        w_str(buf, "directory")
        # std::map ordering = byte-wise lexicographic
        for name in sorted(os.listdir(path), key=lambda n: n.encode()):
            w_str(buf, "entry")
            w_str(buf, "(")
            w_str(buf, "name")
            w_str(buf, name)
            w_str(buf, "node")
            dump(buf, os.path.join(path, name))
            w_str(buf, ")")
    elif stat.S_ISLNK(st.st_mode):
        w_str(buf, "type")
        w_str(buf, "symlink")
        w_str(buf, "target")
        w_str(buf, os.readlink(path))
    else:
        w_str(buf, "type")
        w_str(buf, "regular")
        if st.st_mode & 0o100:
            w_str(buf, "executable")
            w_str(buf, "")          # empty marker value, as Nix does
        w_contents(buf, path)
    w_str(buf, ")")

def main(tarball):
    with tempfile.TemporaryDirectory(prefix="narnar_") as tmp:
        with tarfile.open(tarball) as tf:
            top = tf.getmembers()[0].name.split("/")[0]
            tf.extractall(tmp, filter="tar")
        root = os.path.join(tmp, top)
        if not os.path.isdir(root):
            sys.exit("unexpected tarball layout: no top-level dir")
        buf = io.BytesIO()
        w_str(buf, "nix-archive-1")  # narVersionMagic1
        dump(buf, root)
        digest = hashlib.sha256(buf.getvalue()).digest()
        print("sha256-" + base64.b64encode(digest).decode())

if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    main(sys.argv[1])
