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
PLUGIN_ROOT="$PLUGIN_ROOT" LOG="$LOG" python3 -c "
import json, os, sys
sys.path.insert(0, os.path.join(os.environ['PLUGIN_ROOT'], 'lib'))
from jsonschema_mini import validate
schema = json.load(open(os.path.join(os.environ['PLUGIN_ROOT'], 'schemas/events.schema.json')))
with open(os.environ['LOG']) as f:
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

# Case 5: block_and_comment with valid exit_kind is accepted.
"$APPEND" "$LOG" block_and_comment intake '{"exit_kind":"needs-info","reason":"missing info"}' \
  || { echo "FAIL block_and_comment with valid exit_kind should be accepted"; exit 1; }
echo "OK  block_and_comment with valid exit_kind accepted"

# Case 6: block_and_comment without exit_kind is rejected (schema conditional).
if "$APPEND" "$LOG" block_and_comment intake '{"reason":"forgot exit_kind"}' 2>/dev/null; then
  echo "FAIL block_and_comment missing exit_kind should have been rejected"; exit 1
else
  echo "OK  block_and_comment missing exit_kind rejected"
fi

# Case 7: block_and_comment with exit_kind outside the enum is rejected.
if "$APPEND" "$LOG" block_and_comment intake '{"exit_kind":"fatal"}' 2>/dev/null; then
  echo "FAIL block_and_comment with bad exit_kind should have been rejected"; exit 1
else
  echo "OK  block_and_comment with bad exit_kind rejected"
fi

echo "PASS"
