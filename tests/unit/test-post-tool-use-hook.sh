#!/usr/bin/env bash
set -euo pipefail
PLUGIN_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HOOK="$PLUGIN_ROOT/hooks/post-tool-use-stage-handoff"

[[ -x "$HOOK" ]] || { echo "FAIL hook not executable at $HOOK"; exit 1; }
echo "OK  hook present and executable"

# 1. Skill invocation of a stage skill -> emit systemMessage
out="$(printf '%s' '{"tool_name":"Skill","tool_input":{"skill":"bugfix:ticket-intake"}}' | "$HOOK")"
echo "$out" | jq -e '.systemMessage' >/dev/null || { echo "FAIL no systemMessage for ticket-intake"; echo "$out"; exit 1; }
echo "$out" | jq -r '.systemMessage' | grep -q "resume-run" || { echo "FAIL systemMessage missing resume-run text"; exit 1; }
echo "OK  stage skill triggers reminder"

# 2. Skill invocation of run-ticket -> emit systemMessage
out="$(printf '%s' '{"tool_name":"Skill","tool_input":{"skill":"bugfix:run-ticket"}}' | "$HOOK")"
echo "$out" | jq -e '.systemMessage' >/dev/null || { echo "FAIL no systemMessage for run-ticket"; exit 1; }
echo "OK  run-ticket triggers reminder"

# 3. Skill invocation of resume-run -> NO reminder (resume-run is the dispatcher)
out="$(printf '%s' '{"tool_name":"Skill","tool_input":{"skill":"bugfix:resume-run"}}' | "$HOOK")"
[[ -z "$out" ]] || { echo "FAIL resume-run triggered a reminder (should be silent)"; echo "$out"; exit 1; }
echo "OK  resume-run is silent"

# 4. Non-bugfix skill -> silent
out="$(printf '%s' '{"tool_name":"Skill","tool_input":{"skill":"superpowers:brainstorming"}}' | "$HOOK")"
[[ -z "$out" ]] || { echo "FAIL non-bugfix skill triggered a reminder"; echo "$out"; exit 1; }
echo "OK  non-bugfix skill is silent"

# 5. Non-Skill tool -> silent
out="$(printf '%s' '{"tool_name":"Bash","tool_input":{"command":"ls"}}' | "$HOOK")"
[[ -z "$out" ]] || { echo "FAIL non-Skill tool triggered a reminder"; echo "$out"; exit 1; }
echo "OK  non-Skill tool is silent"

# 6. Malformed event -> silent, no crash
out="$(printf '%s' 'not json at all' | "$HOOK" 2>/dev/null || true)"
[[ -z "$out" ]] || { echo "FAIL malformed event produced output"; exit 1; }
echo "OK  malformed event handled safely"

# 7. Missing fields -> silent
out="$(printf '%s' '{}' | "$HOOK")"
[[ -z "$out" ]] || { echo "FAIL empty JSON produced output"; exit 1; }
echo "OK  empty JSON handled safely"

echo "ALL test-post-tool-use-hook tests passed"
