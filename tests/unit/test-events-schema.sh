#!/usr/bin/env bash
set -euo pipefail
PLUGIN_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCHEMA="$PLUGIN_ROOT/schemas/events.schema.json"
FIXTURES="$PLUGIN_ROOT/tests/fixtures"

validate_jsonl() {
  local fixture="$1"
  local expect="$2"  # "valid" or "invalid"
  python3 -c "
import json
from jsonschema import validate, ValidationError
schema = json.load(open('$SCHEMA'))
all_valid = True
with open('$fixture') as f:
    for i, line in enumerate(f, 1):
        line = line.strip()
        if not line:
            continue
        try:
            validate(json.loads(line), schema)
        except ValidationError:
            all_valid = False
            break
print('valid' if all_valid else 'invalid')
" | grep -q "^$expect$" || { echo "FAIL $fixture expected=$expect"; exit 1; }
  echo "OK  $fixture expected=$expect"
}

validate_jsonl "$FIXTURES/events-valid.jsonl" valid
validate_jsonl "$FIXTURES/events-invalid-bad-event-name.jsonl" invalid

# R3-I5: block_and_comment events must have detail.exit_kind from the enum.
validate_jsonl "$FIXTURES/events-invalid-bad-exit-kind.jsonl" invalid
validate_jsonl "$FIXTURES/events-invalid-bandc-missing-exit-kind.jsonl" invalid
echo "PASS"
