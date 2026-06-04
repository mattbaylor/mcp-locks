#!/usr/bin/env bash
# Test reaper: expired claims, dead-PID claims, idempotency.
#
# The OS-level cleanup steps (orphan Chromium kill, stale SingletonLock
# removal) are not unit-tested here — they require actually running browser
# processes and have to be exercised in integration. The generic steps
# (expired-claim, dead-PID-claim) ARE testable in isolation.

. "$(dirname "$0")/_helpers.sh"

mcp list >/dev/null  # bootstrap

# ---- Reap with nothing to do is a no-op ----
out=$(mcp reap 2>&1)
assert_contains "$out" "0 claims cleared" "empty reap should clear 0 claims"
pass_step "reap on empty state is no-op"

# ---- Inject an expired claim, reap clears it ----
STATE_FILE="$MCP_LOCKS_STATE_DIR/state.json"
jq '.instances.playwright3 = {
  owner: "opencode:fake-expired-uuid",
  owner_pid: 1,
  claimed_at: "2020-01-01T00:00:00Z",
  expires_at: "2020-01-01T00:30:00Z",
  note: "ancient"
}' "$STATE_FILE" > "$STATE_FILE.tmp"
mv "$STATE_FILE.tmp" "$STATE_FILE"

out=$(mcp reap 2>&1)
assert_contains "$out" "1 claims cleared" "should clear 1 expired claim"
owner=$(jq -r '.instances.playwright3.owner' "$STATE_FILE")
assert_eq "$owner" "null" "expired claim should be released after reap"
pass_step "reap clears expired claim"

# ---- Inject a dead-PID claim with opencode: prefix, reap clears it ----
# Find a PID guaranteed to be dead. PID 1 is alive (init/launchd). Use a
# very high number that's vanishingly unlikely to exist.
DEAD_PID=999999
jq --argjson pid "$DEAD_PID" '.instances.playwright4 = {
  owner: "opencode:fake-session-uuid",
  owner_pid: $pid,
  claimed_at: "'"$(date -u +%Y-%m-%dT%H:%M:%SZ)"'",
  expires_at: "'"$(date -u -v+1H +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '+1 hour' +%Y-%m-%dT%H:%M:%SZ)"'",
  note: "dead host"
}' "$STATE_FILE" > "$STATE_FILE.tmp"
mv "$STATE_FILE.tmp" "$STATE_FILE"

out=$(mcp reap 2>&1)
assert_contains "$out" "1 claims cleared" "should clear 1 dead-PID claim"
owner=$(jq -r '.instances.playwright4.owner' "$STATE_FILE")
assert_eq "$owner" "null" "dead-PID claim should be released"
pass_step "reap clears dead-PID claim with opencode: owner"

# ---- Dead-PID claim with bash: owner is NOT reaped ----
# Bash/PPID owners have ephemeral PIDs by design; reaper waits for TTL.
jq --argjson pid "$DEAD_PID" '.instances.playwright = {
  owner: "bash:'"$DEAD_PID"'",
  owner_pid: $pid,
  claimed_at: "'"$(date -u +%Y-%m-%dT%H:%M:%SZ)"'",
  expires_at: "'"$(date -u -v+1H +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '+1 hour' +%Y-%m-%dT%H:%M:%SZ)"'",
  note: "ephemeral shell"
}' "$STATE_FILE" > "$STATE_FILE.tmp"
mv "$STATE_FILE.tmp" "$STATE_FILE"

out=$(mcp reap 2>&1)
assert_contains "$out" "0 claims cleared" "bash: owner with dead PID should NOT be reaped"
owner=$(jq -r '.instances.playwright.owner' "$STATE_FILE")
assert_ne "$owner" "null" "bash: claim with valid TTL should survive reap even if PID is dead"
pass_step "reap does NOT clear dead-PID bash: claim (waits for TTL)"

# ---- Reap is idempotent ----
mcp reap >/dev/null
mcp reap >/dev/null
mcp reap >/dev/null
pass_step "reap is idempotent (3 runs, no errors)"

# ---- Reap log has entries ----
log="$MCP_LOCKS_STATE_DIR/reap.log"
assert "[ -f '$log' ]" "reap.log should exist"
assert "[ -s '$log' ]" "reap.log should be non-empty"
pass_step "reap.log captures activity"

echo "  All reaper tests passed."
