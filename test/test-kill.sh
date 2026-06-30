#!/usr/bin/env bash
# Test the `kill` subcommand.
#
# IMPORTANT: pgrep cannot be sandboxed — it always sees the real process
# table. Tests below cover argument validation and JSON envelope shape on
# negative paths (refusals, errors, mutual exclusion). They DO NOT invoke
# code paths that would call pgrep against real Chromium processes, because
# doing so would kill the developer's real running browsers if any are open.
#
# Real kill behavior is verified manually: spawn a Playwright MCP, run
# `mcp-locks kill --all --force`, observe the Chromium dies.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=_helpers.sh
. "$SCRIPT_DIR/_helpers.sh"

# ---- Per-instance kill is not implemented in v1 -----------------------------
echo "  --- kill <instance>: not implemented in v1 ---"
set +e
out=$(mcp --json kill playwright 2>/dev/null)
code=$?
set -e
assert_exit_code "$code" 1 "kill <instance> should exit 1 (not implemented)"
echo "$out" | jq -e '.ok == false and (.error | test("not implemented"))' >/dev/null \
  || _fail "v1 kill <instance> envelope wrong: $out"
pass_step "kill <instance> returns not-implemented error"

# ---- Missing target ----------------------------------------------------------
echo "  --- kill (no args): error, exit 1 ---"
set +e
out=$(mcp --json kill 2>/dev/null)
code=$?
set -e
assert_exit_code "$code" 1 "kill with no args should exit 1"
echo "$out" | jq -e '.ok == false and (.error | test("missing target"))' >/dev/null \
  || _fail "no-target envelope wrong: $out"
pass_step "kill with no target rejects"

# ---- --all without safety flag ----------------------------------------------
echo "  --- kill --all (no --idle-only/--force): error, exit 1 ---"
set +e
out=$(mcp --json kill --all 2>/dev/null)
code=$?
set -e
assert_exit_code "$code" 1 "kill --all without safety flag should exit 1"
echo "$out" | jq -e '.ok == false and (.error | test("requires --idle-only"))' >/dev/null \
  || _fail "--all without safety envelope wrong: $out"
pass_step "kill --all without safety flag rejects"

# ---- --orphans mutually exclusive with --all/--idle-only/--force ------------
echo "  --- kill --orphans --all: error, exit 1 ---"
set +e
out=$(mcp --json kill --orphans --all 2>/dev/null)
code=$?
set -e
assert_exit_code "$code" 1 "kill --orphans --all should exit 1"
echo "$out" | jq -e '.ok == false and (.error | test("mutually exclusive"))' >/dev/null \
  || _fail "--orphans+--all envelope wrong: $out"
pass_step "kill --orphans is mutually exclusive with --all"

# ---- --all --idle-only refused if any instance is claimed -------------------
echo "  --- kill --all --idle-only with active claim: refused, exit 2 ---"
mcp claim playwright --note "kill-test" >/dev/null
set +e
out=$(mcp --json kill --all --idle-only 2>/dev/null)
code=$?
set -e
assert_exit_code "$code" 2 "--idle-only should refuse with exit 2 when claims exist"
echo "$out" | jq -e '.ok == false and .error == "instances_claimed" and .active_claims == 1 and .mode == "idle-only"' >/dev/null \
  || _fail "idle-only-refused envelope wrong: $out"
pass_step "kill --all --idle-only refuses when claims exist"
mcp release playwright >/dev/null

# NOTE: We intentionally do NOT exercise the success paths
# (--all --idle-only on a clean state, --all --force, --orphans) because
# they invoke pgrep against the real process table. Doing so in a test
# environment would silently kill the developer's running Playwright
# Chromiums, which is destructive across the developer's other workflows.
#
# Real-system verification recipe (manual, not run by run-all.sh):
#   1. Start a Playwright MCP:  npx -y @playwright/mcp@latest --isolated &
#   2. Trigger Chromium spawn:  (any tool call that opens a page)
#   3. mcp-locks --json kill --all --force
#   4. Assert: killed >= 1, no playwright_chromiumdev_profile- in pgrep

echo "  All kill tests passed."
