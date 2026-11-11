#!/bin/sh
# `zig build test` entry for the local-sshd suite (agent, encrypted key,
# keyboard-interactive, ProxyJump, and the rest of tests/ssh/run.py).
# Exit 77 from that suite means sshd or passwordless sudo is missing.
set -eu
bin=${1:?deathterminal binary}
set +e
python3 tests/ssh/run.py "$bin"
code=$?
set -e
if [ "$code" -eq 77 ]; then
  echo "ssh integration: SKIPPED (no sshd or passwordless sudo)."
  echo "Still unverified in this environment: agent auth, encrypted key, keyboard-interactive, ProxyJump hop."
  echo "Run \`zig build test-ssh\` on a machine with openssh-server and passwordless sudo."
  exit 0
fi
exit "$code"
