#!/usr/bin/env bash
# Test owner-ID detection priority and PID source selection.

. "$(dirname "$0")/_helpers.sh"

mcp list >/dev/null  # bootstrap

# Helper: claim an instance, read back the owner+pid, release.
get_owner_for_env() {
  local instance="$1"
  mcp claim "$instance" --note "owner-detect test" >/dev/null
  jq -r ".instances.\"$instance\".owner" "$MCP_LOCKS_STATE_DIR/state.json"
}

get_pid_for_env() {
  local instance="$1"
  jq -r ".instances.\"$instance\".owner_pid" "$MCP_LOCKS_STATE_DIR/state.json"
}

release_quietly() {
  mcp release "$1" --force >/dev/null 2>&1 || true
}

# ---- OPENCODE_RUN_ID wins over everything ----
release_quietly playwright
export OPENCODE_RUN_ID="run-id-uuid" OPENCODE_SESSION_ID="session-id" OPENCODE_PID="12345"
export CLAUDECODE_SESSION_ID="claude-id" CLAUDECODE_PID="67890"
out=$(get_owner_for_env playwright)
assert_eq "$out" "opencode:run-id-uuid" "OPENCODE_RUN_ID should win"
pid=$(get_pid_for_env playwright)
assert_eq "$pid" "12345" "OPENCODE_PID should be the liveness PID"
pass_step "OPENCODE_RUN_ID + OPENCODE_PID wins"

# ---- OPENCODE_SESSION_ID is second priority ----
release_quietly playwright
unset OPENCODE_RUN_ID
export OPENCODE_SESSION_ID="session-id" OPENCODE_PID="22222"
out=$(get_owner_for_env playwright)
assert_eq "$out" "opencode:session-id" "OPENCODE_SESSION_ID should be 2nd priority"
pid=$(get_pid_for_env playwright)
assert_eq "$pid" "22222" "OPENCODE_PID still used"
pass_step "OPENCODE_SESSION_ID second priority"

# ---- CLAUDECODE_SESSION_ID third ----
release_quietly playwright
unset OPENCODE_SESSION_ID OPENCODE_PID
export CLAUDECODE_SESSION_ID="claude-id" CLAUDECODE_PID="33333"
out=$(get_owner_for_env playwright)
assert_eq "$out" "claude:claude-id" "CLAUDECODE_SESSION_ID should be 3rd priority"
pid=$(get_pid_for_env playwright)
assert_eq "$pid" "33333" "CLAUDECODE_PID used as liveness PID"
pass_step "CLAUDECODE_SESSION_ID third priority"

# ---- CLAUDE_SESSION_ID fourth ----
release_quietly playwright
unset CLAUDECODE_SESSION_ID CLAUDECODE_PID
export CLAUDE_SESSION_ID="alt-claude-id"
out=$(get_owner_for_env playwright)
assert_eq "$out" "claude:alt-claude-id" "CLAUDE_SESSION_ID should be 4th priority"
pass_step "CLAUDE_SESSION_ID fourth priority"

# ---- Bash fallback last ----
release_quietly playwright
unset CLAUDE_SESSION_ID
out=$(get_owner_for_env playwright)
# Owner should be <something>:<PPID-of-the-mcp-locks-call>. We can't know
# the exact PID without a dance — just verify shape (contains a colon).
assert_contains "$out" ":" "fallback owner should be 'name:pid'"
pass_step "shell:PPID fallback when no env vars set"

# ---- --owner explicit beats everything ----
release_quietly playwright
export OPENCODE_RUN_ID="should-be-ignored" OPENCODE_PID="99999"
mcp claim playwright --owner "explicit:override" --note "explicit owner" >/dev/null
owner=$(jq -r '.instances.playwright.owner' "$MCP_LOCKS_STATE_DIR/state.json")
assert_eq "$owner" "explicit:override" "--owner should win over env vars"
pass_step "--owner explicit beats env vars"
unset OPENCODE_RUN_ID OPENCODE_PID

# Cleanup
release_quietly playwright

echo "  All owner-detection tests passed."
