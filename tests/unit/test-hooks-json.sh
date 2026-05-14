#!/usr/bin/env bash
set -euo pipefail
PLUGIN_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HOOKS="$PLUGIN_ROOT/hooks/hooks.json"

[[ -f "$HOOKS" ]] || { echo "FAIL hooks.json missing"; exit 1; }
python3 -c "import json; json.load(open('$HOOKS'))" || { echo "FAIL hooks.json not valid JSON"; exit 1; }

# Must declare SessionStart with the right matcher and command.
# R4-N4: hooks.json must declare ONLY the SessionStart hook — any other
# hook key (PostToolUse, PreToolUse, etc.) would expand the plugin's
# permission surface unexpectedly. The plugin's contract is "inject the
# meta-skill once per session"; nothing else.
python3 -c "
import json
h = json.load(open('$HOOKS'))
hooks_obj = h['hooks']
assert set(hooks_obj.keys()) == {'SessionStart'}, f'hooks.json must declare ONLY SessionStart, got {set(hooks_obj.keys())}'
ss = hooks_obj['SessionStart']
assert isinstance(ss, list) and len(ss) >= 1, ss
entry = ss[0]
assert entry['matcher'] == 'startup|clear|compact', entry
cmd = entry['hooks'][0]
assert cmd['type'] == 'command', cmd
assert 'session-start' in cmd['command'], cmd
assert 'run-hook.cmd' in cmd['command'], cmd
" || { echo "FAIL hooks.json shape wrong"; exit 1; }

echo "PASS"
