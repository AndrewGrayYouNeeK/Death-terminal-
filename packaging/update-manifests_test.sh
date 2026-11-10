#!/usr/bin/env bash
# Exercise packaging/update-manifests.sh against a copy of the templates.
# Does not publish anything and does not modify the working tree.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
SRC="$ROOT/packaging"

if grep -R -n "releases/download" \
  "$SRC/homebrew" "$SRC/winget" "$SRC/scoop" "$SRC/flatpak" --include='*.rb' --include='*.yaml' --include='*.yml' --include='*.json' --include='*.xml'
then
  echo "templates must not point at a GitHub Release download URL" >&2
  exit 1
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/packaging"
cp "$SRC/update-manifests.sh" "$TMP/packaging/"
cp -a "$SRC/homebrew" "$SRC/winget" "$SRC/scoop" "$SRC/flatpak" "$TMP/packaging/"

VER=9.9.9
ARM=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
INTEL=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
LINUX=cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc
WIN=dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd
SUMS="$TMP/SHA256SUMS"
cat >"$SUMS" <<EOF
$ARM  DeathTerminal-$VER-aarch64.dmg
$INTEL  DeathTerminal-$VER-x86_64.dmg
$LINUX  deathterminal-$VER-x86_64-linux.tar.gz
$WIN *deathterminal-$VER-x86_64-windows.zip
eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee  unrelated.txt
EOF

before=$(find "$TMP/packaging" -type f -print0 | sort -z | xargs -0 sha256sum)
if bash "$TMP/packaging/update-manifests.sh" "1.2.3" "$SUMS"; then
  echo "missing artifacts should fail" >&2
  exit 1
fi
after=$(find "$TMP/packaging" -type f -print0 | sort -z | xargs -0 sha256sum)
if [ "$before" != "$after" ]; then
  echo "a failed run wrote manifests" >&2
  exit 1
fi

if bash "$TMP/packaging/update-manifests.sh" "not a version" "$SUMS"; then
  echo "bad version should fail" >&2
  exit 1
fi

bash "$TMP/packaging/update-manifests.sh" "$VER" "$SUMS"

python3 - "$TMP/packaging" "$VER" "$ARM" "$INTEL" "$LINUX" "$WIN" <<'PY'
import json
import pathlib
import sys

root, ver, arm, intel, linux, win = sys.argv[1:]
root = pathlib.Path(root)
base = "https://github.com/AndrewGrayYouNeeK/Death-terminal-/releases/download/v" + ver

cask = (root / "homebrew/Casks/deathterminal.rb").read_text()
assert f'version "{ver}"' in cask
assert f'sha256 arm:   "{arm}"' in cask
assert f'intel: "{intel}"' in cask
assert "v#{version}/DeathTerminal-#{version}-#{arch}.dmg" in cask
assert "__" not in cask

formula = (root / "homebrew/Formula/deathterminal.rb").read_text()
assert f'sha256 "{linux}"' in formula
assert base + f"/deathterminal-{ver}-x86_64-linux.tar.gz" in formula
assert "version \"" not in formula

installer = (root / "winget/DeathTerminal.DeathTerminal.installer.yaml").read_text()
assert f'PackageVersion: "{ver}"' in installer
assert base + f"/deathterminal-{ver}-x86_64-windows.zip" in installer
assert f'InstallerSha256: "{win}"' in installer
assert f"deathterminal-{ver}-x86_64-windows\\deathterminal.exe" in installer

for rel in (
    "winget/DeathTerminal.DeathTerminal.yaml",
    "winget/DeathTerminal.DeathTerminal.locale.en-US.yaml",
):
    text = (root / rel).read_text()
    assert f'PackageVersion: "{ver}"' in text
    assert "releases/download" not in text

scoop = json.loads((root / "scoop/deathterminal.json").read_text())
assert scoop["version"] == ver
assert scoop["architecture"]["64bit"]["hash"] == win
assert scoop["architecture"]["64bit"]["url"] == base + f"/deathterminal-{ver}-x86_64-windows.zip"
assert scoop["architecture"]["64bit"]["extract_dir"] == f"deathterminal-{ver}-x86_64-windows"

flatpak = (root / "flatpak/org.youneek.DeathTerminal.yml").read_text()
assert f"deathterminal-{ver}-x86_64-linux/bin/deathterminal" in flatpak
assert f"sha256: {linux}" in flatpak
assert base + f"/deathterminal-{ver}-x86_64-linux.tar.gz" in flatpak

meta = (root / "flatpak/org.youneek.DeathTerminal.metainfo.xml").read_text()
assert f'version="{ver}"' in meta
assert "__" not in meta

for path in root.rglob("*"):
    if path.is_file() and path.suffix != ".png":
        text = path.read_text(encoding="utf-8", errors="strict")
        if "__" in text and path.name != "update-manifests.sh":
            raise SystemExit(f"placeholder left in {path}")
print("update-manifests ok")
PY

# A second run must refuse instead of rewriting hashes.
if bash "$TMP/packaging/update-manifests.sh" "$VER" "$SUMS"; then
  echo "second run should fail" >&2
  exit 1
fi

echo "update-manifests_test passed"
