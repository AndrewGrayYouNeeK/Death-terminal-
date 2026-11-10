#!/usr/bin/env bash
# Fill version and sha256 placeholders for the store manifests.
#
#   packaging/update-manifests.sh <version> <SHA256SUMS>
#
# Writes packaging/dist/. Does not modify the templates, does not create a
# tag, and does not publish a GitHub Release. Download URLs stay
# https://example.invalid/pending-release until someone edits the dist copy
# after the files actually exist.
#
# SHA256SUMS is the file `zig build release` writes (lines of
# "<sha256>  <filename>"). A token @@SHA256:name@@ must match a filename.
# @@SHA256?:name@@ is optional: a missing source tarball becomes SKIP.
set -euo pipefail

if [ "${1:-}" = "" ] || [ "${2:-}" = "" ]; then
  echo "usage: packaging/update-manifests.sh <version> <SHA256SUMS>" >&2
  exit 2
fi

VERSION=$1
SUMS=$(readlink -f "$2")
ROOT=$(cd "$(dirname "$0")/.." && pwd)
OUT="$ROOT/packaging/dist"

if [ ! -f "$SUMS" ]; then
  echo "SHA256SUMS not found: $SUMS" >&2
  exit 2
fi

rm -rf "$OUT"
mkdir -p "$OUT"

python3 - "$ROOT" "$OUT" "$VERSION" "$SUMS" <<'PY'
import pathlib, re, sys
root, out, version, sums_path = sys.argv[1:5]
hashes = {}
for line in pathlib.Path(sums_path).read_text().splitlines():
    parts = line.split()
    if len(parts) >= 2 and re.fullmatch(r"[0-9a-fA-F]{64}", parts[0]):
        hashes[parts[1]] = parts[0].lower()

templates = [
    "packaging/macos/deathterminal-cask.rb",
    "packaging/macos/deathterminal.rb",
    "packaging/windows/winget/DeathTerminal.DeathTerminal.yaml",
    "packaging/windows/winget/DeathTerminal.DeathTerminal.installer.yaml",
    "packaging/windows/winget/DeathTerminal.DeathTerminal.locale.en-US.yaml",
    "packaging/scoop/deathterminal.json",
    "packaging/aur/PKGBUILD",
    "packaging/flatpak/org.youneek.DeathTerminal.yml",
]
required_missing = []
optional_missing = []
for rel in templates:
    text = (pathlib.Path(root) / rel).read_text()
    text = text.replace("@@VERSION@@", version)
    def repl(m, opt=False):
        name = m.group(1)
        if name in hashes:
            return hashes[name]
        (optional_missing if opt else required_missing).append(name)
        return "SKIP" if opt else m.group(0)
    text = re.sub(r"@@SHA256\?:([^@]+)@@", lambda m: repl(m, True), text)
    text = re.sub(r"@@SHA256:([^@]+)@@", lambda m: repl(m, False), text)
    dest = pathlib.Path(out) / rel
    dest.parent.mkdir(parents=True, exist_ok=True)
    dest.write_text(text)
    if "@@" in text and not required_missing:
        print(f"unfilled placeholder in {rel}", file=sys.stderr)
        sys.exit(2)

note = pathlib.Path(out) / "README.txt"
note.write_text(
    "Filled by packaging/update-manifests.sh. URLs are still\n"
    "https://example.invalid/pending-release. Replace those after the\n"
    "files exist. This script does not create a tag or a GitHub Release.\n"
)
print(f"wrote {out}", flush=True)
if optional_missing:
    print("optional hash not in SHA256SUMS (left as SKIP):", flush=True)
    for name in optional_missing:
        print(f"  {name}", flush=True)
if required_missing:
    print("missing from SHA256SUMS:", file=sys.stderr)
    for name in dict.fromkeys(required_missing):
        print(f"  {name}", file=sys.stderr)
    sys.exit(1)
PY
