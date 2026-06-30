#!/usr/bin/env bash
# Run all mcp-locks tests against the built binary.
#
# Each test runs in an isolated temp dir (MCP_LOCKS_HOME, MCP_LOCKS_STATE_DIR,
# MCP_LOCKS_REGISTRY_DIR are pointed there) so tests don't touch real state.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
MCP_LOCKS="$REPO_DIR/bin/mcp-locks"

if [ ! -x "$MCP_LOCKS" ]; then
  echo "ERROR: $MCP_LOCKS not found or not executable" >&2
  exit 1
fi

# Each test sets up its own tmp; we just dispatch.
TESTS=(
  test-claim-release.sh
  test-reaper.sh
  test-owner-detect.sh
  test-json-output.sh
)

pass=0
fail=0
for t in "${TESTS[@]}"; do
  echo ""
  echo "=== $t ==="
  if MCP_LOCKS="$MCP_LOCKS" bash "$TEST_DIR/$t"; then
    pass=$((pass + 1))
  else
    echo "FAIL: $t" >&2
    fail=$((fail + 1))
  fi
done

echo ""
echo "==============================="
echo "  $pass passed, $fail failed"
echo "==============================="
[ "$fail" -eq 0 ]
