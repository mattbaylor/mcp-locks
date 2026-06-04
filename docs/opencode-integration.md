# OpenCode integration

How to wire `mcp-locks` into an OpenCode setup so agents reliably claim before using Playwright instances.

## Prerequisites

- OpenCode installed and running
- `mcp-locks` installed (see [../README.md](../README.md))
- At least one Playwright MCP slot configured in your `opencode.json` / `opencode.jsonc`

## Recommended OpenCode MCP config

Four Playwright slots, all enabled, all `--isolated`. With this, four agent sessions can run browsers simultaneously without OS-level collision; `mcp-locks` handles the cross-session coordination on top.

```jsonc
{
  "$schema": "https://opencode.ai/config.json",
  "mcp": {
    "playwright": {
      "type": "local",
      "command": ["npx", "-y", "@playwright/mcp@latest", "--isolated"],
      "enabled": true
    },
    "playwright2": {
      "type": "local",
      "command": ["npx", "-y", "@playwright/mcp@latest", "--isolated"],
      "enabled": true
    },
    "playwright3": {
      "type": "local",
      "command": ["npx", "-y", "@playwright/mcp@latest", "--isolated"],
      "enabled": true
    },
    "playwright4": {
      "type": "local",
      "command": ["npx", "-y", "@playwright/mcp@latest", "--isolated"],
      "enabled": true
    }
  }
}
```

> **Restart opencode** after editing the config. The MCP server list is read at startup; running servers don't pick up command-line changes.

## OpenCode exports the right env vars

OpenCode exports `OPENCODE_RUN_ID` (per-session UUID) and `OPENCODE_PID` (TUI/web process PID) into every tool-shell. `mcp-locks` auto-detects both — you don't need to pass `--owner` from an OpenCode-driven agent prompt.

Verify in any bash tool call:

```bash
env | grep -E '^OPENCODE_(RUN_ID|PID)'
# Expect both set.
```

## Agent prompt pattern

In any prompt that uses a Playwright instance, the workflow is:

```
1. mcp-locks claim <instance> --ttl 30m --note "what you're doing"
   → exit 0: proceed
   → exit 2: another session owns it; pick a different instance or escalate

2. ... do work via <instance>_browser_* ...

3. mcp-locks release <instance>
```

The `--owner` flag is auto-detected — don't pass it.

## Role conventions

Suggested defaults so agents don't collide by default:

| Instance | Default role |
|---|---|
| `playwright` | PR branch / primary work |
| `playwright2` | Master baseline / "before" half of comparisons |
| `playwright3` | Third site (staging, secondary worktree) |
| `playwright4` | Sub-agent / parallel verification |

These are conventions, not enforced. The CLI is content-agnostic.

## Slash command integration

If you have OpenCode slash commands for browser-heavy workflows (e.g. `/test`, `/review-pr`), bake the claim/release into the command template.

Example for a `/review-pr` command that does a side-by-side master/PR comparison:

```markdown
---
description: Review an open PR with side-by-side master/PR browser comparison
---

You are reviewing PR $1.

Before navigating either browser:

1. Run: `mcp-locks claim playwright --ttl 30m --note "PR $1 review"`
2. Run: `mcp-locks claim playwright2 --ttl 30m --note "PR $1 review master baseline"`

If either DENIES, surface to the human and ask which instance to use instead.

... rest of the prompt ...

At the end of the review (or on error):

- Run: `mcp-locks release playwright`
- Run: `mcp-locks release playwright2`
```

## Sub-agent dispatch

**Parent claims, sub-agent uses, parent releases.** Sub-agents do NOT claim or release — they'd race with the parent's lifecycle and TTL.

Sub-agent dispatch prompt (paste into the dispatch call):

```
Use `playwright3_browser_*` tools for all browser interaction in this task. Do NOT touch `playwright_browser_*` or `playwright2_browser_*` — those are owned by the main thread. Do NOT run `mcp-locks claim` or `mcp-locks release` — the parent session has already coordinated locks.
```

## Verification at session start (optional)

If a flow depends on multiple instances being available, probe at the start:

```bash
mcp-locks list
# Look for the instances you need; if any are claimed by another session,
# either wait, force-steal with reason, or pick a different strategy.
```

This is cheaper than the older "probe by calling `browser_resize` on each" pattern because it doesn't actually launch Chromium — just reads the state file.

## Handling DENIED gracefully

When `mcp-locks claim` returns exit 2:

1. **Read who owns it:** `mcp-locks who <instance>` shows the owner ID, age, and remaining TTL.
2. **If TTL is short** (e.g. under 5m), wait and retry.
3. **If TTL is long** but you have higher priority, `--force` with a `--note` explaining why.
4. **If you don't know what's safe**, surface to the human. Don't just steal.
5. **If the system is stuck** (claims that look dead but aren't being reaped), run `mcp-locks doctor` and `mcp-locks reap` manually.

## Cleanup on session end

If your client supports a session-end hook, call `mcp-locks release` for any instances you claimed. Otherwise rely on TTL expiry (default 30m) and the twice-daily reaper.

## Logging from agents

Agents that shell out to inspect the reaper log should use **absolute paths**, not `~`. From inside any sandbox (devcontainer, isolated agent runtime, etc.), `~` resolves to the sandbox HOME, not the real HOME where the log lives:

```bash
# Wrong (from a sandbox):
tail ~/.local/state/mcp-locks/reap.log

# Right:
tail /Users/$USER/.local/state/mcp-locks/reap.log
# or just:
mcp-locks doctor  # reports the real paths and current health
```
