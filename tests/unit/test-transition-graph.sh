#!/usr/bin/env bash
# Transition-graph lint (R4 #1 from deep code review).
#
# Verifies that the stage-machine transition graph is consistent across the
# 5 places it's currently duplicated:
#
# - run-state.schema.json:current_stage.enum (6 stages)
# - lock.schema.json:stage.enum
# - events.schema.json:stage.enum
# - lib/lock-acquire.sh case statement
# - resume-run/SKILL.md dispatch table
#
# Catches the regression class where a maintainer adds/renames a stage in
# only one of the five locations.
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

extract_lock_schema() {
  python3 -c "
import json
schema = json.load(open('$PLUGIN_ROOT/schemas/lock.schema.json'))
print('\n'.join(sorted(schema['properties']['stage']['enum'])))
"
}

extract_events_schema() {
  python3 -c "
import json
schema = json.load(open('$PLUGIN_ROOT/schemas/events.schema.json'))
print('\n'.join(sorted(schema['properties']['stage']['enum'])))
"
}

extract_lock_acquire() {
  # Find the case statement and extract the | separated stages.
  grep -E '^[[:space:]]*intake\|planning\|executing\|finishing\|ci-watching\|pr-reviewing\)' "$PLUGIN_ROOT/lib/lock-acquire.sh" \
    | sed 's/) ;;//; s/)//' | tr '|' '\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | sort
}

extract_resume_run_table() {
  # The dispatch table has lines like "| `<stage>` | `skills/.../SKILL.md` |".
  # Tighten the match on the 2nd column ("\`skills/") so the per-stage
  # model-hints table — same first-column shape — doesn't leak in.
  grep -E '^\| `[a-z-]+` \| `skills/' "$PLUGIN_ROOT/skills/resume-run/SKILL.md" \
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
compare "lock.schema.json"        "$(extract_lock_schema)"
compare "events.schema.json"      "$(extract_events_schema)"
compare "lib/lock-acquire.sh"     "$(extract_lock_acquire)"
compare "resume-run/SKILL.md"     "$(extract_resume_run_table)"

# Also verify that for each stage in resume-run's table, the mapped skill file exists.
python3 <<PY
import re, os
plugin_root = "$PLUGIN_ROOT"
with open(os.path.join(plugin_root, "skills/resume-run/SKILL.md")) as f:
    body = f.read()
# Match lines like: | \`intake\` | \`skills/ticket-intake/SKILL.md\` |
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
