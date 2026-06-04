# Architecture

## State file shape

`~/.local/state/mcp-locks/state.json`:

```json
{
  "version": 1,
  "instances": {
    "playwright2": {
      "owner": "opencode:5dfd2252-a32a-44c1-a66d-5750dd0d7bfb",
      "owner_pid": 98946,
      "claimed_at": "2026-06-04T13:07:53Z",
      "expires_at": "2026-06-04T13:37:53Z",
      "note": "PR #17024 review"
    },
    "playwright": { "owner": null },
    "playwright3": { "owner": null },
    "playwright4": { "owner": null },
    "figma-desktop": { "owner": null }
  },
  "updated_at": "2026-06-04T13:07:53Z"
}
```

Fields:

| Field | Type | Notes |
|---|---|---|
| `version` | int | Schema version. `1` today. Bumped on incompatible changes (with a migration script). |
| `instances` | object | Map of instance name → claim record. |
| `instances.<name>.owner` | string \| null | The owner ID. `null` = free. |
| `instances.<name>.owner_pid` | int | Long-lived process to check for liveness. See "Owner ID detection." |
| `instances.<name>.claimed_at` | ISO 8601 UTC | When the current claim started. |
| `instances.<name>.expires_at` | ISO 8601 UTC | When the current claim auto-expires. |
| `instances.<name>.note` | string | Free-form. Useful when debugging "who owns this?" |
| `updated_at` | ISO 8601 UTC | Last successful write. |

## Write coordination

All writes go through a directory-based lock at `~/.local/state/mcp-locks/.lock/`:

```bash
mkdir "$LOCK_DIR" 2>/dev/null  # atomic on all unices; succeeds for exactly one process
# ... do work ...
rmdir "$LOCK_DIR"
```

`mkdir` is used instead of `flock` because `flock(1)` is not on macOS by default and the directory pattern is portable across all unices and bash versions. Lock contention timeout: 5 seconds (50 retries × 100ms). After that, the CLI exits with status 3 and prints the lock path so a human can remove a stale lock.

The lock protects only the state file write. Reads are unlocked — readers may see a slightly-older state but never a partially-written one (writes use temp-file + `mv` for atomicity).

## Owner ID detection

`mcp-locks claim` infers `--owner` in this priority order:

| Priority | Source | Owner format | Liveness PID source |
|---|---|---|---|
| 1 | `--owner <id>` | as passed | `--owner-pid` (future) / `$OPENCODE_PID` / `$CLAUDECODE_PID` / `$PPID` |
| 2 | `$OPENCODE_RUN_ID` | `opencode:<uuid>` | `$OPENCODE_PID` |
| 3 | `$OPENCODE_SESSION_ID` | `opencode:<id>` | `$OPENCODE_PID` |
| 4 | `$CLAUDECODE_SESSION_ID` | `claude:<id>` | `$CLAUDECODE_PID` |
| 5 | `$CLAUDE_SESSION_ID` | `claude:<id>` | `$CLAUDECODE_PID` |
| 6 | (none) | `<parent-process-name>:$PPID` | `$PPID` |

### Why two values?

The **owner ID** is the logical identifier — it persists across tool calls within a session. OpenCode and Claude Code each export a stable per-session UUID into every tool shell, so re-claiming as the same session refreshes the TTL instead of getting DENIED.

The **liveness PID** is the long-lived process whose death means the session is genuinely gone. For OpenCode that's the TUI/web process (`$OPENCODE_PID`); for Claude Code that's the main process (`$CLAUDECODE_PID`). The per-tool-call bash subshell (`$PPID`) dies between calls and is therefore useless as a liveness signal for a real agent session.

### Heuristic gate in the reaper

The reaper treats dead-PID as a clear-the-claim signal **only when the owner ID is opencode/claude-shaped** (i.e. it really represents a long-lived session). When the owner ID is `bash:<PPID>` (an ad-hoc shell invocation), the PID is always going to be dead by the next tool call — so the reaper waits for TTL expiry instead of premature clearing.

## Reaper steps

`mcp-locks reap` runs these steps in order. Each is idempotent; the reaper logs what it actually did to `~/.local/state/mcp-locks/reap.log`.

### 1. Expired claims (generic)

Any claim past `expires_at` is cleared.

### 2. Dead-PID claims (generic, with heuristic gate)

For each claim with a non-zero `owner_pid`, check `kill -0 <pid>`. If the PID is gone AND the owner ID starts with `opencode:` or `claude:`, clear the claim.

### 3. Kind-specific OS cleanup

The registry's `kind` field tells the reaper which OS-level cleanup to run.

**`playwright-mcp`:**
- **Kill orphan Chromium processes.** `pgrep -f mcp-chrome-` whose PPID is init/launchd. Handles "OpenCode quit but Chromium kept running."
- **Remove stale `SingletonLock` files.** For each `~/Library/Caches/ms-playwright/mcp-chrome-*/SingletonLock`, parse the PID from the symlink target; if dead, remove the file. Handles the lock-survives-crash failure mode.

**`figma-desktop-mcp`:**
- **Probe the port** (default 3845). If bound but the owning process is dead, log and recommend manual action in `doctor`. Do NOT kill — Figma desktop is user-owned and killing it would close the user's design files.

Other kinds can be added by extending `_reap_<kind>` functions in `bin/mcp-locks`.

### 4. Log truncation (generic)

Keep last 7 days of `reap.log` entries (matched by ISO 8601 prefix on each line).

## Scheduling

A LaunchAgent (macOS) runs `mcp-locks reap` at **09:00 and 14:00 local time** every day. The schedule is opinionated for a single-developer workflow: morning cleanup before the day's first session, mid-afternoon cleanup before the second large work block.

Adjust the `StartCalendarInterval` array in your installed plist (`~/Library/LaunchAgents/com.${USER}.mcp-locks-reap.plist`) if your usage pattern is different. Reload after editing:

```bash
launchctl bootout "gui/$UID/com.${USER}.mcp-locks-reap"
launchctl bootstrap "gui/$UID" "$HOME/Library/LaunchAgents/com.${USER}.mcp-locks-reap.plist"
```

On Linux or with `MCP_LOCKS_NO_LAUNCHAGENT=1`, schedule via cron:

```cron
0 9,14 * * * /usr/local/bin/mcp-locks reap >> "$HOME/.local/state/mcp-locks/cron.out.log" 2>&1
```

## Cross-sandbox / cross-client visibility

`mcp-locks` is designed for a single machine running multiple MCP clients that may live in different sandboxes (devcontainers, isolated agent runtimes, etc.). The state, registry, and logs all live at **host paths** anchored on the real user's HOME — not whatever sandbox HOME the calling process inherits.

The `_real_home()` function (in `bin/mcp-locks`) detects the real HOME:

1. `$MCP_LOCKS_HOME` env var (escape hatch for tests and non-standard layouts)
2. `/Users/${SUDO_USER:-$USER}` on macOS, `/home/$USER` on Linux
3. `$HOME` (fallback)

This means an agent running inside a sandbox sees the same `state.json` as an agent running on the host, and as an agent running in a different sandbox. All three coordinate.

**Gotcha:** when agents shell out to `tail` or `ls` the state/log files, they must use **absolute paths**, not `~`. From inside a sandbox, `~` resolves to the sandbox HOME, not the real HOME. The `mcp-locks` binary itself is fine — only ad-hoc commands need this discipline.

## Trust model

`mcp-locks` is **cooperative**, not enforced. It cannot prevent a determined process from using a Playwright instance without claiming it. The trust model assumes all agents on the machine cooperate with the protocol — which is true if all your agent prompts call `mcp-locks claim` before browser tool calls.

If you need real enforcement, you'd need to proxy the MCP server itself and reject tool calls from un-claimed sessions. That's a larger project and not what this is.
