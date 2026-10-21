#!/usr/bin/env bash
# Download the pinned official MoltenVK macOS release and print the directory
# that contains libMoltenVK.dylib and MoltenVK_icd.json.
#
#   MOLTENVK_DIR=$(bash packaging/macos/fetch-moltenvk.sh [dest])
#
# The tarball is KhronosGroup/MoltenVK MoltenVK-macos.tar. Version and sha256
# are the pin. The ICD's library_path is rewritten to ./libMoltenVK.dylib when
# it is not already that, so both files can sit together in Contents/Frameworks.
set -euo pipefail

VERSION=1.4.2
SHA256=f95765a6229cb7b915990a2890ce12ebe36a730b021545d3d52ae69ce4c4024e
URL="https://github.com/KhronosGroup/MoltenVK/releases/download/v${VERSION}/MoltenVK-macos.tar"

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
DEST=${1:-"$ROOT/packaging/.cache/MoltenVK-$VERSION"}
mkdir -p "$DEST"
TARBALL="$DEST/MoltenVK-macos.tar"
SRC="$DEST/src"

download() {
  local tmp
  tmp=$(mktemp "$DEST/download.XXXXXX")
  curl -fsSL -o "$tmp" "$URL"
  echo "$SHA256  $tmp" | sha256sum -c - >&2
  mv "$tmp" "$TARBALL"
}

if [ ! -f "$TARBALL" ] || ! echo "$SHA256  $TARBALL" | sha256sum -c - >&2; then
  download
fi

if [ ! -f "$SRC/.sha256" ] || [ "$(cat "$SRC/.sha256")" != "$SHA256" ]; then
  rm -rf "$SRC"
  mkdir -p "$SRC"
  tar -xf "$TARBALL" -C "$SRC"
  echo "$SHA256" > "$SRC/.sha256"
fi

DYLIB=""
ICD=""
while IFS= read -r f; do
  case "$f" in
    */dylib/macOS/libMoltenVK.dylib) DYLIB=$f ;;
  esac
  if [ -z "$DYLIB" ] && [ "$(basename "$f")" = "libMoltenVK.dylib" ]; then
    DYLIB=$f
  fi
done < <(find "$SRC" -type f -name libMoltenVK.dylib)
while IFS= read -r f; do
  case "$f" in
    */dylib/macOS/MoltenVK_icd.json) ICD=$f ;;
  esac
  if [ -z "$ICD" ] && [ "$(basename "$f")" = "MoltenVK_icd.json" ]; then
    ICD=$f
  fi
done < <(find "$SRC" -type f -name MoltenVK_icd.json)

if [ -z "$DYLIB" ] || [ -z "$ICD" ]; then
  echo "MoltenVK ${VERSION} archive is missing libMoltenVK.dylib or MoltenVK_icd.json" >&2
  exit 1
fi

dir=$(dirname "$DYLIB")
if [ "$(dirname "$ICD")" != "$dir" ]; then
  cp "$ICD" "$dir/MoltenVK_icd.json"
  ICD="$dir/MoltenVK_icd.json"
fi

python3 - "$ICD" <<'PY'
import json, sys
path = sys.argv[1]
with open(path) as fh:
    data = json.load(fh)
icd = data.setdefault("ICD", {})
if icd.get("library_path") != "./libMoltenVK.dylib":
    icd["library_path"] = "./libMoltenVK.dylib"
    with open(path, "w") as fh:
        json.dump(data, fh, indent=4)
        fh.write("\n")
PY

printf '%s\n' "$dir"
