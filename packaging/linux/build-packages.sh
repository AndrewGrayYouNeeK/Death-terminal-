#!/usr/bin/env bash
# Build the Linux packages from a staged release tree.
#
#   bash packaging/linux/build-packages.sh <version> <stage-dir> <out-dir>
#
# Normally run by `zig build release -Dpackages=true`, which stages
# zig-out/release/deathterminal-<version>-x86_64-linux/ first.
# Produces in <out-dir>:
#   deathterminal-<version>-x86_64.AppImage
#   deathterminal_<version>-1_amd64.deb
#   deathterminal-<version>-1.x86_64.rpm
# Tools (nfpm, appimagetool) are downloaded into packaging/.cache on first
# use; set NFPM / APPIMAGETOOL to use installed ones instead.
set -euo pipefail

VERSION=${1:?version}
STAGE=$(readlink -f "${2:?stage dir}")
OUT=$(readlink -f "${3:?out dir}")
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
CACHE="$ROOT/packaging/.cache"
NFPM_VERSION=2.41.1
mkdir -p "$CACHE" "$OUT"

case "$(uname -m)" in
  x86_64) ARCH=amd64; AI_ARCH=x86_64 ;;
  aarch64) ARCH=arm64; AI_ARCH=aarch64 ;;
  *) echo "unsupported arch $(uname -m)" >&2; exit 1 ;;
esac

# Compressed man page for the packages.
gzip -9nc "$STAGE/share/man/man1/deathterminal.1" > "$STAGE/share/man/man1/deathterminal.1.gz"

# ---------------------------------------------------------------- deb / rpm
NFPM=${NFPM:-}
if [ -z "$NFPM" ]; then
  NFPM="$CACHE/nfpm"
  if [ ! -x "$NFPM" ]; then
    case "$AI_ARCH" in x86_64) NA=x86_64 ;; aarch64) NA=arm64 ;; esac
    curl -fsSL "https://github.com/goreleaser/nfpm/releases/download/v${NFPM_VERSION}/nfpm_${NFPM_VERSION}_Linux_${NA}.tar.gz" | tar -xz -C "$CACHE" nfpm
  fi
fi
# nfpm does not expand variables in `contents`, so fill them in here.
nfpm_cfg() {
  sed -e "s|\${VERSION}|$VERSION|g" -e "s|\${STAGE}|$STAGE|g" -e "s|\${ARCH}|$1|g" "$HERE/nfpm.yaml" > "$OUT/nfpm-$1.yaml"
  echo "$OUT/nfpm-$1.yaml"
}
"$NFPM" package --config "$(nfpm_cfg "$ARCH")" --packager deb --target "$OUT/"
"$NFPM" package --config "$(nfpm_cfg "$AI_ARCH")" --packager rpm --target "$OUT/"
rm -f "$OUT"/nfpm-*.yaml

# ---------------------------------------------------------------- AppImage
APPDIR="$OUT/AppDir"
rm -rf "$APPDIR"
mkdir -p "$APPDIR/usr/bin" "$APPDIR/usr/lib" "$APPDIR/usr/share"
cp "$STAGE/bin/deathterminal" "$APPDIR/usr/bin/"
cp -r "$STAGE/share/applications" "$STAGE/share/icons" "$STAGE/share/man" "$STAGE/share/doc" "$APPDIR/usr/share/"
cp "$ROOT/packaging/appimage/AppRun" "$APPDIR/AppRun"
cp "$STAGE/share/applications/deathterminal.desktop" "$APPDIR/"
cp "$ROOT/packaging/icons/png/deathterminal-256.png" "$APPDIR/deathterminal.png"
cp "$ROOT/packaging/icons/deathterminal.svg" "$APPDIR/.DirIcon.svg"
ln -sf deathterminal.png "$APPDIR/.DirIcon"
# Bundle libraries that are not on the AppImage excludelist (graphics,
# X11/Wayland, fontconfig/freetype/harfbuzz and glibc stay with the host).
for lib in libcrypto.so.3 libxkbcommon.so.0; do
  path=$(ldd "$STAGE/bin/deathterminal" | awk -v l="$lib" '$1 == l { print $3 }')
  [ -n "$path" ] && cp -L "$path" "$APPDIR/usr/lib/"
done

AIT=${APPIMAGETOOL:-}
if [ -z "$AIT" ]; then
  AIT="$CACHE/appimagetool-$AI_ARCH.AppImage"
  if [ ! -x "$AIT" ]; then
    curl -fsSL -o "$AIT" "https://github.com/AppImage/appimagetool/releases/download/continuous/appimagetool-$AI_ARCH.AppImage"
    chmod +x "$AIT"
  fi
fi
# --appimage-extract-and-run: works without FUSE (containers, CI).
ARCH=$AI_ARCH VERSION=$VERSION "$AIT" --appimage-extract-and-run --no-appstream "$APPDIR" "$OUT/deathterminal-$VERSION-$AI_ARCH.AppImage"
rm -rf "$APPDIR"

python3 "$ROOT/packaging/archive.py" "$OUT" "$(basename "$STAGE")" sums >/dev/null
echo "Linux packages in $OUT:"
ls -1 "$OUT" | grep -E "\.(deb|rpm|AppImage)$"
