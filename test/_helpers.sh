# Shared helpers for mcp-locks tests. Source this from each test script.
#
# Provides:
#   - tmp HOME / STATE_DIR / REGISTRY_DIR so tests don't touch real state
#   - assert / assert_eq / assert_ne / assert_exit_code helpers
#   - automatic cleanup via trap

set -euo pipefail

: "${MCP_LOCKS:?MCP_LOCKS env var must be set by the runner}"

TMP_ROOT=$(mktemp -d -t mcp-locks-test.XXXXXX)
export MCP_LOCKS_HOME="$TMP_ROOT/home"
export MCP_LOCKS_STATE_DIR="$TMP_ROOT/state"
export MCP_LOCKS_REGISTRY_DIR="$TMP_ROOT/config"
mkdir -p "$MCP_LOCKS_HOME" "$MCP_LOCKS_STATE_DIR" "$MCP_LOCKS_REGISTRY_DIR"

cleanup() {
  rm -rf "$TMP_ROOT"
}
trap cleanup EXIT

# Wipe any sticky session env vars so detect_owner falls through predictably
# unless a test sets them.
unset OPENCODE_RUN_ID OPENCODE_SESSION_ID OPENCODE_PID
unset CLAUDECODE_SESSION_ID CLAUDE_SESSION_ID CLAUDECODE_PID

mcp() {
  "$MCP_LOCKS" "$@"
}

# Assertion helpers — print FAIL with line context, exit non-zero.
_fail() {
  echo "  ASSERTION FAILED: $*" >&2
  echo "  call site: ${BASH_SOURCE[2]}:${BASH_LINENO[1]}" >&2
  exit 1
}

assert() {
  local cond="$1" msg="${2:-condition false}"
  eval "$cond" || _fail "$msg"
}

assert_eq() {
  local got="$1" expected="$2" msg="${3:-not equal}"
  [ "$got" = "$expected" ] || _fail "$msg (got: '$got', expected: '$expected')"
}

assert_ne() {
  local got="$1" not_expected="$2" msg="${3:-equal when should not be}"
  [ "$got" != "$not_expected" ] || _fail "$msg (both: '$got')"
}

assert_exit_code() {
  local got="$1" expected="$2" msg="${3:-wrong exit code}"
  [ "$got" -eq "$expected" ] || _fail "$msg (got: $got, expected: $expected)"
}

assert_contains() {
  local haystack="$1" needle="$2" msg="${3:-substring not found}"
  case "$haystack" in
    *"$needle"*) ;;
    *) _fail "$msg (needle: '$needle' not in '$haystack')" ;;
  esac
}

pass_step() {
  echo "  ✓ $*"
}
