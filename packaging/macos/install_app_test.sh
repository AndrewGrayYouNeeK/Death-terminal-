#!/bin/sh
# Exercise the macOS app layout from install.sh on any POSIX host.
# codesign and xattr are skipped. A local HTTP server stands in for the
# nightly branch.
set -eu

ROOT=$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)
TMP=$(mktemp -d)
httpd=
cleanup() {
  if [ -n "$httpd" ]; then
    kill "$httpd" 2>/dev/null || true
  fi
  rm -rf "$TMP"
}
trap cleanup EXIT

export DEATHTERMINAL_INSTALL_LIB=1
export HOME="$TMP/home"
export DEATHTERMINAL_HOME="$TMP/dt"
export DEATHTERMINAL_OS=macos
export DEATHTERMINAL_ARCH=aarch64
export DEATHTERMINAL_SKIP_SIGN=1
export DEATHTERMINAL_ICON_DIR="$ROOT/packaging/icons/png"
mkdir -p "$HOME"

# shellcheck disable=SC1091
. "$ROOT/install.sh"
detect_platform

fake="$TMP/deathterminal"
printf '#!/bin/sh\necho deathterminal\n' > "$fake"
chmod 755 "$fake"

macos_make_app "$fake"
macos_link_cli_and_desktop

app="$HOME/Applications/YouNeeK Death Terminal.app"
test -d "$app"
test -x "$app/Contents/MacOS/deathterminal"
test -x "$app/Contents/MacOS/deathterminal-gui"
grep -q 'deathterminal' "$app/Contents/MacOS/deathterminal-gui"
grep -q -- '--gui' "$app/Contents/MacOS/deathterminal-gui"
grep -q 'CFBundleExecutable' "$app/Contents/Info.plist"
grep -q 'deathterminal-gui' "$app/Contents/Info.plist"
grep -q 'YouNeeK Death Terminal' "$app/Contents/Info.plist"
test -f "$app/Contents/Resources/deathterminal-512.png"
test -L "$HOME/Desktop/YouNeeK Death Terminal.app"
test -L "$HOME/.local/bin/deathterminal"
linked=$(readlink "$HOME/.local/bin/deathterminal")
test "$linked" = "$app/Contents/MacOS/deathterminal"

# Prebuilt download: good checksum is kept, a bad one is refused.
mkdir -p "$TMP/www/macos/aarch64"
python3 -m http.server 8765 --bind 127.0.0.1 --directory "$TMP/www" >/tmp/dt-prebuilt-http.log 2>&1 &
httpd=$!
printf 'prebuilt-binary\n' > "$TMP/www/macos/aarch64/deathterminal"
if command -v sha256sum >/dev/null 2>&1; then
  sha256sum "$TMP/www/macos/aarch64/deathterminal" | awk '{ print $1 }' > "$TMP/www/macos/aarch64/deathterminal.sha256"
else
  shasum -a 256 "$TMP/www/macos/aarch64/deathterminal" | awk '{ print $1 }' > "$TMP/www/macos/aarch64/deathterminal.sha256"
fi
ready=0
i=0
while [ "$i" -lt 50 ]; do
  if curl -fsS "http://127.0.0.1:8765/macos/aarch64/deathterminal.sha256" >/dev/null 2>&1; then
    ready=1
    break
  fi
  i=$((i + 1))
  sleep 0.1
done
test "$ready" -eq 1

export DEATHTERMINAL_PREBUILT_BASE="http://127.0.0.1:8765"
PREBUILT_BASE=$DEATHTERMINAL_PREBUILT_BASE
downloaded="$TMP/got-bin"
fetch_prebuilt "$downloaded"
cmp "$downloaded" "$TMP/www/macos/aarch64/deathterminal"

printf '00\n' > "$TMP/www/macos/aarch64/deathterminal.sha256"
if fetch_prebuilt "$TMP/got-bad"; then
  echo "bad checksum was accepted" >&2
  exit 1
fi

echo "install app layout ok"
