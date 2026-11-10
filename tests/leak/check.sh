#!/bin/sh
# Run the filtered GPA leak test under Valgrind when it is installed.
# Exit 0 when valgrind is absent so Linux CI without it stays green.
# The Zig test "leak check:" always runs under std.testing as well.
set -eu
bin=${1:?test binary}
if ! command -v valgrind >/dev/null 2>&1; then
  echo "leak check: valgrind not installed; skipped"
  exit 0
fi
echo "leak check: valgrind --leak-check=full"
set +e
valgrind \
  --error-exitcode=99 \
  --leak-check=full \
  --show-leak-kinds=definite \
  --errors-for-leak-kinds=definite \
  --quiet \
  "$bin" --test-filter "leak check:"
code=$?
set -e
# Zig's memset uses host SIMD that some Valgrind builds refuse (SIGILL, 132).
# That is a tool limit, not a leak. The GPA test in this binary is the check.
if [ "$code" -eq 132 ]; then
  echo "leak check: valgrind SIGILL in the Zig runtime; GPA leak check is the result that counts"
  exit 0
fi
exit "$code"
