# ctxctl - context control for agents

A Claude Code plugin that restricts the **top-level (orchestrator) thread** to a
small allowlist of orchestration tools. Everything else (file edits, shell, web
fetches, MCP tools, etc.) is blocked at the top level and must run inside a
**subagent**. Subagents themselves are never restricted.

The point is context hygiene: the main thread stays an orchestrator that plans
and delegates, while heavy, context-polluting work happens in subagents whose
output is summarized back rather than dumped into the main transcript.

## How it works

It registers a single `PreToolUse` hook (`scripts/gate.sh`) on all tools.

`PreToolUse` payloads include an `agent_id` field **only** when the call fires
inside a subagent. The gate uses that:

- `agent_id` present (subagent) -> allow everything.
- `agent_id` absent (top-level thread) -> allow only tools on the allowlist;
  block the rest.

Reference: Claude Code hooks reference, "Common input fields"
(https://code.claude.com/docs/en/hooks).

## Install

```bash
claude plugin marketplace add cloudripper/ctxctl
claude plugin install ctxctl@ctxctl
```

## Configuration

The plugin works out of the box with no configuration required — the defaults
below are applied automatically on install.

To customise, run this in Claude Code:

```
/plugin configure ctxctl@ctxctl
```

You'll be prompted for each option. Leave any field blank to keep the default.

| Option      | Default                                                              | Meaning |
| ----------- | -------------------------------------------------------------------- | ------- |
| `allowlist` | `Agent,Skill,TodoWrite,AskUserQuestion,ExitPlanMode,ScheduleWakeup,SendMessage,TaskCreate,TaskUpdate,TaskList,TaskGet,TaskOutput,TaskStop,EnterPlanMode` | Comma-separated tool names the top-level thread may still call (no spaces). |
| `mode`      | `deny`                                                               | `deny` blocks outright; `ask` prompts you to confirm each blocked top-level call. |

If a tool you want at the top level gets blocked, the denial message prints its
exact name — add it to `allowlist` and re-run the configure command. Tool names
can vary slightly between Claude Code versions, so treat the default list as a
starting point.

## Interaction with skills and named agents

This is the common worry, and the answer is that they keep working:

1. The top-level thread spawns a named agent (for example `code-review`) by
   calling the `Agent` tool, which is on the allowlist. The spawn is allowed.
2. Inside that subagent, every tool call carries `agent_id`, so the gate allows
   all of them. The agent does its work normally.
3. Skills that Claude triggers via the `Skill` tool also work, because `Skill`
   is on the allowlist. (Typing `/skillname` directly bypasses `PreToolUse`
   entirely, so that path is unaffected regardless.)

The only thing blocked is the **orchestrator calling work tools directly**.

## Requirements

- `bash` and `jq` on `PATH`. On Windows, the hook runs under Git Bash (Claude
  Code's default shell-form shell); install Git Bash and `jq`.
- If `jq` is missing or the payload cannot be parsed, the gate **fails open**
  (allows the call) so it can never lock you out of every tool.

## Caveats and known interactions

- **`--agent` sessions:** launching with `claude --agent <name>` makes the whole
  session an agent, so `agent_id` is set throughout and nothing is blocked.
- **MCP tools** (`mcp__server__tool`) are treated as work tools and are blocked
  at the top level by default. Add specific ones to `allowlist` if you want them
  available to the orchestrator.
- **`WebSearch` / `WebFetch`** are blocked at the top level by default on the
  same context-hygiene grounds. Add them to `allowlist` if you prefer quick
  top-level lookups.
- This is a convenience guardrail, not a security boundary. For hard security
  controls use the permission system (deny rules) instead. See
  https://code.claude.com/docs/en/permissions.

## Layout

```
ctxctl/
  .claude-plugin/marketplace.json     # marketplace catalog
  plugins/ctxctl/
    .claude-plugin/plugin.json        # plugin manifest + userConfig
    hooks/hooks.json                  # registers the PreToolUse gate
    scripts/gate.sh                   # the gate logic
  README.md
  LICENSE
```

## License

MIT. See LICENSE.
