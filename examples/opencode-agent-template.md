# OpenCode agent prompt template — Playwright with mcp-locks

Copy-paste into any OpenCode agent prompt (slash command, agent prompt, AGENTS.md, etc.) that needs a Playwright instance.

---

## Prompt fragment

Drop this into the prompt at the point the agent should start using Playwright:

```
Before using any Playwright instance, claim it with mcp-locks:

  mcp-locks claim <instance> --ttl 30m --note "<what you're doing>"

- Exit 0 means you've got the lock; proceed with <instance>_browser_* tools.
- Exit 2 means another session owns it. Either pick a different instance
  (mcp-locks list will show what's free), wait if their TTL is short, or
  surface to the human if you're blocked.

When you're done with the instance (or on error), release it:

  mcp-locks release <instance>

--owner is auto-detected from OPENCODE_RUN_ID; don't pass it.
```

## Full example: side-by-side comparison

A prompt that compares a PR branch (port `:<PORT>`) against master (port `:8443`):

```
You are verifying that PR <N> doesn't regress visual behavior compared to master.

1. Claim both Playwright instances:
   - mcp-locks claim playwright --ttl 30m --note "PR <N> PR-branch view"
   - mcp-locks claim playwright2 --ttl 30m --note "PR <N> master baseline"

   If either DENIES, surface to me with `mcp-locks who <instance>` output
   and propose a fallback (single-instance sequential, or different ports).

2. Inject the four auth cookies into both instances (use cookie-bridge or
   your team's standard auth recipe).

3. Navigate:
   - playwright_browser_navigate(https://localhost:<PORT>/...)
   - playwright2_browser_navigate(https://localhost:8443/...)

4. Snapshot both, compare, report findings.

5. ALWAYS release before finishing, even on error:
   - mcp-locks release playwright
   - mcp-locks release playwright2
```

## Full example: sub-agent dispatch

The parent claims, dispatches the sub-agent with an explicit instance assignment, and releases after the sub-agent returns:

```
Parent:
1. mcp-locks claim playwright3 --ttl 30m --note "ARTI-XYZ smoke checks (sub-agent)"
2. Dispatch sub-agent with this prompt:

   ---
   Use playwright3_browser_* tools for all browser interaction in this task.

   Do NOT touch playwright_browser_* or playwright2_browser_* — those are
   owned by the main thread.

   Do NOT run `mcp-locks claim` or `mcp-locks release` — the parent has
   already coordinated.

   Your task: [...]
   ---

3. When the sub-agent returns: mcp-locks release playwright3
```

## Common mistakes

- **Forgetting to release on error.** Wrap the work in a try/finally pattern or release in both the success and failure branches.
- **Sub-agents claiming on their own.** They'll race with the parent. Parent always owns the lifecycle.
- **Using `~` in `tail`/`ls` of state files from a sandbox shell.** `~` is the sandbox HOME; the state file lives at the real HOME. Use absolute paths or `mcp-locks doctor`.
- **Claiming the same instance repeatedly without checking exit code.** A loop that claims-then-stomps without honoring DENIED defeats the system. Always check `$?`.
- **Setting `--ttl` too short** (e.g. 5m) for a long task. The reaper or another session will swoop in and steal. Default 30m is usually right.
