#!/usr/bin/env bash
set -euo pipefail
PLUGIN_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCHEMA="$PLUGIN_ROOT/schemas/run-state.schema.json"
FIXTURES="$PLUGIN_ROOT/tests/fixtures"

validate() {
  local fixture="$1"
  local expect="$2"  # "valid" or "invalid"
  if PLUGIN_ROOT="$PLUGIN_ROOT" SCHEMA="$SCHEMA" FIXTURE="$fixture" python3 -c "
import json, os, sys
sys.path.insert(0, os.path.join(os.environ['PLUGIN_ROOT'], 'lib'))
from jsonschema_mini import validate, ValidationError
schema = json.load(open(os.environ['SCHEMA']))
doc = json.load(open(os.environ['FIXTURE']))
try:
    validate(doc, schema)
    print('valid')
except ValidationError as e:
    print('invalid')
" | grep -q "^$expect$"; then
    echo "OK  $fixture expected=$expect"
  else
    echo "FAIL $fixture expected=$expect"
    exit 1
  fi
}

validate "$FIXTURES/state-valid.json" valid
validate "$FIXTURES/state-blocked.json" valid
validate "$FIXTURES/state-terminal.json" valid
validate "$FIXTURES/state-invalid-missing-stage.json" invalid

# C2: terminal and blocked_reason are mutually exclusive.
validate "$FIXTURES/state-invalid-both-terminal-and-blocked.json" invalid

# C2: 'blocked' is no longer a terminal enum value (it's a non-terminal pause).
validate "$FIXTURES/state-invalid-terminal-blocked-enum.json" invalid

# Schema must not contain 'blocked' in the terminal enum.
if grep -A 10 '"terminal":' "$SCHEMA" | grep -qE '"blocked"'; then
  echo "FAIL terminal enum still contains 'blocked'"
  exit 1
fi
echo "OK  terminal enum does not contain 'blocked'"

echo "PASS"
