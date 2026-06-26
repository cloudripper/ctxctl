#!/usr/bin/env bash
#
# ctxctl gate
# -----------
# A PreToolUse hook that restricts the TOP-LEVEL (orchestrator) thread to a
# small allowlist of orchestration tools, while leaving subagents completely
# unrestricted. The goal is to keep the main thread's context clean by pushing
# real work (file edits, shell, web fetches, MCP calls) down into subagents.
#
# How it distinguishes threads:
#   PreToolUse payloads include an `agent_id` field ONLY when the call fires
#   inside a subagent. An empty/absent `agent_id` means we are in the top-level
#   thread. (See the Claude Code hooks reference, "Common input fields".)
#
# Configuration (read from env vars set by the plugin runtime):
#   CLAUDE_PLUGIN_OPTION_ALLOWLIST / CLAUDE_PLUGIN_OPTION_allowlist
#       comma-separated allowlist of tools permitted in the top-level thread
#   CLAUDE_PLUGIN_OPTION_MODE / CLAUDE_PLUGIN_OPTION_mode
#       "deny" (block outright) or "ask" (prompt the user to confirm)
#
# Input:  PreToolUse JSON on stdin.
# Output: exit 0 with no output to allow; exit 0 with a JSON decision to block.
#
# Fail-open policy: if anything is wrong (no jq, unparseable payload, missing
# tool name) the hook allows the call. A context-control convenience should
# never be able to lock you out of every tool.

ALLOWLIST_DEFAULT="Read,Grep,Glob,Agent,Skill,TodoWrite,AskUserQuestion,ExitPlanMode,ScheduleWakeup,SendMessage,TaskCreate,TaskUpdate,TaskList,TaskGet,TaskOutput,TaskStop,EnterPlanMode"

ALLOWLIST="${CLAUDE_PLUGIN_OPTION_ALLOWLIST:-${CLAUDE_PLUGIN_OPTION_allowlist:-${1:-}}}"
MODE="${CLAUDE_PLUGIN_OPTION_MODE:-${CLAUDE_PLUGIN_OPTION_mode:-${2:-deny}}}"
[ -z "$ALLOWLIST" ] && ALLOWLIST="$ALLOWLIST_DEFAULT"
[ -z "$MODE" ] && MODE="deny"

payload="$(cat)"

# jq is required to read the payload. If it is missing, fail open.
if ! command -v jq >/dev/null 2>&1; then
  echo "ctxctl: jq not found on PATH; gate disabled for this call." >&2
  exit 0
fi

agent_id="$(printf '%s' "$payload" | jq -r '.agent_id // empty' 2>/dev/null)"
tool_name="$(printf '%s' "$payload" | jq -r '.tool_name // empty' 2>/dev/null)"

# Subagent context: allow everything.
[ -n "$agent_id" ] && exit 0

# Could not determine the tool name: fail open.
[ -z "$tool_name" ] && exit 0

# Top-level thread: allow only tools on the allowlist (exact match).
case ",$ALLOWLIST," in
  *",$tool_name,"*) exit 0 ;;
esac

# Blocked. Emit a PreToolUse decision.
decision="deny"
[ "$MODE" = "ask" ] && decision="ask"

reason="ctxctl: '$tool_name' is blocked in the top-level thread. Allowed at the top level: ${ALLOWLIST}. Delegate this to a subagent (via the Agent tool) or run it inside a skill or agent so the orchestrator's context stays clean."

jq -n --arg d "$decision" --arg r "$reason" '{
  hookSpecificOutput: {
    hookEventName: "PreToolUse",
    permissionDecision: $d,
    permissionDecisionReason: $r
  }
}'
exit 0
