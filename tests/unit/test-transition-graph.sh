#!/usr/bin/env bash
# Transition-graph lint.
#
# Verifies that the stage-machine transition graph is consistent across the
# 3 places it's currently duplicated:
#
# - run-state.schema.json:current_stage.enum (6 stages)
# - events.schema.json:stage.enum
# - run-ticket/SKILL.md dispatch table
#
# (Lock schema, lib/lock-acquire.sh, and resume-run's dispatch table were
# removed when the plugin dropped split-session mode; run-ticket's inlined
# dispatch table is the new single source of truth alongside the two schemas.)
set -euo pipefail
PLUGIN_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

# Expected canonical set (in alphabetical order for stable comparison).
EXPECTED="$(printf 'ci-watching\nexecuting\nfinishing\nintake\nplanning\npr-reviewing\n')"

extract_state_schema() {
  python3 -c "
import json
schema = json.load(open('$PLUGIN_ROOT/schemas/run-state.schema.json'))
print('\n'.join(sorted(schema['properties']['current_stage']['enum'])))
"
}

extract_events_schema() {
  python3 -c "
import json
schema = json.load(open('$PLUGIN_ROOT/schemas/events.schema.json'))
print('\n'.join(sorted(schema['properties']['stage']['enum'])))
"
}

extract_run_ticket_table() {
  # The dispatch table has lines like "| `<stage>` | `skills/.../SKILL.md` |".
  grep -E '^\| `[a-z-]+` \| `skills/' "$PLUGIN_ROOT/skills/run-ticket/SKILL.md" \
    | sed -E 's/^\| `([a-z-]+)` .*/\1/' | sort
}

compare() {
  local name="$1" actual="$2"
  if [[ "$actual" != "$EXPECTED" ]]; then
    echo "FAIL $name diverges from canonical stage set"
    echo "expected:"; echo "$EXPECTED" | sed 's/^/  /'
    echo "actual:";   echo "$actual"   | sed 's/^/  /'
    diff <(echo "$EXPECTED") <(echo "$actual") || true
    exit 1
  fi
  echo "OK  $name matches canonical stage set"
}

compare "run-state.schema.json"   "$(extract_state_schema)"
compare "events.schema.json"      "$(extract_events_schema)"
compare "run-ticket/SKILL.md"     "$(extract_run_ticket_table)"

# Verify that for each stage in run-ticket's table, the mapped skill file exists.
python3 <<PY
import re, os
plugin_root = "$PLUGIN_ROOT"
with open(os.path.join(plugin_root, "skills/run-ticket/SKILL.md")) as f:
    body = f.read()
pat = re.compile(r'^\| \`([a-z-]+)\` \| \`(skills/[^/]+/SKILL\.md)\` \|', re.M)
missing = []
for stage, path in pat.findall(body):
    full = os.path.join(plugin_root, path)
    if not os.path.isfile(full):
        missing.append((stage, path))
if missing:
    print("FAIL skill files missing for stages:")
    for s, p in missing:
        print(f"  {s} -> {p}")
    raise SystemExit(1)
print(f"OK  all {len(pat.findall(body))} mapped skill files exist")
PY

echo "PASS"
