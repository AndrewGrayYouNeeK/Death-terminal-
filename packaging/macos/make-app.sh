#!/usr/bin/env bash
# Build DeathTerminal.app (skeleton; UNTESTED on a real Mac).
#
#   bash packaging/macos/make-app.sh <stage-dir> <out-dir>
#
# <stage-dir> is a `zig build release -Dtarget=aarch64-macos` (or x86_64)
# tree: zig-out/release/deathterminal-<ver>-<arch>-macos. Produces
# <out-dir>/DeathTerminal.app and DeathTerminal-<ver>-<arch>.zip.
#
# Vulkan on macOS goes through MoltenVK. If MOLTENVK_DIR (containing
# libMoltenVK.dylib and optionally libvulkan.1.dylib) is set, they are copied
# into Contents/Frameworks, where src/renderer/loader.zig looks first.
# Without them the app uses Homebrew's /opt/homebrew/lib, or falls back to
# the software renderer. The .icns is made with iconutil (macOS only).
set -euo pipefail
STAGE=$(cd "${1:?stage dir}" && pwd)
OUT=$(mkdir -p "${2:?out dir}" && cd "$2" && pwd)
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
NAME=$(basename "$STAGE")              # deathterminal-0.1.0-aarch64-macos
VER=$(echo "$NAME" | cut -d- -f2)
ARCH=$(echo "$NAME" | cut -d- -f3)
APP="$OUT/DeathTerminal.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
sed "s/0\.1\.0/$VER/g" "$HERE/Info.plist" > "$APP/Contents/Info.plist"
cp "$STAGE/bin/deathterminal" "$APP/Contents/MacOS/deathterminal"
# Finder launches without arguments; open a window. (Not named
# "DeathTerminal": APFS is case-insensitive by default.)
cat > "$APP/Contents/MacOS/deathterminal-gui" <<'SH'
#!/bin/sh
exec "$(dirname "$0")/deathterminal" --gui "$@"
SH
chmod +x "$APP/Contents/MacOS/deathterminal-gui" "$APP/Contents/MacOS/deathterminal"
cp -R "$STAGE/share" "$APP/Contents/Resources/"

if [ -n "${MOLTENVK_DIR:-}" ]; then
  cp "$MOLTENVK_DIR"/libMoltenVK.dylib "$APP/Contents/Frameworks/"
  [ -f "$MOLTENVK_DIR/libvulkan.1.dylib" ] && cp "$MOLTENVK_DIR/libvulkan.1.dylib" "$APP/Contents/Frameworks/"
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

# Ad-hoc signature so Gatekeeper on Apple silicon will run it locally.
command -v codesign >/dev/null && codesign --force --deep --sign - "$APP" || true

(cd "$OUT" && rm -f "DeathTerminal-$VER-$ARCH.zip" && \
  if command -v ditto >/dev/null; then ditto -c -k --keepParent DeathTerminal.app "DeathTerminal-$VER-$ARCH.zip"; \
  else python3 -c "import shutil; shutil.make_archive('DeathTerminal-$VER-$ARCH', 'zip', '.', 'DeathTerminal.app')"; fi)
echo "$APP"
