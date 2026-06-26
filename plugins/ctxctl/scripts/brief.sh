#!/usr/bin/env bash
#
# ctxctl brief
# ------------
# A SubagentStart hook that injects a standard "return contract" into every
# subagent at spawn. The orchestrator cannot see a subagent's transcript, only
# the single final message it returns, so the value of delegation is bounded by
# how good that final message is. This hook deterministically delivers the same
# handoff contract to every subagent, without requiring per-agent or per-skill
# definitions.
#
# What this does and does not guarantee:
#   - Deterministic: the contract is delivered on every subagent spawn.
#   - NOT deterministic: the subagent still writes the summary itself. The hook
#     shapes the structure; it cannot force the content to be correct.
# For stricter, structural enforcement, see the SubagentStop note in the README.
#
# Configuration (read from env vars set by the plugin runtime):
#   CLAUDE_PLUGIN_OPTION_SUMMARY / CLAUDE_PLUGIN_OPTION_summary
#       overrides the contract text. Leave unset to use the default below.
#
# Input:  SubagentStart JSON on stdin (ignored).
# Output: exit 0 with a JSON additionalContext block.
#
# Fail-open policy: if jq is missing, exit 0 with no output. SubagentStart
# cannot block, so a bad payload here can never stall a subagent.

CONTRACT_DEFAULT="ctxctl: You are a subagent. The orchestrator that spawned you CANNOT see your transcript or tool output, only the single final message you return. Make that message a complete handoff. When applicable, cover:
- Outcome: what you did, or the answer, in 1-3 sentences.
- Files touched: each path with a one-line description of the change.
- Findings: discrete facts, decisions, gotchas, and exact identifiers (paths, symbols, commands, line numbers) the orchestrator needs, including incidental ones you would otherwise drop.
- Loose ends: anything unverified, failed, skipped, or left for follow-up.
Prefer specific identifiers over prose. Omit sections that do not apply; do not pad. Do not restate these instructions."

CONTRACT="${CLAUDE_PLUGIN_OPTION_SUMMARY:-${CLAUDE_PLUGIN_OPTION_summary:-}}"
[ -z "$CONTRACT" ] && CONTRACT="$CONTRACT_DEFAULT"

# Drain stdin so the writer never sees a broken pipe; we do not need the payload.
cat >/dev/null 2>&1

# jq builds valid JSON regardless of quoting/newlines in the contract.
if ! command -v jq >/dev/null 2>&1; then
  exit 0
fi

jq -n --arg c "$CONTRACT" '{
  hookSpecificOutput: {
    hookEventName: "SubagentStart",
    additionalContext: $c
  }
}'
exit 0
