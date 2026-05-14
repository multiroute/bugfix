#!/usr/bin/env bash
# Transition-graph lint.
#
# Verifies that the stage-machine transition graph is consistent across the
# 2 places it's currently duplicated:
#
# - run-state.schema.json:current_stage.enum (6 stages)
# - events.schema.json:stage.enum
#
# (Lock schema, lib/lock-acquire.sh, and resume-run's dispatch table were
# removed when the plugin dropped split-session mode; run-ticket's inlined
# dispatch table is the new single source of truth and is validated in the
# run-ticket-skill test, not here.)
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

echo "PASS"
