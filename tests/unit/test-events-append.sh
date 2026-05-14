#!/usr/bin/env bash
set -euo pipefail
PLUGIN_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
APPEND="$PLUGIN_ROOT/lib/events-append.sh"
WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT
LOG="$WORKDIR/events.log"

# Case 1: valid event appends and the file ends in newline.
"$APPEND" "$LOG" intake_started intake '{"classification":"bug"}'
[[ -f "$LOG" ]] || { echo "FAIL log not created"; exit 1; }
line_count="$(wc -l < "$LOG")"
[[ "$line_count" -eq 1 ]] || { echo "FAIL expected 1 line, got $line_count"; exit 1; }
echo "OK  first append wrote one line"

# Case 1b: line is valid against events schema.
python3 -c "
import json
from jsonschema import validate
schema = json.load(open('$PLUGIN_ROOT/schemas/events.schema.json'))
with open('$LOG') as f:
    for line in f:
        validate(json.loads(line), schema)
" || { echo "FAIL appended line invalid against schema"; exit 1; }
echo "OK  appended line valid against schema"

# Case 2: second append produces two lines.
"$APPEND" "$LOG" intake_passed intake '{}'
line_count="$(wc -l < "$LOG")"
[[ "$line_count" -eq 2 ]] || { echo "FAIL expected 2 lines, got $line_count"; exit 1; }
echo "OK  second append wrote second line"

# Case 3: invalid event name exits non-zero.
if "$APPEND" "$LOG" not_a_real_event intake '{}' 2>/dev/null; then
  echo "FAIL invalid event name should have been rejected"; exit 1
else
  echo "OK  invalid event name rejected"
fi

# Case 4: detail must be valid JSON.
if "$APPEND" "$LOG" intake_started intake 'not json' 2>/dev/null; then
  echo "FAIL invalid detail JSON should have been rejected"; exit 1
else
  echo "OK  invalid detail JSON rejected"
fi

echo "PASS"
