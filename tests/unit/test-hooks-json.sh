#!/usr/bin/env bash
set -euo pipefail
PLUGIN_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HOOKS="$PLUGIN_ROOT/hooks/hooks.json"

[[ -f "$HOOKS" ]] || { echo "FAIL hooks.json missing"; exit 1; }
python3 -c "import json; json.load(open('$HOOKS'))" || { echo "FAIL hooks.json not valid JSON"; exit 1; }

# Must declare SessionStart with the right matcher and command.
# R4-N4: hooks.json must declare ONLY the SessionStart and PostToolUse
# hooks — any other hook key (PreToolUse, UserPromptSubmit, etc.) would
# expand the plugin's permission surface unexpectedly. The plugin's
# hook-permission surface is a tracked, audited list; adding any other
# hook key is forbidden without an explicit design change.
python3 -c "
import json
h = json.load(open('$HOOKS'))
hooks_obj = h['hooks']
assert set(hooks_obj.keys()) == {'SessionStart', 'PostToolUse'}, f'hooks.json must declare ONLY SessionStart and PostToolUse, got {set(hooks_obj.keys())}'
ss = hooks_obj['SessionStart']
assert isinstance(ss, list) and len(ss) >= 1, ss
entry = ss[0]
assert entry['matcher'] == 'startup|clear|compact', entry
cmd = entry['hooks'][0]
assert cmd['type'] == 'command', cmd
assert 'session-start' in cmd['command'], cmd
assert 'run-hook.cmd' in cmd['command'], cmd
" || { echo "FAIL hooks.json shape wrong"; exit 1; }

# PostToolUse matcher block must be registered and point at the right wrapper.
jq -e '.hooks.PostToolUse | length > 0' "$PLUGIN_ROOT/hooks/hooks.json" >/dev/null \
  || { echo "FAIL hooks.json missing PostToolUse block"; exit 1; }
echo "OK  PostToolUse block present"

jq -e '.hooks.PostToolUse[] | select(.matcher == "Skill") | .hooks[] | select(.command | contains("post-tool-use-stage-handoff"))' "$PLUGIN_ROOT/hooks/hooks.json" >/dev/null \
  || { echo "FAIL hooks.json PostToolUse does not register post-tool-use-stage-handoff"; exit 1; }
echo "OK  PostToolUse registers post-tool-use-stage-handoff via run-hook.cmd"

echo "PASS"
