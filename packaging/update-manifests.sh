#!/usr/bin/env bash
# Fill version, sha256, and download URLs in the ready-to-submit manifests.
#
#   packaging/update-manifests.sh <version> <path-to-SHA256SUMS>
#
# Does not create a git tag or a GitHub Release. The manifests in git use
# placeholders and do not point at a release. Run this only when that
# version's artifacts are actually published, then submit the result.
#
# SHA256SUMS is the file produced with the release (sha256sum format,
# "<64 hex>  <filename>"). Basenames are matched. Required names:
#
#   DeathTerminal-<version>-aarch64.dmg
#   DeathTerminal-<version>-x86_64.dmg
#   deathterminal-<version>-x86_64-linux.tar.gz
#   deathterminal-<version>-x86_64-windows.zip
#
# Missing names abort before any manifest is written.
set -euo pipefail

if [ "$#" -ne 2 ]; then
  echo "usage: packaging/update-manifests.sh <version> <path-to-SHA256SUMS>" >&2
  exit 2
fi

VERSION=$1
SUMS=$2
HERE=$(cd "$(dirname "$0")" && pwd)

exec python3 - "$HERE" "$VERSION" "$SUMS" <<'PY'
import re
import sys
from datetime import datetime, timezone
from pathlib import Path

root = Path(sys.argv[1])
version = sys.argv[2]
sums_path = Path(sys.argv[3])

if not re.fullmatch(r"[0-9A-Za-z][0-9A-Za-z._+-]*", version) or "__" in version:
    raise SystemExit(f"refusing version {version!r}")
if not sums_path.is_file():
    raise SystemExit(f"SHA256SUMS not found: {sums_path}")

assets = {
    "MACOS_DMG_AARCH64": f"DeathTerminal-{version}-aarch64.dmg",
    "MACOS_DMG_X86_64": f"DeathTerminal-{version}-x86_64.dmg",
    "LINUX_TARGZ_X86_64": f"deathterminal-{version}-x86_64-linux.tar.gz",
    "WINDOWS_ZIP_X86_64": f"deathterminal-{version}-x86_64-windows.zip",
}

found = {}
for raw in sums_path.read_text(encoding="utf-8").splitlines():
    line = raw.strip()
    if not line or line.startswith("#"):
        continue
    parts = line.split()
    if len(parts) < 2:
        raise SystemExit(f"bad SHA256SUMS line: {raw!r}")
    digest, name = parts[0], parts[-1].lstrip("*")
    name = name.replace("\\", "/").rsplit("/", 1)[-1]
    if not re.fullmatch(r"[0-9a-fA-F]{64}", digest):
        raise SystemExit(f"bad sha256 for {name}: {digest!r}")
    digest = digest.lower()
    previous = found.get(name)
    if previous is not None and previous != digest:
        raise SystemExit(f"conflicting sha256 for {name}")
    found[name] = digest

missing = [name for name in assets.values() if name not in found]
if missing:
    raise SystemExit(
        "SHA256SUMS is missing:\n  "
        + "\n  ".join(missing)
        + "\nNo manifest was written."
    )
hashes = {key: found[name] for key, name in assets.items()}

base = "https://github.com/AndrewGrayYouNeeK/Death-terminal-/releases/download/v" + version
urls = {
    "URL_MACOS_DMG": (
        "https://github.com/AndrewGrayYouNeeK/Death-terminal-/releases/download/"
        "v#{version}/DeathTerminal-#{version}-#{arch}.dmg"
    ),
    "URL_LINUX_TARGZ_X86_64": base + "/" + assets["LINUX_TARGZ_X86_64"],
    "URL_WINDOWS_ZIP_X86_64": base + "/" + assets["WINDOWS_ZIP_X86_64"],
}

replacements = {
    "__VERSION__": version,
    "__RELEASE_DATE__": datetime.now(timezone.utc).strftime("%Y-%m-%d"),
}
for key, digest in hashes.items():
    replacements[f"__SHA256_{key}__"] = digest
for key, url in urls.items():
    replacements[f"__{key}__"] = url

files = (
    "homebrew/Casks/deathterminal.rb",
    "homebrew/Formula/deathterminal.rb",
    "winget/DeathTerminal.DeathTerminal.yaml",
    "winget/DeathTerminal.DeathTerminal.installer.yaml",
    "winget/DeathTerminal.DeathTerminal.locale.en-US.yaml",
    "scoop/deathterminal.json",
    "flatpak/org.youneek.DeathTerminal.yml",
    "flatpak/org.youneek.DeathTerminal.metainfo.xml",
)

required_tokens = {
    "homebrew/Casks/deathterminal.rb": (
        "__VERSION__",
        "__SHA256_MACOS_DMG_AARCH64__",
        "__SHA256_MACOS_DMG_X86_64__",
        "__URL_MACOS_DMG__",
    ),
    "homebrew/Formula/deathterminal.rb": (
        "__SHA256_LINUX_TARGZ_X86_64__",
        "__URL_LINUX_TARGZ_X86_64__",
    ),
    "winget/DeathTerminal.DeathTerminal.yaml": ("__VERSION__",),
    "winget/DeathTerminal.DeathTerminal.installer.yaml": (
        "__VERSION__",
        "__SHA256_WINDOWS_ZIP_X86_64__",
        "__URL_WINDOWS_ZIP_X86_64__",
    ),
    "winget/DeathTerminal.DeathTerminal.locale.en-US.yaml": ("__VERSION__",),
    "scoop/deathterminal.json": (
        "__VERSION__",
        "__SHA256_WINDOWS_ZIP_X86_64__",
        "__URL_WINDOWS_ZIP_X86_64__",
    ),
    "flatpak/org.youneek.DeathTerminal.yml": (
        "__VERSION__",
        "__SHA256_LINUX_TARGZ_X86_64__",
        "__URL_LINUX_TARGZ_X86_64__",
    ),
    "flatpak/org.youneek.DeathTerminal.metainfo.xml": (
        "__VERSION__",
        "__RELEASE_DATE__",
    ),
}

originals = {}
for rel in files:
    path = root / rel
    if not path.is_file():
        raise SystemExit(f"missing manifest {path}")
    text = path.read_text(encoding="utf-8")
    absent = [token for token in required_tokens[rel] if token not in text]
    if absent:
        raise SystemExit(
            f"{rel} is missing {', '.join(absent)}. "
            "Refusing to write; the manifests may already be filled."
        )
    originals[rel] = text

token_order = sorted(replacements, key=len, reverse=True)
filled = {}
for rel, text in originals.items():
    for token in token_order:
        text = text.replace(token, replacements[token])
    leftover = sorted(set(re.findall(r"__[A-Z0-9_]+__", text)))
    if leftover:
        raise SystemExit(f"{rel} still has placeholders: {', '.join(leftover)}")
    filled[rel] = text

cask = "homebrew/Casks/deathterminal.rb"
aligned = (
    f'  sha256 arm:   "{hashes["MACOS_DMG_AARCH64"]}",\n'
    f'         intel: "{hashes["MACOS_DMG_X86_64"]}"'
)
cask_text, count = re.subn(
    r'  sha256 arm:   "[0-9a-f]{64}",\n         intel: "[0-9a-f]{64}"',
    aligned,
    filled[cask],
    count=1,
)
if count != 1:
    raise SystemExit("could not align the cask sha256 stanza")
filled[cask] = cask_text

for rel, text in filled.items():
    path = root / rel
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text(text, encoding="utf-8")
    tmp.replace(path)
    print(f"updated {rel}")

print(f"version {version}")
print(f"release date {replacements['__RELEASE_DATE__']} (UTC, edit the metainfo if the release day differs)")
for key, name in assets.items():
    print(f"{hashes[key]}  {name}")
print("No tag or GitHub Release was created. Submit these files only after that release exists.")
PY
