# Claude Code prompt template — Playwright with mcp-locks

Copy-paste into any Claude Code slash command, agent prompt, or CLAUDE.md section that needs a Playwright instance.

The contract is identical to the [OpenCode template](opencode-agent-template.md); only the env-var auto-detection differs (Claude Code exports `CLAUDECODE_SESSION_ID` / `CLAUDECODE_PID` instead of `OPENCODE_RUN_ID` / `OPENCODE_PID`).

---

## Prompt fragment

```
Before using any Playwright instance, claim it with mcp-locks:

  mcp-locks claim <instance> --ttl 30m --note "<what you're doing>"

- Exit 0: lock acquired, proceed with mcp__<instance>__browser_* tools
  (or whatever your Claude Code MCP tool naming convention is).
- Exit 2: another session owns it. Pick a different instance (mcp-locks list
  shows what's free), wait if their TTL is short, or escalate.

When done (or on error):

  mcp-locks release <instance>

--owner is auto-detected from CLAUDECODE_SESSION_ID; don't pass it.
```

## Sub-agent dispatch (Claude Code)

```
Parent:
1. mcp-locks claim playwright3 --ttl 30m --note "ARTI-XYZ checks (sub-agent)"
2. Dispatch (Task tool) with this prompt:

   ---
   Use mcp__playwright3__browser_* tools for all browser interaction.

   Do NOT touch mcp__playwright__browser_* or mcp__playwright2__browser_* —
   those are owned by the main thread.

   Do NOT run `mcp-locks claim` or `mcp-locks release` — the parent has
   already coordinated.

   Your task: [...]
   ---

3. After return: mcp-locks release playwright3
```

## Wiring into a slash command

`~/.claude/commands/review-pr.md`:

```markdown
---
description: Review an open PR with side-by-side master/PR browser comparison
---

You are reviewing PR $ARGUMENTS.

Step 1: claim browser instances.
- Run: `mcp-locks claim playwright --ttl 30m --note "PR $ARGUMENTS"`
- Run: `mcp-locks claim playwright2 --ttl 30m --note "PR $ARGUMENTS master"`
- If either DENIES, run `mcp-locks who <instance>` for both and ask me how to proceed.

... rest of the review ...

Step N: release at the end (or on error).
- Run: `mcp-locks release playwright`
- Run: `mcp-locks release playwright2`
```

## Cross-client coordination

The whole point of `mcp-locks` is that an OpenCode session and a Claude Code session on the same machine will see each other's claims and avoid stomping. Owner IDs are namespaced by client (`opencode:<uuid>` vs `claude:<id>`) so `mcp-locks who playwright2` will tell you exactly which client is holding it.

If you're regularly running both clients in parallel and need to coordinate, leave a note in your `CLAUDE.md`:

```
When using Playwright tools, claim via mcp-locks first. Mac is shared with an
OpenCode session — other sessions' claims will block ours. See
~/repos/mcp-locks/README.md for the protocol.
```
