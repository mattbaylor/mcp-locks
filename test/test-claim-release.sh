#!/usr/bin/env bash
# Test claim / release / refresh / deny semantics.

. "$(dirname "$0")/_helpers.sh"

# Bootstrap with a list call so registry + state are written.
mcp list >/dev/null
pass_step "bootstrap creates state and registry"

# ---- Claim a free instance ----
mcp claim playwright --note "test 1" >/dev/null
pass_step "claim on free instance succeeds"

# ---- Re-claim by same owner refreshes ----
mcp claim playwright --note "test 1 refresh" >/dev/null
pass_step "re-claim by same owner refreshes (no DENIED)"

# ---- Claim by different owner DENIES ----
set +e
OPENCODE_RUN_ID=other-uuid OPENCODE_PID=$$ mcp claim playwright --note "stealer" >/dev/null 2>&1
code=$?
set -e
assert_exit_code "$code" 2 "different owner should be DENIED with exit 2"
pass_step "claim by different owner DENIES with exit 2"

# ---- Release by wrong owner DENIES ----
set +e
OPENCODE_RUN_ID=other-uuid OPENCODE_PID=$$ mcp release playwright >/dev/null 2>&1
code=$?
set -e
assert_exit_code "$code" 2 "release by wrong owner should be DENIED with exit 2"
pass_step "release by wrong owner DENIES with exit 2"

# ---- Release by correct owner succeeds ----
mcp release playwright >/dev/null
pass_step "release by correct owner succeeds"

# ---- After release, who reports free + exit 1 ----
set +e
output=$(mcp who playwright 2>&1)
code=$?
set -e
assert_exit_code "$code" 1 "who on free instance should exit 1"
assert_contains "$output" "free" "who output should say 'free'"
pass_step "after release, who reports free with exit 1"

# ---- Force-steal works ----
mcp claim playwright --note "original" >/dev/null
OPENCODE_RUN_ID=stealer-uuid OPENCODE_PID=$$ mcp claim playwright --note "stolen" --force >/dev/null
output=$(mcp who playwright)
assert_contains "$output" "stealer-uuid" "force-steal should swap owner"
pass_step "force-steal swaps owner"

# ---- Unknown instance returns exit 2 ----
set +e
mcp claim nonexistent-instance >/dev/null 2>&1
code=$?
set -e
assert_exit_code "$code" 2 "unknown instance should exit 2"
pass_step "unknown instance returns exit 2"

# ---- TTL accepts m/h/s suffixes ----
for ttl in 30s 5m 2h; do
  mcp claim playwright2 --owner "ttl-test" --ttl "$ttl" >/dev/null
  mcp release playwright2 --owner "ttl-test" >/dev/null
done
pass_step "TTL accepts s/m/h suffixes"

echo "  All claim/release tests passed."
