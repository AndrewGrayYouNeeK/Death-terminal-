#!/bin/sh
# Install YouNeeK Death Terminal from the main branch.
# POSIX sh. macOS (arm64 and x86_64) and Linux (x86_64 and aarch64).
#
#   curl -fsSL https://raw.githubusercontent.com/AndrewGrayYouNeeK/Death-terminal-/main/install.sh | sh
#   curl -fsSL https://raw.githubusercontent.com/AndrewGrayYouNeeK/Death-terminal-/main/install.sh | sh -s -- --uninstall
#
# Windows (no administrator): install.ps1
#   irm https://raw.githubusercontent.com/AndrewGrayYouNeeK/Death-terminal-/main/install.ps1 | iex
#
# Re-run the same command to update.
#
# macOS: downloads a prebuilt arm64 or x86_64 binary. Those binaries are
# cross-compiled on Linux and published on the rolling `nightly` branch.
# Zig 0.13 cannot link on current macOS, so a missing prebuilt is an error,
# not a source build. The app is ~/Applications/YouNeeK Death Terminal.app,
# a Desktop symlink, and ~/.local/bin/deathterminal. Quarantine is stripped
# and the bundle is ad-hoc signed.
# DT_REF selects the git ref for the prebuilt binary and the icon pngs
# (default: nightly). Linux still builds from source with Zig 0.13.

set -eu

ZIG_VERSION=0.13.0
PREFIX=${DEATHTERMINAL_HOME:-"$HOME/.deathterminal"}
BIN_DIR="$HOME/.local/bin"
BIN_PATH="$BIN_DIR/deathterminal"
REPO="AndrewGrayYouNeeK/Death-terminal-"
SOURCE_URL="https://codeload.github.com/${REPO}/tar.gz/refs/heads/main"
MOLTENVK_VERSION=1.4.2
MOLTENVK_SHA256=f95765a6229cb7b915990a2890ce12ebe36a730b021545d3d52ae69ce4c4024e
MOLTENVK_URL="https://github.com/KhronosGroup/MoltenVK/releases/download/v${MOLTENVK_VERSION}/MoltenVK-macos.tar"
MANIFEST="$PREFIX/installed-files.txt"
APP_BUNDLE="YouNeeK Death Terminal.app"
APP_PATH="$HOME/Applications/$APP_BUNDLE"
DESKTOP_LINK="$HOME/Desktop/$APP_BUNDLE"
# Git ref for prebuilt macOS binaries and icon pngs. Default is the rolling
# nightly branch. Override to test a branch before it is merged:
#   curl -fsSL https://raw.githubusercontent.com/${REPO}/<branch>/install.sh | DT_REF=nightly sh
DT_REF=${DT_REF:-nightly}

say() {
  printf '==> %s\n' "$*"
}

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

usage() {
  cat <<EOF
Usage: install.sh [--uninstall]

  curl -fsSL https://raw.githubusercontent.com/AndrewGrayYouNeeK/Death-terminal-/main/install.sh | sh

macOS (arm64 and Intel): installs ~/Applications/YouNeeK Death Terminal.app,
a Desktop symlink you can double-click, and ~/.local/bin/deathterminal.
A prebuilt binary is required. Zig 0.13 cannot link on current macOS, so a
missing prebuilt stops with an error. Set DT_REF to choose the git ref
(default nightly). Linux installs ~/.local/bin/deathterminal by building
from source.
Run again to update. --uninstall removes the app, the Desktop symlink, the
CLI, MoltenVK files this script installed, and ~/.deathterminal.
~/.config/death-terminal is kept.

Windows:
  irm https://raw.githubusercontent.com/AndrewGrayYouNeeK/Death-terminal-/main/install.ps1 | iex
EOF
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

file_sha256() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk 'NR==1 { print $1 }'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk 'NR==1 { print $1 }'
  elif command -v openssl >/dev/null 2>&1; then
    openssl dgst -sha256 "$1" | awk 'NR==1 { print $NF }'
  else
    return 1
  fi
}

sha_matches() {
  got=$(file_sha256 "$1") || return 1
  [ "$got" = "$2" ]
}

verify_sha256() {
  got=$(file_sha256 "$1") || die "need sha256sum, shasum, or openssl to verify $1"
  if [ "$got" != "$2" ]; then
    die "checksum mismatch for $1 (expected $2, got $got)"
  fi
}

curl_to() {
  curl_url=$1
  curl_dest=$2
  curl_tmp="$curl_dest.partial"
  rm -f "$curl_tmp"
  curl -fsSL --retry 3 --retry-delay 2 -o "$curl_tmp" "$curl_url" || {
    rm -f "$curl_tmp"
    return 1
  }
  mv -f "$curl_tmp" "$curl_dest"
}

download() {
  url=$1
  dest=$2
  say "Downloading $url"
  curl_to "$url" "$dest" || die "download failed: $url"
}

detect_platform() {
  if [ -n "${DEATHTERMINAL_OS:-}" ]; then
    zig_os=$DEATHTERMINAL_OS
    zig_arch=${DEATHTERMINAL_ARCH:-x86_64}
    case "$zig_os" in
      linux|macos) ;;
      *) die "DEATHTERMINAL_OS must be linux or macos" ;;
    esac
    case "$zig_arch" in
      x86_64|aarch64) ;;
      *) die "DEATHTERMINAL_ARCH must be x86_64 or aarch64" ;;
    esac
    return 0
  fi
  uname_s=$(uname -s)
  uname_m=$(uname -m)
  case "$uname_s" in
    Linux) zig_os=linux ;;
    Darwin) zig_os=macos ;;
    MINGW*|MSYS*|CYGWIN*)
      die "This environment is Windows. In PowerShell run: irm https://raw.githubusercontent.com/AndrewGrayYouNeeK/Death-terminal-/main/install.ps1 | iex"
      ;;
    *)
      die "unsupported operating system: $uname_s (supported: macOS and Linux; Windows uses install.ps1)"
      ;;
  esac
  case "$uname_m" in
    x86_64|amd64) zig_arch=x86_64 ;;
    aarch64|arm64) zig_arch=aarch64 ;;
    *)
      die "unsupported architecture: $uname_m (supported: x86_64 and aarch64 / arm64)"
      ;;
  esac
}

zig_sha256_for() {
  case "$1" in
    linux-x86_64) printf '%s\n' "d45312e61ebcc48032b77bc4cf7fd6915c11fa16e4aad116b66c9468211230ea" ;;
    linux-aarch64) printf '%s\n' "041ac42323837eb5624068acd8b00cd5777dac4cf91179e8dad7a7e90dd0c556" ;;
    macos-x86_64) printf '%s\n' "8b06ed1091b2269b700b3b07f8e3be3b833000841bae5aa6a09b1a8b4773effd" ;;
    macos-aarch64) printf '%s\n' "46fae219656545dfaf4dce12fb4e8685cec5b51d721beee9389ab4194d43394c" ;;
    *) return 1 ;;
  esac
}

zig_is_013() {
  z=$1
  [ -n "$z" ] && [ -x "$z" ] || return 1
  ver=$("$z" version 2>/dev/null) || return 1
  case "$ver" in
    0.13.*) return 0 ;;
    *) return 1 ;;
  esac
}

ensure_zig() {
  if command -v zig >/dev/null 2>&1; then
    z=$(command -v zig)
    if zig_is_013 "$z"; then
      ZIG=$z
      say "Using Zig $("$ZIG" version) at $ZIG"
      return 0
    fi
    say "Found Zig at $z ($("$z" version 2>/dev/null || printf '%s' 'unknown')), not 0.13.x. A private Zig 0.13.0 will be used."
  fi
  if zig_is_013 "$PREFIX/zig/zig"; then
    ZIG=$PREFIX/zig/zig
    say "Using Zig $("$ZIG" version) at $ZIG"
    return 0
  fi

  triple="${zig_os}-${zig_arch}"
  zig_sha=$(zig_sha256_for "$triple") || die "no official Zig ${ZIG_VERSION} build for ${zig_os} ${zig_arch}"
  zig_name="zig-${zig_os}-${zig_arch}-${ZIG_VERSION}.tar.xz"
  zig_url="https://ziglang.org/download/${ZIG_VERSION}/${zig_name}"
  say "Zig 0.13 not found. Downloading Zig ${ZIG_VERSION} for ${zig_os} ${zig_arch} into ${PREFIX}/zig"
  mkdir -p "$PREFIX/downloads"
  tarball="$PREFIX/downloads/$zig_name"
  if [ ! -f "$tarball" ] || ! sha_matches "$tarball" "$zig_sha"; then
    download "$zig_url" "$tarball"
    verify_sha256 "$tarball" "$zig_sha"
  else
    say "Using cached $tarball"
  fi
  rm -rf "$PREFIX/zig"
  mkdir -p "$PREFIX/zig"
  tar -xf "$tarball" -C "$PREFIX/zig" --strip-components=1 || die "could not extract $tarball (install tar and xz)"
  ZIG=$PREFIX/zig/zig
  zig_is_013 "$ZIG" || die "extracted Zig at $ZIG does not report version 0.13.x"
  say "Installed Zig $("$ZIG" version) to $PREFIX/zig"
}

print_linux_build_deps() {
  cat >&2 <<'EOF'

Build failed.

Install the Linux build dependencies, then run this script again.
That includes the X11, Wayland, xkbcommon, FreeType, HarfBuzz, fontconfig,
and OpenSSL development packages, and the libssh2 and Vulkan dev packages.

Debian / Ubuntu:
  sudo apt-get update
  sudo apt-get install -y pkg-config build-essential \
    libx11-dev libwayland-dev wayland-protocols libxkbcommon-dev \
    libfreetype-dev libharfbuzz-dev libfontconfig-dev libssl-dev \
    libssh2-1-dev libvulkan-dev

Fedora:
  sudo dnf install -y pkgconf-pkg-config gcc \
    libX11-devel wayland-devel wayland-protocols-devel libxkbcommon-devel \
    freetype-devel harfbuzz-devel fontconfig-devel openssl-devel \
    libssh2-devel vulkan-devel

Arch Linux:
  sudo pacman -S --needed pkgconf base-devel \
    libx11 wayland wayland-protocols libxkbcommon freetype2 harfbuzz \
    fontconfig openssl libssh2 vulkan-devel

libssh2 in this tree is the vendored 1.11.1 sources; the link step needs
libcrypto from the OpenSSL development package. Vulkan headers are vendored.
The Vulkan development package provides the loader. At run time, install
libvulkan1 and mesa-vulkan-drivers (or another Vulkan driver), or Death
Terminal uses the software renderer.
EOF
}

fetch_source() {
  say "Downloading main branch source from codeload"
  mkdir -p "$PREFIX/downloads"
  archive="$PREFIX/downloads/deathterminal-main.tar.gz"
  download "$SOURCE_URL" "$archive"
  rm -rf "$PREFIX/src"
  mkdir -p "$PREFIX/src"
  tar -xzf "$archive" -C "$PREFIX/src" --strip-components=1 || die "could not extract the source tarball"
  [ -f "$PREFIX/src/build.zig" ] || die "source tarball has no build.zig"
  say "Source ready at $PREFIX/src"
}

record_installed() {
  mkdir -p "$(dirname "$MANIFEST")"
  printf '%s\n' "$1" >> "$MANIFEST"
}

install_file() {
  src=$1
  dest=$2
  mode=$3
  dest_dir=$(dirname "$dest")
  mkdir -p "$dest_dir"
  tmp=$(mktemp "$dest_dir/.deathterminal.XXXXXX") || die "cannot create a temp file in $dest_dir"
  cp "$src" "$tmp" || die "cannot copy $src"
  chmod "$mode" "$tmp" || die "cannot chmod $dest"
  mv -f "$tmp" "$dest" || die "cannot install $dest"
  record_installed "$dest"
  say "Installed $dest"
}

pick_file() {
  root=$1
  name=$2
  list=$(mktemp) || die "mktemp failed"
  find "$root" -type f -name "$name" > "$list" 2>/dev/null || true
  found=
  preferred=
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    case "$f" in
      */dylib/macOS/"$name") preferred=$f; break ;;
    esac
    if [ -z "$found" ]; then
      found=$f
    fi
  done < "$list"
  rm -f "$list"
  if [ -n "$preferred" ]; then
    printf '%s\n' "$preferred"
    return 0
  fi
  if [ -n "$found" ]; then
    printf '%s\n' "$found"
    return 0
  fi
  return 1
}

install_moltenvk() {
  say "Downloading MoltenVK ${MOLTENVK_VERSION} so libMoltenVK.dylib sits beside the binary"
  mkdir -p "$PREFIX/downloads" "$PREFIX/moltenvk"
  tarfile="$PREFIX/downloads/MoltenVK-${MOLTENVK_VERSION}-macos.tar"
  if [ ! -f "$tarfile" ] || ! sha_matches "$tarfile" "$MOLTENVK_SHA256"; then
    download "$MOLTENVK_URL" "$tarfile"
    verify_sha256 "$tarfile" "$MOLTENVK_SHA256"
  else
    say "Using cached $tarfile"
  fi
  srcdir="$PREFIX/moltenvk/src"
  stamp="$srcdir/.sha256"
  if [ ! -f "$stamp" ] || [ "$(cat "$stamp")" != "$MOLTENVK_SHA256" ]; then
    rm -rf "$srcdir"
    mkdir -p "$srcdir"
    tar -xf "$tarfile" -C "$srcdir" || die "could not extract MoltenVK"
    printf '%s\n' "$MOLTENVK_SHA256" > "$stamp"
  fi
  dylib=$(pick_file "$srcdir" "libMoltenVK.dylib") || die "MoltenVK archive is missing libMoltenVK.dylib"
  icd=$(pick_file "$srcdir" "MoltenVK_icd.json") || die "MoltenVK archive is missing MoltenVK_icd.json"
  install_file "$dylib" "$BIN_DIR/libMoltenVK.dylib" 755
  icd_out="$BIN_DIR/MoltenVK_icd.json"
  sed 's/"library_path"[[:space:]]*:[[:space:]]*"[^"]*"/"library_path": ".\/libMoltenVK.dylib"/' "$icd" > "$icd_out.partial" || die "could not rewrite MoltenVK_icd.json"
  mv -f "$icd_out.partial" "$icd_out"
  record_installed "$icd_out"
  say "Installed $icd_out"
  vulkan_src=$(dirname "$dylib")/libvulkan.1.dylib
  if [ -f "$vulkan_src" ]; then
    install_file "$vulkan_src" "$BIN_DIR/libvulkan.1.dylib" 755
  fi
}

macos_unquarantine_and_sign() {
  file=$1
  if [ "${DEATHTERMINAL_SKIP_SIGN:-}" = "1" ]; then
    say "Skipping quarantine clear and codesign for $file"
    return 0
  fi
  command -v xattr >/dev/null 2>&1 || die "xattr is required on macOS to clear quarantine on $file"
  command -v codesign >/dev/null 2>&1 || die "codesign is required on macOS to ad-hoc sign $file"
  xattr -c "$file" || die "xattr -c failed for $file"
  case "$file" in
    *.json) say "Cleared quarantine on $file" ;;
    *)
      codesign --force --sign - "$file" || die "ad-hoc codesign failed for $file"
      say "Cleared quarantine and ad-hoc signed $file"
      ;;
  esac
}

# raw.githubusercontent.com, not media.githubusercontent.com. The nightly
# branch stores plain git blobs (not Git LFS), and raw serves those blobs.
prebuilt_root() {
  if [ -n "${DEATHTERMINAL_PREBUILT_BASE:-}" ]; then
    printf '%s\n' "$DEATHTERMINAL_PREBUILT_BASE"
    return 0
  fi
  printf '%s\n' "https://raw.githubusercontent.com/${REPO}/${DT_REF}"
}

icon_root() {
  if [ -n "${DEATHTERMINAL_ICON_BASE:-}" ]; then
    printf '%s\n' "$DEATHTERMINAL_ICON_BASE"
    return 0
  fi
  printf '%s\n' "https://raw.githubusercontent.com/${REPO}/${DT_REF}/packaging/icons/png"
}

# Fetch the prebuilt macOS binary. Returns 1 when it is missing or the
# checksum does not match. macOS does not fall back to a source build.
fetch_prebuilt() {
  prebuilt_path=$1
  base="$(prebuilt_root)/macos/${zig_arch}"
  shafile="$PREFIX/downloads/deathterminal-${zig_arch}.sha256"
  mkdir -p "$PREFIX/downloads"
  say "Looking for a prebuilt ${zig_arch} macOS binary"
  if ! curl_to "$base/deathterminal.sha256" "$shafile"; then
    say "No prebuilt checksum published yet"
    return 1
  fi
  expected=$(awk 'NR==1 { print $1 }' "$shafile")
  if [ -z "$expected" ]; then
    say "Prebuilt checksum file was empty"
    return 1
  fi
  if ! curl_to "$base/deathterminal" "$prebuilt_path"; then
    say "Prebuilt binary download failed"
    return 1
  fi
  if ! sha_matches "$prebuilt_path" "$expected"; then
    say "Prebuilt checksum did not match; ignoring it"
    rm -f "$prebuilt_path"
    return 1
  fi
  chmod 755 "$prebuilt_path" || die "cannot mark the prebuilt binary executable"
  say "Verified prebuilt binary (Zig is not required)"
  return 0
}

macos_copy_icons() {
  resources=$1
  iconset=$2
  stage=$(dirname "$iconset")
  mkdir -p "$iconset" "$resources" "$stage"
  for s in 16 32 64 128 256 512; do
    name="deathterminal-$s.png"
    if [ -n "${DEATHTERMINAL_ICON_DIR:-}" ]; then
      cp "$DEATHTERMINAL_ICON_DIR/$name" "$stage/$name" || die "missing icon $name"
    else
      download "$(icon_root)/$name" "$stage/$name"
    fi
    cp "$stage/$name" "$resources/$name"
  done
  cp "$stage/deathterminal-16.png" "$iconset/icon_16x16.png"
  cp "$stage/deathterminal-32.png" "$iconset/icon_16x16@2x.png"
  cp "$stage/deathterminal-32.png" "$iconset/icon_32x32.png"
  cp "$stage/deathterminal-64.png" "$iconset/icon_32x32@2x.png"
  cp "$stage/deathterminal-128.png" "$iconset/icon_128x128.png"
  cp "$stage/deathterminal-256.png" "$iconset/icon_128x128@2x.png"
  cp "$stage/deathterminal-256.png" "$iconset/icon_256x256.png"
  cp "$stage/deathterminal-512.png" "$iconset/icon_256x256@2x.png"
  cp "$stage/deathterminal-512.png" "$iconset/icon_512x512.png"
  if command -v iconutil >/dev/null 2>&1; then
    iconutil -c icns "$iconset" -o "$resources/deathterminal.icns" || die "iconutil could not build deathterminal.icns"
    say "Built $resources/deathterminal.icns"
  else
    say "iconutil is not available; the png icons are in the app bundle but Finder may not show them until iconutil can run"
  fi
}

macos_make_app() {
  binary=$1
  [ -f "$binary" ] || die "no binary to bundle: $binary"
  say "Creating $APP_PATH"
  rm -rf "$APP_PATH"
  mkdir -p "$APP_PATH/Contents/MacOS" "$APP_PATH/Contents/Resources" "$APP_PATH/Contents/Frameworks"
  cp "$binary" "$APP_PATH/Contents/MacOS/deathterminal"
  chmod 755 "$APP_PATH/Contents/MacOS/deathterminal"
  cat > "$APP_PATH/Contents/MacOS/deathterminal-gui" <<'SH'
#!/bin/sh
here=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
exec "$here/deathterminal" --gui "$@"
SH
  chmod 755 "$APP_PATH/Contents/MacOS/deathterminal-gui"
  cat > "$APP_PATH/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>YouNeeK Death Terminal</string>
  <key>CFBundleDisplayName</key><string>YouNeeK Death Terminal</string>
  <key>CFBundleIdentifier</key><string>com.github.andrewgrayyouneek.deathterminal</string>
  <key>CFBundleVersion</key><string>nightly</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleExecutable</key><string>deathterminal-gui</string>
  <key>CFBundleIconFile</key><string>deathterminal</string>
  <key>LSMinimumSystemVersion</key><string>11.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSSupportsAutomaticGraphicsSwitching</key><true/>
</dict>
</plist>
PLIST
  iconset=$(mktemp -d) || die "mktemp failed"
  macos_copy_icons "$APP_PATH/Contents/Resources" "$iconset/deathterminal.iconset"
  rm -rf "$iconset"
  record_installed "$APP_PATH"
  say "App bundle ready at $APP_PATH"
}

macos_place_moltenvk() {
  install_moltenvk
  fw="$APP_PATH/Contents/Frameworks"
  mac="$APP_PATH/Contents/MacOS"
  mkdir -p "$fw"
  for name in libMoltenVK.dylib libvulkan.1.dylib MoltenVK_icd.json; do
    if [ -f "$BIN_DIR/$name" ]; then
      cp "$BIN_DIR/$name" "$fw/$name"
      ln -sfn "../Frameworks/$name" "$mac/$name"
      record_installed "$fw/$name"
      record_installed "$mac/$name"
    fi
  done
}

macos_sign_bundle() {
  if [ "${DEATHTERMINAL_SKIP_SIGN:-}" = "1" ]; then
    say "Skipping quarantine clear and codesign for $APP_PATH"
    return 0
  fi
  command -v xattr >/dev/null 2>&1 || die "xattr is required on macOS to clear quarantine on the app"
  command -v codesign >/dev/null 2>&1 || die "codesign is required on macOS to ad-hoc sign the app"
  xattr -cr "$APP_PATH" || die "xattr -cr failed for $APP_PATH"
  codesign --force --deep --sign - "$APP_PATH" || die "ad-hoc codesign failed for $APP_PATH"
  say "Cleared quarantine and ad-hoc signed $APP_PATH"
}

macos_link_cli_and_desktop() {
  mkdir -p "$BIN_DIR" "$HOME/Desktop"
  ln -sfn "$APP_PATH/Contents/MacOS/deathterminal" "$BIN_PATH"
  record_installed "$BIN_PATH"
  say "CLI is $BIN_PATH"
  ln -sfn "$APP_PATH" "$DESKTOP_LINK"
  record_installed "$DESKTOP_LINK"
  say "Desktop shortcut is $DESKTOP_LINK"
}

print_macos_instructions() {
  printf '\n'
  say "Double-click \"$DESKTOP_LINK\""
  printf '\nThe app is also at:\n\n  %s\n\n' "$APP_PATH"
  printf 'The deathterminal command is:\n\n  %s\n\n' "$BIN_PATH"
  printf 'Add ~/.local/bin to PATH if it is not already there:\n\n'
  # shellcheck disable=SC2016
  printf '  export PATH="$HOME/.local/bin:$PATH"\n\n'
  printf 'Run this script again to update.\n'
  printf 'Uninstall:\n\n'
  printf '  curl -fsSL https://raw.githubusercontent.com/AndrewGrayYouNeeK/Death-terminal-/main/install.sh | sh -s -- --uninstall\n\n'
}

print_run_instructions() {
  printf '\n'
  say "Installed $BIN_PATH"
  printf '\nAdd ~/.local/bin to PATH if it is not already there:\n\n'
  # The dollar signs are text for the user to paste, not variables to expand.
  # shellcheck disable=SC2016
  printf '  export PATH="$HOME/.local/bin:$PATH"\n\n'
  printf 'Start the GUI:\n\n'
  printf '  deathterminal --gui\n\n'
  printf 'Run this script again to update.\n'
  printf 'Uninstall:\n\n'
  printf '  curl -fsSL https://raw.githubusercontent.com/AndrewGrayYouNeeK/Death-terminal-/main/install.sh | sh -s -- --uninstall\n\n'
}

build_from_source() {
  ensure_zig
  fetch_source
  mkdir -p "$PREFIX/cache" "$PREFIX/global-cache"
  say "Building: $ZIG build -Doptimize=ReleaseSafe"
  if ! (
    cd "$PREFIX/src" &&
      "$ZIG" build -Doptimize=ReleaseSafe \
        --cache-dir "$PREFIX/cache" \
        --global-cache-dir "$PREFIX/global-cache"
  ); then
    if [ "$zig_os" = "linux" ]; then
      print_linux_build_deps
    fi
    die "build failed"
  fi
  [ -f "$PREFIX/src/zig-out/bin/deathterminal" ] || die "build did not produce zig-out/bin/deathterminal"
  BUILT_BIN="$PREFIX/src/zig-out/bin/deathterminal"
}

die_no_prebuilt() {
  url="$(prebuilt_root)/macos/${zig_arch}/deathterminal"
  cat >&2 <<EOF
error: no prebuilt Death Terminal for ${zig_arch}-macos.

Zig 0.13 cannot link programs on current macOS. The linker reports undefined
symbols from libSystem (_getcwd, _abort, _sigaction, _posix_memalign,
_malloc_size, _getenv, _fork, _bzero, _arc4random_buf, _sysctlbyname), so this
installer does not try to build from source on a Mac.

The macOS binaries are cross-compiled on Linux and stored on the git ref
"${DT_REF}" (override with DT_REF). This URL did not return a checksummed
binary:

  ${url}
  ${url}.sha256

Test this branch before it is merged:

  curl -fsSL https://raw.githubusercontent.com/${REPO}/cursor/window-share-fixes-0c84/install.sh | DT_REF=nightly sh
EOF
  exit 1
}

install_macos() {
  prebuilt="$PREFIX/downloads/deathterminal-${zig_arch}"
  if fetch_prebuilt "$prebuilt"; then
    binary=$prebuilt
  else
    die_no_prebuilt
  fi
  macos_make_app "$binary"
  macos_place_moltenvk
  macos_sign_bundle
  macos_link_cli_and_desktop
  print_macos_instructions
}

build_and_install() {
  if [ -x "$BIN_PATH" ] || [ -d "$APP_PATH" ]; then
    say "Updating YouNeeK Death Terminal"
  else
    say "Installing YouNeeK Death Terminal"
  fi
  say "Platform: ${zig_os} ${zig_arch}"
  mkdir -p "$BIN_DIR" "$PREFIX"
  : > "$MANIFEST"
  if [ "$zig_os" = "macos" ]; then
    install_macos
    return 0
  fi
  build_from_source
  install_file "$BUILT_BIN" "$BIN_PATH" 755
  print_run_instructions
}

remove_path() {
  target=$1
  if [ -L "$target" ] || [ -f "$target" ]; then
    rm -f "$target"
    say "Removed $target"
  elif [ -d "$target" ]; then
    rm -rf "$target"
    say "Removed $target"
  fi
}

uninstall() {
  say "Uninstalling YouNeeK Death Terminal"
  remove_path "$APP_PATH"
  remove_path "$DESKTOP_LINK"
  if [ -f "$MANIFEST" ]; then
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      if [ -e "$f" ] || [ -L "$f" ]; then
        rm -f "$f"
        say "Removed $f"
      fi
    done < "$MANIFEST"
  fi
  if [ -e "$BIN_PATH" ] || [ -L "$BIN_PATH" ]; then
    rm -f "$BIN_PATH"
    say "Removed $BIN_PATH"
  fi
  if [ -e "$BIN_DIR/libMoltenVK.dylib" ] || [ -L "$BIN_DIR/libMoltenVK.dylib" ]; then
    rm -f "$BIN_DIR/libMoltenVK.dylib"
    say "Removed $BIN_DIR/libMoltenVK.dylib"
  fi
  if [ -e "$BIN_DIR/MoltenVK_icd.json" ] || [ -L "$BIN_DIR/MoltenVK_icd.json" ]; then
    rm -f "$BIN_DIR/MoltenVK_icd.json"
    say "Removed $BIN_DIR/MoltenVK_icd.json"
  fi
  if [ -d "$PREFIX" ]; then
    rm -rf "$PREFIX"
    say "Removed $PREFIX"
  else
    say "No install cache at $PREFIX"
  fi
  say "Left ~/.config/death-terminal in place."
  printf '\nIf you added ~/.local/bin to PATH only for Death Terminal, remove that export from your shell profile.\n'
}

main() {
  if [ -z "${HOME:-}" ]; then
    die "HOME is not set"
  fi
  uninstall_mode=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --uninstall|-u|uninstall) uninstall_mode=1 ;;
      --help|-h) usage; exit 0 ;;
      *) die "unknown argument: $1 (try --help)" ;;
    esac
    shift
  done
  need_cmd uname
  if [ "$uninstall_mode" -eq 1 ]; then
    uninstall
    exit 0
  fi
  need_cmd curl
  need_cmd tar
  need_cmd mkdir
  need_cmd mktemp
  detect_platform
  build_and_install
}

if [ "${DEATHTERMINAL_INSTALL_LIB:-}" != "1" ]; then
  main "$@"
fi
