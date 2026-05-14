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

echo "PASS"
