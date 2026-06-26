# ctxctl - context control for agents

A Claude Code plugin that restricts the **top-level (orchestrator) thread** to a
small allowlist of orchestration tools. Heavy work (file edits, shell, web
fetches, MCP tools, etc.) is blocked at the top level and must run inside a
**subagent**. Lightweight read-only inspection (`Read`, `Grep`, `Glob`) is
allowed at the top level so the orchestrator can see code to plan. Subagents
themselves are never restricted.

The point is context hygiene: the main thread stays an orchestrator that plans
and delegates, while heavy, context-polluting work happens in subagents whose
output is summarized back rather than dumped into the main transcript. A second
hook injects a standard summary contract into each subagent so those summaries
carry the findings the orchestrator actually needs.

## How it works

It registers two hooks:

**1. A `PreToolUse` gate (`scripts/gate.sh`) on all tools.** `PreToolUse`
payloads include an `agent_id` field **only** when the call fires inside a
subagent. The gate uses that:

- `agent_id` present (subagent) -> allow everything.
- `agent_id` absent (top-level thread) -> allow only tools on the allowlist;
  block the rest.

**2. A `SubagentStart` brief (`scripts/brief.sh`) on every subagent.** The
orchestrator never sees a subagent's transcript, only the single final message
it returns, so the value of delegation is capped by the quality of that message.
This hook injects a standard return contract (via `additionalContext`) into
every subagent at spawn, asking for outcome, files touched, discrete findings
(including incidental ones), and loose ends. It is delivered deterministically
on every spawn and needs no per-agent or per-skill setup. `SubagentStart` cannot
block, so it can never stall a subagent. See "Subagent summaries" below for what
this does and does not guarantee.

Reference: Claude Code hooks reference (https://code.claude.com/docs/en/hooks),
"Common input fields" for `agent_id`, and the `SubagentStart` event, which
supports `additionalContext` and cannot block.

## Install

```bash
claude plugin marketplace add cloudripper/ctxctl
claude plugin install ctxctl@ctxctl
```

## Configuration

The plugin works out of the box with no configuration required. The defaults
below are applied automatically on install.

To customise, run this in Claude Code:

```
/plugin configure ctxctl@ctxctl
```

You'll be prompted for each option. Leave any field blank to keep the default.

| Option      | Default                                                              | Meaning |
| ----------- | -------------------------------------------------------------------- | ------- |
| `allowlist` | `Read,Grep,Glob,Agent,Skill,TodoWrite,AskUserQuestion,ExitPlanMode,ScheduleWakeup,SendMessage,TaskCreate,TaskUpdate,TaskList,TaskGet,TaskOutput,TaskStop,EnterPlanMode` | Comma-separated tool names the top-level thread may still call (no spaces). |
| `mode`      | `deny`                                                               | `deny` blocks outright; `ask` prompts you to confirm each blocked top-level call. |
| `summary`   | (blank -> built-in contract)                                         | Text injected into every subagent at spawn telling it how to write its final handoff. Blank uses the built-in contract. |

`Read`, `Grep`, and `Glob` are on the default allowlist so the orchestrator can
inspect code while planning. They are low-volume by nature, but `Read` on a huge
file still pollutes the top-level context, so prefer delegating bulk reads to a
subagent. Remove them from `allowlist` if you want a stricter pure-orchestrator
top level.

If a tool you want at the top level gets blocked, the denial message prints its
exact name, so add it to `allowlist` and re-run the configure command. Tool names
can vary slightly between Claude Code versions, so treat the default list as a
starting point.

## Interaction with skills and named agents

Named agents keep working; skills work with one important caveat.

1. The top-level thread spawns a named agent (for example `code-review`) by
   calling the `Agent` tool, which is on the allowlist. The spawn is allowed.
2. Inside that subagent, every tool call carries `agent_id`, so the gate allows
   all of them. The agent does its work normally, and `brief.sh` has already
   handed it the summary contract at spawn.
3. The `Skill` tool is allowlisted, so **triggering** a skill always works. But a
   skill's body runs **inline in the top-level thread**, not in a subagent, so
   its tool calls carry no `agent_id`. That means:
   - Skills that only plan, use allowlisted tools (including `Read`/`Grep`/`Glob`),
     or delegate to subagents run unchanged.
   - A skill that **directly performs work** at the top level (`Edit`, `Write`,
     `Bash`, `WebFetch`, MCP tools, etc.) will have **those specific calls
     blocked** by the gate, exactly like any other top-level work call.

   To run a work-performing skill at the top level, either add the tools it needs
   to `allowlist`, or have the skill delegate its work into a subagent. Note:
   invoking a skill via `/skillname` skips the `Skill` tool call itself, but any
   work tools the skill then runs in the main thread **still pass through the
   gate** and are blocked the same way.

The thing blocked is the **orchestrator (or an inline skill) calling work tools
directly**.

## Subagent summaries

`brief.sh` injects the same return contract into every subagent at spawn. This
is a deliberate trade:

- **Deterministic:** the contract is delivered on every spawn, with no per-agent
  or per-skill files to maintain. Customise it with the `summary` option.
- **Not deterministic:** the subagent still writes its own summary. The hook
  shapes the structure and reminds it to surface incidental findings; it cannot
  force the content to be complete or correct.

If you want hard, structural enforcement, add a `SubagentStop` hook that reads
the subagent transcript and returns `{"decision":"block","reason":"..."}` (or
exits 2) when the final message is missing required sections, forcing the
subagent to revise before it returns. This is stricter but can loop and adds a
round-trip, so it is intentionally **not** shipped by default. ctxctl keeps the
lighter spawn-time contract as the default.

## Requirements

- `bash` and `jq` on `PATH`. On Windows, the hooks run under Git Bash (Claude
  Code's default shell-form shell); install Git Bash and `jq`.
- Both hooks **fail open**: if `jq` is missing or the payload cannot be parsed,
  the gate allows the call (so it can never lock you out of every tool) and the
  brief simply skips injection (no summary contract, but the subagent still
  runs). `SubagentStart` cannot block in any case.

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
    hooks/hooks.json                  # registers the PreToolUse gate + SubagentStart brief
    scripts/gate.sh                   # the top-level allowlist gate
    scripts/brief.sh                  # injects the subagent summary contract at spawn
  README.md
  LICENSE
```

## License

MIT. See LICENSE.
