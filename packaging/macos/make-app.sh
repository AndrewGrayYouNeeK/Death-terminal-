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
# /opt/homebrew/lib, or falls back to the software renderer. The signing job
# signs that dylib when the Apple secrets are set. The .icns is the
# green-skull logo from site/logo.png (DeathTerminal.icns). iconutil
# rebuilds it from DeathTerminal.iconset when that tool exists.
set -euo pipefail
STAGE=$(cd "${1:?stage dir}" && pwd)
OUT=$(mkdir -p "${2:?out dir}" && cd "$2" && pwd)
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
NAME=$(basename "$STAGE")              # deathterminal-<ver>-<arch>-macos
base=${NAME#deathterminal-}
rest=${base%-*}                        # drop the os
ARCH=${rest##*-}
VER=${rest%-"$ARCH"}
# Bundle name is the display name. The helper executable stays
# deathterminal-gui so it does not collide with the deathterminal binary
# on case-insensitive APFS.
APP_BUNDLE="YouNeeK Death Terminal.app"
APP="$OUT/$APP_BUNDLE"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
if [ -z "$VER" ]; then
  echo "could not parse a version from $NAME" >&2
  exit 1
fi
python3 - "$HERE/Info.plist" "$APP/Contents/Info.plist" "$VER" <<'PY'
import plistlib
import sys

src, dst, ver = sys.argv[1:]
text = open(src, encoding="utf-8").read()
if "__VERSION__" not in text:
    raise SystemExit("Info.plist has no __VERSION__ placeholder")
text = text.replace("__VERSION__", ver)
if "__VERSION__" in text:
    raise SystemExit("version placeholder left in Info.plist")
open(dst, "w", encoding="utf-8").write(text)
with open(dst, "rb") as fh:
    plist = plistlib.load(fh)
short = plist.get("CFBundleShortVersionString")
if short != ver or plist.get("CFBundleVersion") != ver:
    raise SystemExit(f"CFBundleShortVersionString is {short!r}, staged build is {ver!r}")
schemes = []
for item in plist.get("CFBundleURLTypes") or []:
    schemes.extend(item.get("CFBundleURLSchemes") or [])
if "deathterminal" not in schemes:
    raise SystemExit("CFBundleURLTypes is missing the deathterminal scheme")
PY
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

# Green-skull .icns rendered from site/logo.png. Do not substitute
# packaging/icons (a separate export; older art was a white skull).
ICONSET="$HERE/DeathTerminal.iconset"
ICNS="$HERE/DeathTerminal.icns"
if [ ! -f "$ICNS" ]; then
  echo "missing $ICNS; run python3 packaging/macos/render-icon.py" >&2
  exit 1
fi
if command -v iconutil >/dev/null && [ -d "$ICONSET" ]; then
  iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/deathterminal.icns"
else
  cp "$ICNS" "$APP/Contents/Resources/deathterminal.icns"
fi
python3 -c 'import sys; assert open(sys.argv[1], "rb").read(4) == b"icns", sys.argv[1]' \
  "$APP/Contents/Resources/deathterminal.icns"

# Ad-hoc signature only, and only when codesign exists (a local Mac).
# Developer ID signing and notarization run in the release workflow when
# the Apple secrets are set (packaging/SIGNING.md).
if command -v codesign >/dev/null; then
  codesign --force --deep --sign - "$APP" || true
fi

(cd "$OUT" && rm -f "DeathTerminal-$VER-$ARCH.zip" && \
  if command -v ditto >/dev/null; then ditto -c -k --keepParent "$APP_BUNDLE" "DeathTerminal-$VER-$ARCH.zip"; \
  else python3 -c "import shutil; shutil.make_archive('DeathTerminal-$VER-$ARCH', 'zip', '.', '$APP_BUNDLE')"; fi)
bash "$HERE/make-dmg.sh" "$APP" "$OUT/DeathTerminal-$VER-$ARCH.dmg"
python3 "$ROOT/packaging/archive.py" "$OUT" "$(basename "$STAGE")" sums >/dev/null
echo "$APP"
