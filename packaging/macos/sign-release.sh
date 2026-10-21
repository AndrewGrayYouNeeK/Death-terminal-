#!/usr/bin/env bash
# Sign DeathTerminal macOS release artifacts, or copy them through unsigned.
#
#   bash packaging/macos/sign-release.sh <input-dir> <output-dir>
#
# <input-dir> is a directory of DeathTerminal-*.zip / *.dmg / *.tar.gz, or a
# directory of those directories (the actions/download-artifact layout).
#
# Developer ID signing, an hdiutil DMG, notarization, and stapling run only
# when every one of these is non-empty:
#   CSC_LINK CSC_KEY_PASSWORD CODESIGN_IDENTITY
#   APPLE_ID APPLE_APP_PASSWORD APPLE_TEAM_ID
# If any of them is absent the input files are copied unchanged and this
# script exits 0. See packaging/SIGNING.md.
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
ENTITLEMENTS="$HERE/entitlements.plist"
KEYCHAIN=""
KEYCHAIN_DIR=""
P12=""
WORK=""

cleanup() {
  if [ -n "$WORK" ]; then
    rm -rf "$WORK"
  fi
  if [ -n "$P12" ]; then
    rm -f "$P12"
  fi
  if [ -n "$KEYCHAIN" ] && command -v security >/dev/null 2>&1; then
    security delete-keychain "$KEYCHAIN" >/dev/null 2>&1 || true
  fi
  if [ -n "$KEYCHAIN_DIR" ]; then
    rm -rf "$KEYCHAIN_DIR"
  fi
}
trap cleanup EXIT

if [ "$#" -ne 2 ]; then
  echo "usage: sign-release.sh <input-dir> <output-dir>" >&2
  exit 2
fi
IN=$(cd "$1" && pwd)
OUT=$(mkdir -p "$2" && cd "$2" && pwd)

MISSING=""
[ -z "${CSC_LINK:-}" ] && MISSING="$MISSING CSC_LINK"
[ -z "${CSC_KEY_PASSWORD:-}" ] && MISSING="$MISSING CSC_KEY_PASSWORD"
[ -z "${CODESIGN_IDENTITY:-}" ] && MISSING="$MISSING CODESIGN_IDENTITY"
[ -z "${APPLE_ID:-}" ] && MISSING="$MISSING APPLE_ID"
[ -z "${APPLE_APP_PASSWORD:-}" ] && MISSING="$MISSING APPLE_APP_PASSWORD"
[ -z "${APPLE_TEAM_ID:-}" ] && MISSING="$MISSING APPLE_TEAM_ID"
MISSING=${MISSING# }

copy_files() {
  local in=$1
  local f base
  mkdir -p "$OUT"
  for f in "$in"/*; do
    [ -f "$f" ] || continue
    base=$(basename "$f")
    cp -a "$f" "$OUT/$base"
  done
}

copy_unsigned() {
  local in=$1
  local has_zip=false
  local d
  for d in "$in"/DeathTerminal-*.zip; do
    [ -f "$d" ] && has_zip=true && break
  done
  if [ "$has_zip" = true ]; then
    copy_files "$in"
    return
  fi
  local found=false
  for d in "$in"/*; do
    [ -d "$d" ] || continue
    found=true
    copy_files "$d"
  done
  if [ "$found" = false ]; then
    echo "no macOS artifacts in $in" >&2
    exit 1
  fi
}

require_tools() {
  local missing="" t
  for t in codesign security hdiutil ditto file clang openssl xcrun; do
    command -v "$t" >/dev/null 2>&1 || missing="$missing $t"
  done
  if ! xcrun --find notarytool >/dev/null 2>&1; then
    missing="$missing notarytool"
  fi
  if ! xcrun --find stapler >/dev/null 2>&1; then
    missing="$missing stapler"
  fi
  if [ -n "$missing" ]; then
    echo "signing secrets are set but these tools are missing:${missing}" >&2
    exit 1
  fi
}

codesign_runtime() {
  local target=$1
  local entitlements=${2:-}
  if [ -n "$entitlements" ]; then
    codesign --force --sign "$CODESIGN_IDENTITY" --options runtime --timestamp \
      --keychain "$KEYCHAIN" --entitlements "$entitlements" "$target"
  else
    codesign --force --sign "$CODESIGN_IDENTITY" --options runtime --timestamp \
      --keychain "$KEYCHAIN" "$target"
  fi
}

setup_keychain() {
  local password old_umask line
  local chains
  KEYCHAIN_DIR=$(mktemp -d)
  KEYCHAIN="$KEYCHAIN_DIR/deathterminal-signing.keychain-db"
  password=$(openssl rand -base64 32)
  P12=$(mktemp)
  old_umask=$(umask)
  umask 077
  printf '%s' "$CSC_LINK" | base64 -D > "$P12"
  umask "$old_umask"

  security create-keychain -p "$password" "$KEYCHAIN"
  security set-keychain-settings -lut 21600 "$KEYCHAIN"
  security unlock-keychain -p "$password" "$KEYCHAIN"
  security import "$P12" -k "$KEYCHAIN" -P "$CSC_KEY_PASSWORD" -T /usr/bin/codesign -T /usr/bin/security
  security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$password" "$KEYCHAIN" >/dev/null
  # codesign --keychain still needs the keychain on the user search list.
  chains=("$KEYCHAIN")
  while IFS= read -r line; do
    line=${line//\"/}
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    [ -n "$line" ] || continue
    chains+=("$line")
  done < <(security list-keychains -d user)
  security list-keychains -d user -s "${chains[@]}"
  rm -f "$P12"
  P12=""

  if ! security find-identity -v -p codesigning "$KEYCHAIN" | grep -F "$CODESIGN_IDENTITY" >/dev/null; then
    echo "CODESIGN_IDENTITY is not in the imported keychain. Identities found:" >&2
    security find-identity -v -p codesigning "$KEYCHAIN" >&2 || true
    exit 1
  fi
}

sign_machos() {
  local root=$1
  local list f kind
  list=$(mktemp)
  find "$root" -type f > "$list"
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    kind=$(file -b "$f")
    case "$kind" in
      Mach-O*)
        case "$f" in
          *.dylib) codesign_runtime "$f" "" ;;
          *) codesign_runtime "$f" "$ENTITLEMENTS" ;;
        esac
        ;;
    esac
  done < "$list"
  rm -f "$list"
}

sign_one() {
  local zip=$1
  local stem app
  stem=$(basename "$zip" .zip)
  WORK=$(mktemp -d)
  mkdir -p "$WORK/unz"
  ditto -x -k "$zip" "$WORK/unz"
  app="$WORK/unz/DeathTerminal.app"
  if [ ! -d "$app" ]; then
    echo "zip has no DeathTerminal.app: $zip" >&2
    exit 1
  fi
  mkdir -p "$app/Contents/Frameworks" "$app/Contents/MacOS"
  chmod +x "$app/Contents/MacOS/deathterminal" "$app/Contents/MacOS/deathterminal-gui"

  # Hardened runtime applies to Mach-O. The cross-compiled bundle's
  # CFBundleExecutable is a shell script; replace it before signing.
  if ! file -b "$app/Contents/MacOS/deathterminal-gui" | grep -q Mach-O; then
    clang -std=c99 -O2 -Wall -Wextra -o "$app/Contents/MacOS/deathterminal-gui" "$HERE/gui-launcher.c"
    chmod +x "$app/Contents/MacOS/deathterminal-gui"
  fi

  sign_machos "$app/Contents"
  codesign_runtime "$app" "$ENTITLEMENTS"
  codesign --verify --strict --verbose=2 "$app"

  bash "$HERE/make-dmg.sh" "$app" "$OUT/$stem.dmg"
  xcrun notarytool submit "$OUT/$stem.dmg" \
    --apple-id "$APPLE_ID" \
    --team-id "$APPLE_TEAM_ID" \
    --password "$APPLE_APP_PASSWORD" \
    --wait
  xcrun stapler staple "$OUT/$stem.dmg"
  xcrun stapler staple "$app"

  rm -f "$OUT/$stem.zip"
  (cd "$WORK/unz" && ditto -c -k --keepParent DeathTerminal.app "$OUT/$stem.zip")
  rm -rf "$WORK"
  WORK=""
  echo "signed and notarized $stem"
}

sign_tree() {
  local in=$1
  local has_zip=false
  local d found z f base
  for d in "$in"/DeathTerminal-*.zip; do
    [ -f "$d" ] && has_zip=true && break
  done
  if [ "$has_zip" = true ]; then
    for z in "$in"/DeathTerminal-*.zip; do
      [ -f "$z" ] || continue
      sign_one "$z"
    done
    for f in "$in"/*; do
      [ -f "$f" ] || continue
      base=$(basename "$f")
      case "$base" in
        DeathTerminal-*.zip|DeathTerminal-*.dmg) continue ;;
      esac
      cp -a "$f" "$OUT/$base"
    done
    return
  fi
  found=false
  for d in "$in"/*; do
    [ -d "$d" ] || continue
    found=true
    sign_tree "$d"
  done
  if [ "$found" = false ]; then
    echo "no macOS artifacts in $in" >&2
    exit 1
  fi
}

if [ -n "$MISSING" ]; then
  echo "Apple signing secrets are absent ($MISSING); copying macOS artifacts unsigned."
  copy_unsigned "$IN"
else
  require_tools
  setup_keychain
  sign_tree "$IN"
fi

if ! ls "$OUT"/DeathTerminal-*.zip >/dev/null 2>&1; then
  echo "no DeathTerminal zip in $OUT" >&2
  exit 1
fi
echo "macOS artifacts in $OUT:"
ls -l "$OUT"
