# mcp-locks

Cross-client checkout/lock manager for MCP servers that hold exclusive OS resources.

If you run [OpenCode](https://opencode.ai), [Claude Code](https://www.anthropic.com/claude-code), or any other MCP-aware agent on the same machine, and you use the [Playwright MCP server](https://github.com/microsoft/playwright-mcp), you've probably hit this:

```
Browser is already in use for …mcp-chrome-<hash>, use --isolated to run multiple instances of the same browser
```

That's the OS-level symptom of multiple MCP server processes fighting over a shared Chromium profile dir. **Adding `--isolated` to the Playwright MCP command fixes the OS collision.** But it doesn't solve the higher-level problem: multiple agent sessions (across clients, across sandboxes) still have no way to know whether `playwright2` is currently owned by another session and will silently stomp on each other if both grab it.

`mcp-locks` is the coordination layer. Claim an instance before you use it, release it when you're done. A twice-daily reaper cleans up missed releases and stale OS state.

## Status

Early. Working in production on the author's machine since 2026-06-04. Not yet versioned or tagged. The CLI surface is stable; the state file has a `version: 1` field for future migrations.

## Requirements

- macOS (Linux support is best-effort; the LaunchAgent installer is macOS-only)
- `bash` 4+ (macOS ships 3.2 — use `brew install bash` if you want strict-mode behavior to be exhaustive)
- `jq` (`brew install jq`)
- `sudo` access for the install-time symlink into `/usr/local/bin`

## Install

```bash
git clone https://github.com/mattbaylor/mcp-locks.git
cd mcp-locks
./install.sh
```

The installer is idempotent. It:
1. Copies `bin/mcp-locks` to `~/bin/mcp-locks` (or `$MCP_LOCKS_BIN_DIR` if set)
2. Symlinks to `/usr/local/bin/mcp-locks` (requires sudo)
3. Renders `share/launchagent.template.plist` → `~/Library/LaunchAgents/com.${USER}.mcp-locks-reap.plist`
4. Loads the LaunchAgent (runs reaper at 09:00 and 14:00 daily)
5. Kickstart once to verify end-to-end

Uninstall: `./uninstall.sh`.

## Configure

The registry at `~/.config/mcp-locks/registry.json` declares which MCP instances are lockable. Bootstrapped with sensible defaults; edit to suit your config:

```json
{
  "instances": {
    "playwright":    { "kind": "playwright-mcp" },
    "playwright2":   { "kind": "playwright-mcp" },
    "playwright3":   { "kind": "playwright-mcp" },
    "playwright4":   { "kind": "playwright-mcp" },
    "figma-desktop": { "kind": "figma-desktop-mcp", "port": 3845 }
  }
}
```

The instance name should match the name in your MCP client's config (OpenCode's `mcp.<name>` key, Claude Code's equivalent). The `kind` field drives kind-specific reaper behavior — see [docs/architecture.md](docs/architecture.md).

Also recommended: add `--isolated` to every `@playwright/mcp` command in your client config. Without it, Chromium itself will block multiple instances even before `mcp-locks` gets involved.

```jsonc
// In your opencode.json / claude config
"playwright2": {
  "type": "local",
  "command": ["npx", "-y", "@playwright/mcp@latest", "--isolated"],
  "enabled": true
}
```

## Usage

### Agent prompt pattern

The contract for any agent prompt that uses a lockable MCP instance:

```
1. mcp-locks claim <instance> --ttl 30m --note "what you're doing"
   → exit 0: proceed
   → exit 2: another session owns it; fall back or escalate

2. ... do your work via <instance>_browser_* / etc. ...

3. mcp-locks release <instance>
```

`--owner` is auto-detected from environment (OpenCode and Claude Code session IDs). You rarely pass it explicitly.

See [examples/opencode-agent-template.md](examples/opencode-agent-template.md) and [examples/claude-code-prompt.md](examples/claude-code-prompt.md) for ready-to-paste templates.

### CLI

```
mcp-locks list                                           # show all instances + owners
mcp-locks who <instance>                                 # detail for one instance
mcp-locks claim <instance> [--owner ID] [--ttl 30m] [--note "..."] [--force]
mcp-locks release <instance> [--owner ID] [--force]
mcp-locks reap                                           # clean up expired + orphans
mcp-locks doctor                                         # health + recommendations
mcp-locks kill --orphans                                 # kill orphaned playwright-mcp Chromiums (subset of reap)
mcp-locks kill --all --idle-only                         # kill all playwright-mcp Chromiums IFF no instance is claimed
mcp-locks kill --all --force                             # nuclear: kill all playwright-mcp Chromiums regardless of claims
```

Exit codes:

- `0` success
- `1` usage error
- `2` denied (owned by someone else, unknown instance, wrong owner; or `kill --idle-only` refused because of active claims)
- `3` state lock acquisition timeout

### Killing Playwright Chromiums on demand

Each `@playwright/mcp` server lazily spawns a Chromium on first browser use, and that Chromium stays alive for the life of the MCP server process. Across opencode restarts these can accumulate, and you sometimes want a single wedged Chromium recycled mid-session. The `kill` subcommand handles the bulk-cleanup cases:

- **`mcp-locks kill --all --idle-only`** — safe default. Refuses (exit 2) if any instance is currently claimed in mcp-locks state. If all instances are free, kills every Chromium whose command line matches the Playwright-MCP profile-dir convention (`mcp-chrome-*` or `playwright_chromiumdev_profile-*`). Use end-of-day or after a known-clean checkpoint.
- **`mcp-locks kill --all --force`** — nuclear. Kills every matching Chromium regardless of claim state. Use when you're sure nothing is in flight, or to recover from a stuck claim.
- **`mcp-locks kill --orphans`** — kills only Chromiums whose parent process is gone (PPID = init/launchd). Subset of what `reap` already does; exposed standalone for cron / launchd / on-demand use.

**Not yet implemented (v1):** `mcp-locks kill <instance>` — targeted single-slot kill. Returns a clear error explaining the limitation. The blocker is that `@playwright/mcp` chooses random profile-dir names that don't encode the mcp-locks instance slot, and the MCP server's command line (as spawned by opencode) doesn't either, so there's no reliable way to map slot → PID from the process table alone. The fix is to track PIDs in mcp-locks state on first browser activity; tracked as a follow-up.

### JSON output for programmatic callers

Pass `--json` (before or after the subcommand) to emit a structured envelope on stdout instead of human-readable text. Useful for MCP wrappers, CI checks, and any script that needs to parse results:

```
mcp-locks --json list
mcp-locks --json claim playwright --ttl 5m --note "session X"
mcp-locks claim playwright --json  # equivalent
```

Envelope shape:

```json
// success
{ "ok": true, "data": { ... command-specific ... } }

// denied / error
{ "ok": false, "error": "denied", "denied": { "current_owner": "...", "ttl_remaining_seconds": 1234, ... } }
{ "ok": false, "error": "owner_mismatch", "denied": { ... } }
{ "ok": false, "error": "instance 'foo' is not registered" }
```

Diagnostics (`WARN:` / `ERROR:` lines) still go to stderr in both modes. Exit codes are unchanged.

### Sub-agents

Parent claims, dispatches the sub-agent with an explicit instance assignment, sub-agent doesn't claim/release. This avoids a sub-agent claim expiring mid-work because its TTL was shorter than the parent's task.

In the sub-agent dispatch prompt:

> Use `playwright3_browser_*` tools for all browser interaction. Do NOT touch `playwright_browser_*` or `playwright2_browser_*` — those are owned by the main thread. Do NOT run `mcp-locks claim` or `release` — the parent has already coordinated.

## How it works

**State** lives at `~/.local/state/mcp-locks/state.json`. JSON. `flock`-protected for write coordination. Cross-sandbox / cross-client visibility because everything anchors on the real user's HOME, not the calling process's HOME (relevant for devcontainers and other sandboxed agent runtimes).

**Claims** carry an owner ID, a long-lived PID for liveness checks, a `claimed_at` timestamp, and an `expires_at` timestamp computed from `--ttl`. Re-claiming as the same owner refreshes the TTL.

**The reaper** (`mcp-locks reap`) runs three classes of cleanup:
1. Expired claims (past `expires_at`)
2. Dead-PID claims (for owners whose long-lived process is gone — opencode/claude session-host PID, not the per-tool-call shell)
3. Kind-specific OS-level cleanup (orphan Chromium processes, stale `SingletonLock` files for `playwright-mcp`; port probe for `figma-desktop-mcp`)

A LaunchAgent runs the reaper at 09:00 and 14:00 daily. Manual: `mcp-locks reap`.

## Why not just use `--isolated`?

`--isolated` solves the OS-level Chromium collision. It doesn't solve the **cross-session coordination problem**: two agents both calling `playwright2_browser_navigate()` will still trash each other's state.

`--isolated` and `mcp-locks` are complementary. Use both. The Playwright MCP slot in your client config should have `--isolated` in its command; the agent prompts should call `mcp-locks claim` before using the slot.

## Owner ID detection

`mcp-locks claim` infers `--owner` in this order:

| Priority | Env var | Owner format | Liveness PID |
|---|---|---|---|
| 1 | `--owner` explicit | as passed | `--owner-pid` / env / `$PPID` |
| 2 | `OPENCODE_RUN_ID` | `opencode:<uuid>` | `OPENCODE_PID` |
| 3 | `OPENCODE_SESSION_ID` | `opencode:<id>` | `OPENCODE_PID` |
| 4 | `CLAUDECODE_SESSION_ID` | `claude:<id>` | `CLAUDECODE_PID` |
| 5 | `CLAUDE_SESSION_ID` | `claude:<id>` | `CLAUDECODE_PID` |
| 6 | (none) | `<shell>:<PPID>` | `$PPID` |

The session-host PID (OpenCode's TUI/web process, Claude Code's main process) is the right thing to check for liveness — it persists across tool calls. The per-tool-call bash PID (`$PPID`) is ephemeral and is only used as a last-resort owner.

## Files

- `~/bin/mcp-locks` — the script (or `$MCP_LOCKS_BIN_DIR/mcp-locks`)
- `/usr/local/bin/mcp-locks` — symlink for PATH
- `~/.config/mcp-locks/registry.json` — which instances are lockable
- `~/.local/state/mcp-locks/state.json` — current claims (HOST-GLOBAL)
- `~/.local/state/mcp-locks/.lock/` — write-coordination lock dir
- `~/.local/state/mcp-locks/reap.log` — rolling 7-day reaper log
- `~/.local/state/mcp-locks/launchd.{out,err}.log` — LaunchAgent stdio
- `~/Library/LaunchAgents/com.${USER}.mcp-locks-reap.plist`

## Docs

- [docs/design.md](docs/design.md) — original design sketch, problem statement, alternatives
- [docs/architecture.md](docs/architecture.md) — state file shape, owner-ID rules, reaper steps, kind semantics
- [docs/opencode-integration.md](docs/opencode-integration.md) — wiring into OpenCode slash commands and agent prompts

## License

MIT. See [LICENSE](LICENSE).

## Contributing

PRs welcome. Tests live in `test/`; run `./test/run-all.sh` before sending. New `kind` types (e.g. for a new MCP server holding exclusive state) should add a reaper step in `bin/mcp-locks` and a section in `docs/architecture.md`.
