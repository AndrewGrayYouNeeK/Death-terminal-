#!/usr/bin/env bash
# Build "YouNeeK Death Terminal.app" (skeleton; UNTESTED on a real Mac).
#
#   bash packaging/macos/make-app.sh <stage-dir> <out-dir>
#
# <stage-dir> is a `zig build release -Dtarget=aarch64-macos` (or x86_64)
# tree: zig-out/release/deathterminal-<ver>-<arch>-macos. Produces
# <out-dir>/YouNeeK Death Terminal.app, DeathTerminal-<ver>-<arch>.zip and
# DeathTerminal-<ver>-<arch>.dmg (see make-dmg.sh). The zip and dmg
# filenames stay DeathTerminal-* so release asset URLs do not change.
#
# Vulkan on macOS goes through MoltenVK. If MOLTENVK_DIR is set (the release
# workflow points it at packaging/macos/fetch-moltenvk.sh), libMoltenVK.dylib
# and MoltenVK_icd.json are copied into Contents/Frameworks. The loader
# resolves that directory from the executable (`../Frameworks`); dlopen does
# not expand @executable_path. Without them the app uses Homebrew's
# /opt/homebrew/lib, or falls back to the software renderer. The .icns is
# made with iconutil (macOS only).
set -euo pipefail
STAGE=$(cd "${1:?stage dir}" && pwd)
OUT=$(mkdir -p "${2:?out dir}" && cd "$2" && pwd)
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
NAME=$(basename "$STAGE")              # deathterminal-<ver>-<arch>-macos
base=${NAME#deathterminal-}
rest=${base%-*}                        # drop the os
ARCH=${rest##*-}
VER=${rest%-$ARCH}
# Bundle name is the display name. The helper executable stays
# deathterminal-gui so it does not collide with the deathterminal binary
# on case-insensitive APFS.
APP_BUNDLE="YouNeeK Death Terminal.app"
APP="$OUT/$APP_BUNDLE"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
sed "s/0\.1\.0/$VER/g" "$HERE/Info.plist" > "$APP/Contents/Info.plist"
cp "$STAGE/bin/deathterminal" "$APP/Contents/MacOS/deathterminal"
# Finder launches without arguments; open a window.
cat > "$APP/Contents/MacOS/deathterminal-gui" <<'SH'
#!/bin/sh
exec "$(dirname "$0")/deathterminal" --gui "$@"
SH
chmod +x "$APP/Contents/MacOS/deathterminal-gui" "$APP/Contents/MacOS/deathterminal"
cp -R "$STAGE/share" "$APP/Contents/Resources/"

if [ -n "${MOLTENVK_DIR:-}" ]; then
  cp "$MOLTENVK_DIR/libMoltenVK.dylib" "$APP/Contents/Frameworks/libMoltenVK.dylib"
  cp "$MOLTENVK_DIR/MoltenVK_icd.json" "$APP/Contents/Frameworks/MoltenVK_icd.json"
  if [ -f "$MOLTENVK_DIR/libvulkan.1.dylib" ]; then
    cp "$MOLTENVK_DIR/libvulkan.1.dylib" "$APP/Contents/Frameworks/libvulkan.1.dylib"
  fi
fi

if command -v iconutil >/dev/null; then
  ICONSET=$(mktemp -d)/deathterminal.iconset
  mkdir -p "$ICONSET"
  for s in 16 32 128 256 512; do
    cp "$ROOT/packaging/icons/png/deathterminal-$s.png" "$ICONSET/icon_${s}x${s}.png"
  done
  cp "$ROOT/packaging/icons/png/deathterminal-32.png" "$ICONSET/icon_16x16@2x.png"
  cp "$ROOT/packaging/icons/png/deathterminal-64.png" "$ICONSET/icon_32x32@2x.png"
  cp "$ROOT/packaging/icons/png/deathterminal-256.png" "$ICONSET/icon_128x128@2x.png"
  cp "$ROOT/packaging/icons/png/deathterminal-512.png" "$ICONSET/icon_256x256@2x.png"
  iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/deathterminal.icns"
fi

# Ad-hoc signature only. A Developer ID signature and notarization are
# TODO; CI has no Apple secrets (packaging/SIGNING.md).
command -v codesign >/dev/null && codesign --force --deep --sign - "$APP" || true

(cd "$OUT" && rm -f "DeathTerminal-$VER-$ARCH.zip" && \
  if command -v ditto >/dev/null; then ditto -c -k --keepParent "$APP_BUNDLE" "DeathTerminal-$VER-$ARCH.zip"; \
  else python3 -c "import shutil; shutil.make_archive('DeathTerminal-$VER-$ARCH', 'zip', '.', '$APP_BUNDLE')"; fi)
bash "$HERE/make-dmg.sh" "$APP" "$OUT/DeathTerminal-$VER-$ARCH.dmg"
python3 "$ROOT/packaging/archive.py" "$OUT" "$(basename "$STAGE")" sums >/dev/null
echo "$APP"
