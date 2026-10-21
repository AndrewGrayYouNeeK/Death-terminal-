#!/usr/bin/env bash
# Skip-path contract for sign-release.sh. No Apple certificate and no codesign.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(mktemp -d)
trap 'rm -rf "$ROOT"' EXIT

mkdir -p "$ROOT/in/aarch64-macos" "$ROOT/in/x86_64-macos" "$ROOT/flat" "$ROOT/out-none" "$ROOT/out-partial" "$ROOT/out-flat" "$ROOT/out-full"
echo 'zip-arm' > "$ROOT/in/aarch64-macos/DeathTerminal-0.1.0-aarch64.zip"
echo 'dmg-arm' > "$ROOT/in/aarch64-macos/DeathTerminal-0.1.0-aarch64.dmg"
echo 'tar-arm' > "$ROOT/in/aarch64-macos/deathterminal-0.1.0-aarch64-macos.tar.gz"
echo 'zip-intel' > "$ROOT/in/x86_64-macos/DeathTerminal-0.1.0-x86_64.zip"
echo 'dmg-intel' > "$ROOT/in/x86_64-macos/DeathTerminal-0.1.0-x86_64.dmg"
echo 'tar-intel' > "$ROOT/in/x86_64-macos/deathterminal-0.1.0-x86_64-macos.tar.gz"
echo 'zip-flat' > "$ROOT/flat/DeathTerminal-9.9.9-aarch64.zip"
echo 'tar-flat' > "$ROOT/flat/deathterminal-9.9.9-aarch64-macos.tar.gz"

run_clean() {
  (
    unset CSC_LINK CSC_KEY_PASSWORD CODESIGN_IDENTITY APPLE_ID APPLE_APP_PASSWORD APPLE_TEAM_ID
    "$@"
  )
}

run_clean bash "$HERE/sign-release.sh" "$ROOT/in" "$ROOT/out-none"
cmp "$ROOT/in/aarch64-macos/DeathTerminal-0.1.0-aarch64.zip" "$ROOT/out-none/DeathTerminal-0.1.0-aarch64.zip"
cmp "$ROOT/in/aarch64-macos/DeathTerminal-0.1.0-aarch64.dmg" "$ROOT/out-none/DeathTerminal-0.1.0-aarch64.dmg"
cmp "$ROOT/in/aarch64-macos/deathterminal-0.1.0-aarch64-macos.tar.gz" "$ROOT/out-none/deathterminal-0.1.0-aarch64-macos.tar.gz"
cmp "$ROOT/in/x86_64-macos/DeathTerminal-0.1.0-x86_64.zip" "$ROOT/out-none/DeathTerminal-0.1.0-x86_64.zip"
cmp "$ROOT/in/x86_64-macos/DeathTerminal-0.1.0-x86_64.dmg" "$ROOT/out-none/DeathTerminal-0.1.0-x86_64.dmg"
cmp "$ROOT/in/x86_64-macos/deathterminal-0.1.0-x86_64-macos.tar.gz" "$ROOT/out-none/deathterminal-0.1.0-x86_64-macos.tar.gz"

# One secret is not enough: still unsigned, still success.
(
  unset CSC_KEY_PASSWORD CODESIGN_IDENTITY APPLE_ID APPLE_APP_PASSWORD APPLE_TEAM_ID
  CSC_LINK=aaaa bash "$HERE/sign-release.sh" "$ROOT/in" "$ROOT/out-partial"
)
cmp "$ROOT/in/aarch64-macos/DeathTerminal-0.1.0-aarch64.zip" "$ROOT/out-partial/DeathTerminal-0.1.0-aarch64.zip"

run_clean bash "$HERE/sign-release.sh" "$ROOT/flat" "$ROOT/out-flat"
cmp "$ROOT/flat/DeathTerminal-9.9.9-aarch64.zip" "$ROOT/out-flat/DeathTerminal-9.9.9-aarch64.zip"
cmp "$ROOT/flat/deathterminal-9.9.9-aarch64-macos.tar.gz" "$ROOT/out-flat/deathterminal-9.9.9-aarch64-macos.tar.gz"

# Every secret set, but this machine cannot sign. Must fail, and must not
# present the unsigned zip as a successful signed output.
set +e
(
  export CSC_LINK=aaaa CSC_KEY_PASSWORD=bbbb
  export CODESIGN_IDENTITY="Developer ID Application: Test (TEAMID)"
  export APPLE_ID=dev@example.com APPLE_APP_PASSWORD=app-password APPLE_TEAM_ID=TEAMID1234
  bash "$HERE/sign-release.sh" "$ROOT/in" "$ROOT/out-full"
)
status=$?
set -e
if [ "$status" -eq 0 ]; then
  echo "expected non-zero when signing secrets are set and codesign is unavailable" >&2
  exit 1
fi
if [ -f "$ROOT/out-full/DeathTerminal-0.1.0-aarch64.zip" ]; then
  echo "signing failure still wrote an output zip" >&2
  exit 1
fi

echo "sign-release skip path ok"
