# Design

Original design sketch + decision log. Captured 2026-06-04 after the seventh consecutive session that hit a Playwright multi-instance failure without fixing the underlying mechanism.

## Problem

Two failure modes compound when running MCP servers across multiple agent clients on the same machine.

### Failure mode 1: Chromium `SingletonLock` collision (OS layer)

Without `--isolated` on the `@playwright/mcp` command, every MCP server process points at the **same** Chromium profile dir (`~/Library/Caches/ms-playwright/mcp-chrome-<hash>/`). Chromium enforces single-process-per-profile via `SingletonLock`. **Result: only the first instance to launch a browser wins; every other instance fails with:**

```
Browser is already in use for …mcp-chrome-<hash>, use --isolated to run multiple instances of the same browser
```

This is fixable by adding `--isolated` to every MCP server's command in the client config. Each instance then gets its own profile dir under `/tmp/playwright_chromiumdev_profile-*` and they coexist fine.

### Failure mode 2: No discovery across clients (coordination layer)

Even with `--isolated`, two agent sessions (across OpenCode, Claude Code, multiple sandboxes) have no way to know whether another session is currently using `playwright2`. The default behavior is "grab it and hope," and the failure mode is silent stomping — one session navigates the browser away mid-snapshot of another.

This is the harder problem. It can't be solved at the OS layer because the conflict is logical, not physical.

### Why rules don't work

Playbook guidance like "sub-agents must be told which instance to use" or "claim before navigating" has been documented and re-documented. It does not prevent the failure mode in practice because:

- Agents read the playbook, then forget about it three tool-calls later
- Sub-agents default to grabbing the primary instance and stomping on the main thread
- Cross-client coordination needs cross-process state, which a playbook can't provide
- The failure is silent (no exception, no log), so nobody notices until a downstream check fails

**Mechanism beats rules.** `mcp-locks` provides the mechanism.

## Goal

Cross-client checkout system for MCP instances that hold exclusive OS resources. State lives outside any single client. Both clients call into it the same way. Claims expire automatically. A periodic reaper cleans up missed releases and OS-level leftovers.

## Non-goals

- **Solve OS-level Chromium collisions.** That's `--isolated`'s job. `mcp-locks` is orthogonal — both layers are needed.
- **Cross-machine coordination.** Single-machine assumption (one developer's laptop, multiple processes).
- **Enforce locking against uncooperative processes.** Cooperative trust model only. See [architecture.md#trust-model](architecture.md#trust-model).
- **Cover MCP servers that don't hold exclusive resources** (e.g. Atlassian, Figma REST API). Those multiplex fine.

## Naming

Considered names: `pw-instances` (Playwright-only, too narrow), `mcp-claim` (verb-named, awkward in subcommands), `instance-checkout` (too generic), `chrome-lock` (wrong layer).

**Chose `mcp-locks`** because:
- The abstraction is "lockable MCP instances," not Playwright-specific
- Noun-based naming reads cleanly with subcommands (`mcp-locks claim`, `mcp-locks list`)
- Future-proof for adding Figma desktop, Slack-harvester, or other single-resource MCPs

## Why bash

Considered: Python, Go, Rust. Chose **bash** because:

- Zero install overhead (every macOS / Linux ships bash + `jq`)
- Matches the style of similar single-machine ops tools the author already maintains
- The state file is tiny JSON; `jq` handles it cleanly
- No build step, no dependency manifest, no runtime version concerns
- The whole binary is ~600 lines — well under the threshold where bash starts hurting

Trade-off: no language-level test framework. The `test/` dir uses bash scripts with `set -e` + manual assertions. Adequate for the surface area.

## Why `mkdir`-based locking

Considered: `flock(1)` (not on macOS by default), `lockfile(1)` (procmail dependency), file-descriptor locks (bash 4+ only and tricky with subshells). Chose `mkdir <dir>` which is atomic on all POSIX filesystems, portable across bash versions, and easy to recover from manually (`rm -rf <lock-dir>` if stale).

## State file format

JSON because:
- Trivial to read/write from any language (someone might want to extend with Python or write a UI on top)
- `jq` is universally available
- Human-readable for debugging
- Atomic-update pattern (temp file + `mv`) is straightforward

Versioned (`version: 1` field) so future schema changes can migrate cleanly.

## Owner ID design

The hardest part of the design. The owner ID needs to be:

1. **Stable across tool calls within a session** — otherwise every tool call would be a different owner and re-claim would fail
2. **Distinguishable across concurrent sessions** — otherwise two parallel sessions look like the same owner
3. **Cleanable when the session is genuinely gone** — otherwise dead claims block live ones

OpenCode and Claude Code both export per-session UUIDs into the tool shell environment, which solves (1) and (2). For (3), we pair the owner ID with a **separate liveness PID** — the long-lived session host process, not the ephemeral per-tool-call shell.

The reaper applies dead-PID cleanup only to claims with opencode/claude-shaped owner IDs. Shell/PPID claims wait for TTL expiry because their PIDs are designed to be ephemeral.

## TTL default

30 minutes. Long enough that an active interactive session doesn't hit DENIED on a new tool call (re-claim refreshes). Short enough that a crashed agent's claim clears within a tolerable window — no human ever has to wait more than 30m for a stuck lock to free.

Hard ceiling: 4 hours. Anything longer should be a manual `--ttl 4h --note "long-running smoke test"` decision, not a default.

## What this replaces

Before `mcp-locks`:
- "Rules" sections in playbooks telling agents which instance to use
- Manual probe at session start (`playwright_browser_resize` + `playwright2_browser_resize` to see if both work)
- Recovery procedure when a stale `SingletonLock` blocks startup
- Sub-agent prompt templates listing explicit instance assignments

After `mcp-locks`:
- One line in every prompt: `mcp-locks claim <instance>`
- One line at the end: `mcp-locks release <instance>`
- The CLI tells you what's free; no probe needed
- The reaper handles all the recovery and stale-lock cleanup as a background process

## Open questions (deferred to future versions)

- **`--wait` mode.** `mcp-locks claim playwright2 --wait 5m` polls every 10s until the claim frees or the wait expires. Useful for batch workflows that can tolerate waiting. v2.
- **Visibility in the agent UI.** OpenCode and Claude Code could surface "MCP locks: 2 claimed (playwright by another session)" at startup. Requires plugin/extension API integration. v2.
- **Plugin hook to auto-claim on tool call.** Wrap MCP tool calls in OpenCode so any `playwright*_browser_*` invocation auto-claims if not already owned, auto-releases on session end. Less discipline required from agents. v2.
- **Generalize Linux support.** LaunchAgent doesn't apply. systemd timer + user services are the equivalent. install.sh has skip flags but no Linux-native install path yet.
- **`mcp-locks register <instance> --kind <kind>`** subcommand to add lockable instances without hand-editing JSON. Low priority; the file is two lines.

## Cross-references

- [README.md](../README.md) — install + agent usage
- [architecture.md](architecture.md) — state shape, owner-ID rules, reaper steps
- [opencode-integration.md](opencode-integration.md) — wiring into OpenCode commands
- [examples/](../examples/) — copy-paste prompt templates
