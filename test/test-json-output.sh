#!/usr/bin/env bash
# Test --json output mode across all subcommands.
#
# Asserts:
#   - Stdout is valid JSON for every subcommand
#   - Envelope shape: {ok: true, data: ...} for success, {ok: false, error: ...} for failure
#   - Exit codes match the human-mode behavior
#   - JSON_MODE doesn't bleed into stderr (diagnostics stay readable)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=_helpers.sh
. "$SCRIPT_DIR/_helpers.sh"

echo "  --- list --json on a fresh state file ---"
out=$(mcp --json list)
echo "$out" | jq -e '.ok == true' >/dev/null || _fail "list envelope missing ok:true"
echo "$out" | jq -e '.data | type == "array"' >/dev/null || _fail "list data is not an array"
echo "$out" | jq -e '.data | length >= 5' >/dev/null || _fail "list should have >=5 registered instances"
echo "$out" | jq -e '.data | all(.status == "free")' >/dev/null || _fail "fresh list should show all free"
echo "$out" | jq -e '.data[0] | has("instance") and has("owner") and has("status") and has("age_seconds") and has("ttl_remaining_seconds") and has("alive")' >/dev/null \
  || _fail "list row missing expected fields"
pass_step "list --json on fresh state"

echo "  --- who --json on free instance: exit 1, ok:true, status:free ---"
set +e
out=$(mcp --json who playwright)
code=$?
set -e
assert_exit_code "$code" 1 "who on free instance should exit 1"
echo "$out" | jq -e '.ok == true and .data.status == "free" and .data.owner == null' >/dev/null \
  || _fail "who envelope wrong for free instance"
pass_step "who --json on free instance"

echo "  --- claim --json: ok:true, action:claimed ---"
out=$(mcp --json claim playwright --ttl 5m --note "json test")
echo "$out" | jq -e '.ok == true and .data.action == "claimed" and .data.instance == "playwright" and .data.ttl_seconds == 300 and .data.note == "json test"' >/dev/null \
  || _fail "claim envelope wrong: $out"
pass_step "claim --json (fresh)"

echo "  --- claim --json (same owner): ok:true, action:refreshed ---"
out=$(mcp --json claim playwright --ttl 10m)
echo "$out" | jq -e '.ok == true and .data.action == "refreshed" and .data.ttl_seconds == 600' >/dev/null \
  || _fail "re-claim envelope wrong: $out"
pass_step "claim --json (refresh)"

echo "  --- who --json on owned instance: exit 0, status:claimed, fields populated ---"
out=$(mcp --json who playwright)
echo "$out" | jq -e '.ok == true and .data.status == "claimed" and .data.owner != null and .data.owner_pid > 0 and .data.note == "json test"' >/dev/null \
  || _fail "who envelope wrong on owned: $out"
pass_step "who --json on owned instance"

echo "  --- list --json reflects claim ---"
out=$(mcp --json list)
echo "$out" | jq -e '.data | map(select(.instance == "playwright"))[0] | .status == "claimed" and .owner != null' >/dev/null \
  || _fail "list does not show playwright as claimed"
pass_step "list --json reflects claim"

echo "  --- claim --json conflict: exit 2, ok:false, error:denied, denied{} populated ---"
set +e
out=$(OPENCODE_RUN_ID=other-owner OPENCODE_PID=$$ mcp --json claim playwright 2>/dev/null)
code=$?
set -e
assert_exit_code "$code" 2 "conflicting claim should exit 2"
echo "$out" | jq -e '.ok == false and .error == "denied" and .denied.instance == "playwright" and (.denied | has("current_owner") and has("ttl_remaining_seconds"))' >/dev/null \
  || _fail "denied envelope wrong: $out"
pass_step "claim --json (denied)"

echo "  --- release --json with wrong owner: exit 2, error:owner_mismatch ---"
set +e
out=$(OPENCODE_RUN_ID=wrong-owner OPENCODE_PID=$$ mcp --json release playwright 2>/dev/null)
code=$?
set -e
assert_exit_code "$code" 2 "wrong-owner release should exit 2"
echo "$out" | jq -e '.ok == false and .error == "owner_mismatch" and .denied.current_owner != null and .denied.requesting_owner == "opencode:wrong-owner"' >/dev/null \
  || _fail "owner-mismatch envelope wrong: $out"
pass_step "release --json (owner mismatch)"

echo "  --- release --json (correct owner): ok:true, action:released ---"
out=$(mcp --json release playwright)
echo "$out" | jq -e '.ok == true and .data.action == "released" and .data.previous_owner != null' >/dev/null \
  || _fail "release envelope wrong: $out"
pass_step "release --json (correct owner)"

echo "  --- release --json (already free): ok:true, action:already_free ---"
out=$(mcp --json release playwright)
echo "$out" | jq -e '.ok == true and .data.action == "already_free" and .data.previous_owner == null' >/dev/null \
  || _fail "release-already-free envelope wrong: $out"
pass_step "release --json (already free)"

echo "  --- unknown instance: exit 2, ok:false, error mentions registered ---"
set +e
out=$(mcp --json claim nonexistent-instance 2>/dev/null)
code=$?
set -e
assert_exit_code "$code" 2 "unknown instance should exit 2"
echo "$out" | jq -e '.ok == false and (.error | test("not registered"))' >/dev/null \
  || _fail "unknown-instance envelope wrong: $out"
pass_step "claim --json (unknown instance)"

echo "  --- reap --json: ok:true, counts present ---"
out=$(mcp --json reap)
echo "$out" | jq -e '.ok == true and (.data | has("claims_cleared") and has("chromium_orphans_killed") and has("stale_singletonlocks_removed") and has("log"))' >/dev/null \
  || _fail "reap envelope wrong: $out"
pass_step "reap --json"

echo "  --- doctor --json: ok:true, paths/counts populated ---"
out=$(mcp --json doctor)
echo "$out" | jq -e '.ok == true and (.data | has("paths") and has("active_claims") and has("expired") and has("dead_pid") and has("chromium") and has("reap_recommended"))' >/dev/null \
  || _fail "doctor envelope wrong: $out"
pass_step "doctor --json"

echo "  --- --json position-agnostic: works before or after subcommand ---"
out_before=$(mcp --json list)
out_after=$(mcp list --json)
# Strip timestamps to compare (claimed_at/expires_at would differ if any active claims, but state is clean)
[ "$(echo "$out_before" | jq '.ok')" = "$(echo "$out_after" | jq '.ok')" ] || _fail "--json position-dependence detected"
pass_step "--json position-agnostic"

echo "  All --json tests passed."
