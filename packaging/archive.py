#!/usr/bin/env python3
"""Archive a staged release directory and update SHA256SUMS.

usage: archive.py <release-dir> <name> <zip|gztar|sums>
Creates <release-dir>/<name>.zip or .tar.gz containing <name>/...
("sums" only refreshes SHA256SUMS).
"""
import hashlib, os, shutil, sys

root, name, fmt = sys.argv[1], sys.argv[2], sys.argv[3]
base = os.path.join(root, name)
path = root if fmt == 'sums' else shutil.make_archive(base, fmt, root_dir=root, base_dir=name)

def sha(p):
    h = hashlib.sha256()
    with open(p, 'rb') as f:
        for chunk in iter(lambda: f.read(1 << 20), b''):
            h.update(chunk)
    return h.hexdigest()

sums = os.path.join(root, 'SHA256SUMS')
lines = {}
if os.path.exists(sums):
    for ln in open(sums):
        parts = ln.split()
        if len(parts) == 2:
            lines[parts[1]] = parts[0]
for f in sorted(os.listdir(root)):
    p = os.path.join(root, f)
    if os.path.isfile(p) and f != 'SHA256SUMS' and not f.endswith('.part'):
        lines[f] = sha(p)
with open(sums, 'w') as out:
    for f in sorted(lines):
        if os.path.exists(os.path.join(root, f)):
            out.write(f'{lines[f]}  {f}\n')
print(path)
