#!/usr/bin/env bash
# Runs the SSH/SFTP/port-forward/known-hosts core of the iOS app against a
# throwaway local sshd. Works on Linux or macOS with a Swift 5.9+ toolchain.
# This exercises the real app sources (symlinked into Sources/Core); only the
# Keychain and Combine are stubbed.
set -euo pipefail
cd "$(dirname "$0")"
T=$(mktemp -d)
trap 'kill $(cat "$T/sshd.pid" 2>/dev/null) $HTTP_PID 2>/dev/null || true; rm -rf "$T"' EXIT
ssh-keygen -q -t ed25519 -N '' -f "$T/hk_ed25519"
ssh-keygen -q -t ed25519 -N '' -f "$T/ck_ed25519"
ssh-keygen -q -t rsa -b 3072 -N 'pp123' -f "$T/ck_rsa"
cat "$T/ck_ed25519.pub" "$T/ck_rsa.pub" > "$T/authorized_keys"; chmod 600 "$T/authorized_keys"
cat > "$T/sshd_config" <<CFG
Port 2222
ListenAddress 127.0.0.1
HostKey $T/hk_ed25519
AuthorizedKeysFile $T/authorized_keys
PidFile $T/sshd.pid
StrictModes no
PasswordAuthentication no
UsePAM no
Subsystem sftp internal-sftp
AllowTcpForwarding yes
PubkeyAcceptedAlgorithms +ssh-rsa
CFG
"$(command -v sshd || echo /usr/sbin/sshd)" -f "$T/sshd_config" -E "$T/sshd.log"
mkdir -p "$T/www"; echo tunnel-ok > "$T/www/hello.txt"
(cd "$T/www" && exec python3 -m http.server 28432 --bind 127.0.0.1 >/dev/null 2>&1) & HTTP_PID=$!
sleep 1
swift build
DT_SSH_DIR="$T" DT_USER="$(whoami)" .build/debug/smoke 2>&1 | grep -v "info nl.orlandos" || { echo "--- sshd.log"; tail -5 "$T/sshd.log"; exit 1; }
