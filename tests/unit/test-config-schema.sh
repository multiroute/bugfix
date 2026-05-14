#!/usr/bin/env bash
set -euo pipefail
PLUGIN_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCHEMA="$PLUGIN_ROOT/schemas/config.schema.json"
FIXTURES="$PLUGIN_ROOT/tests/fixtures"

validate() {
  local fixture="$1"
  local expect="$2"
  python3 -c "
import json
from jsonschema import validate, ValidationError
schema = json.load(open('$SCHEMA'))
try:
    validate(json.load(open('$fixture')), schema)
    print('valid')
except ValidationError:
    print('invalid')
" | grep -q "^$expect$" || { echo "FAIL $fixture"; exit 1; }
  echo "OK  $fixture"
}

validate "$FIXTURES/config-valid.json" valid
validate "$FIXTURES/config-empty.json" valid

# model_hints.stages must reject keys outside the 6-stage enum.
validate "$FIXTURES/config-invalid-stage-key.json" invalid

# Schema must list all 6 stages as valid keys under model_hints.stages.
python3 -c "
import json
schema = json.load(open('$SCHEMA'))
stages_props = schema['properties']['model_hints']['properties']['stages']['properties']
expected = {'intake', 'planning', 'executing', 'finishing', 'ci-watching', 'pr-reviewing'}
assert set(stages_props.keys()) == expected, f'stages keys {set(stages_props.keys())} != {expected}'
" || { echo "FAIL model_hints.stages does not list all 6 canonical stages"; exit 1; }
echo "OK  model_hints.stages enumerates all 6 stages"

echo "PASS"
