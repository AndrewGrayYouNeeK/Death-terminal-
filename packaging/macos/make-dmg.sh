#!/usr/bin/env bash
# Build a DeathTerminal disk image from DeathTerminal.app.
#
#   bash packaging/macos/make-dmg.sh <DeathTerminal.app> <out.dmg>
#
# macOS: hdiutil writes a compressed UDZO image.
# Linux: genisoimage writes an HFS hybrid, then libdmg-hfsplus (downloaded
# into packaging/.cache, GPL-3, not linked into the app) wraps it as a
# zlib UDIF .dmg. Finder can open that image. Developer ID signing and
# notarization are the release job's, when the Apple secrets are set
# (packaging/SIGNING.md).
set -euo pipefail

APP=$(cd "${1:?app bundle}" && pwd)
OUT=${2:?output dmg}
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
CACHE="$ROOT/packaging/.cache"
# fanquake/libdmg-hfsplus @ 1cc791e (dmg tool only). Output archives are
# not GPL works; the tool is a build-time downloader, same idea as nfpm.
DMG_REV=1cc791e4173da9cb0b0cc16c5a1aaa25d5eb5efa

STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
# ditto keeps the code signature; cp -a is the Linux fallback.
if command -v ditto >/dev/null 2>&1; then
  ditto "$APP" "$STAGE/DeathTerminal.app"
else
  cp -a "$APP" "$STAGE/DeathTerminal.app"
fi
ln -s /Applications "$STAGE/Applications"

if command -v hdiutil >/dev/null 2>&1; then
  rm -f "$OUT"
  hdiutil create -volname DeathTerminal -srcfolder "$STAGE" -ov -format UDZO "$OUT"
  echo "$OUT"
  exit 0
fi

if ! command -v genisoimage >/dev/null 2>&1; then
  echo "need hdiutil (macOS) or genisoimage (Linux) to build a DMG" >&2
  exit 1
fi

DMG_BIN="$CACHE/dmg-$DMG_REV"
if [ ! -x "$DMG_BIN" ]; then
  # GitHub's archive extracts to libdmg-hfsplus-<full sha>.
  src="$CACHE/libdmg-hfsplus-$DMG_REV"
  if [ ! -f "$src/dmg/dmg.c" ]; then
    mkdir -p "$CACHE"
    tarball="$CACHE/libdmg-hfsplus-$DMG_REV.tar.gz"
    curl -fsSL -o "$tarball" "https://github.com/fanquake/libdmg-hfsplus/archive/${DMG_REV}.tar.gz"
    tar -xzf "$tarball" -C "$CACHE"
  fi
  cc -O2 -I"$src/includes" -o "$DMG_BIN" "$src/dmg/"*.c -lz
  chmod +x "$DMG_BIN"
fi

ISO="$STAGE/raw.iso"
# cdrkit's genisoimage rejects -apple together with -hfs. -hfs is the
# hybrid Finder can mount; Rock Ridge keeps the Applications symlink.
# -l keeps names like deathterminal-gui intact (without it, ISO9660
# collapses them onto an 8.3 name and one of the two binaries is renamed).
genisoimage -D -l -V DeathTerminal -no-pad -r -hfs -hfs-volid DeathTerminal -o "$ISO" "$STAGE"
rm -f "$OUT"
"$DMG_BIN" "$ISO" "$OUT"
echo "$OUT"
