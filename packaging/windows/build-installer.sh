#!/usr/bin/env bash
# NSIS installer from a staged Windows release tree.
#
#   bash packaging/windows/build-installer.sh <stage-dir> <out-dir>
#
# <stage-dir> is zig-out/release/deathterminal-<ver>-<arch>-windows
# (flat: deathterminal.exe, docs, examples). Writes
# <out-dir>/deathterminal-<ver>-<arch>-setup.exe and refreshes SHA256SUMS.
#
# Requires makensis (apt install nsis). Does not sign the installer.
set -euo pipefail

STAGE=$(cd "${1:?stage dir}" && pwd)
OUT=$(mkdir -p "${2:?out dir}" && cd "$2" && pwd)
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
NAME=$(basename "$STAGE")
base=${NAME#deathterminal-}
os=${base##*-}
rest=${base%-$os}
ARCH=${rest##*-}
VER=${rest%-$ARCH}
SETUP="$OUT/deathterminal-$VER-$ARCH-setup.exe"

if ! command -v makensis >/dev/null 2>&1; then
  echo "makensis not found. Install NSIS (apt install nsis) to build the Windows installer." >&2
  exit 1
fi

# VIProductVersion is four integers. Pre-release tails are dropped.
quad=0.0.0.0
IFS=. read -r major minor patch _ <<<"${VER%%[^0-9.]*}...."
major=${major:-0}
minor=${minor:-0}
patch=${patch:-0}
patch=${patch%%[^0-9]*}
quad="${major}.${minor}.${patch}.0"

makensis -NOCD \
  -DVERSION="$VER" \
  -DVER_QUAD="$quad" \
  -DSTAGE="$STAGE" \
  -DOUT="$SETUP" \
  -DICON="$HERE/deathterminal.ico" \
  "$HERE/nsis/deathterminal.nsi"

python3 "$ROOT/packaging/archive.py" "$OUT" "$NAME" sums >/dev/null
echo "$SETUP"
