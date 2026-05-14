#!/usr/bin/env bash
# Usage: events-append.sh <log_path> <event> <stage> <detail-json>
# Appends one validated JSONL event line.
# Exit 0: appended.
# Exit 1: validation failed (bad event name, bad stage, malformed detail JSON, schema mismatch).
# Exit 2: bad arguments.
set -euo pipefail

if [[ $# -ne 4 ]]; then
  echo "usage: events-append.sh <log_path> <event> <stage> <detail-json>" >&2
  exit 2
fi

log_path="$1"
event="$2"
stage="$3"
detail="$4"

PLUGIN_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCHEMA="$PLUGIN_ROOT/schemas/events.schema.json"

# Build the record in Python, validate against schema, emit JSONL line.
# All inputs passed via env vars to avoid shell-interpolation injection.
line="$(EVENT="$event" STAGE="$stage" DETAIL="$detail" SCHEMA="$SCHEMA" python3 -c '
import json, os, sys, datetime
from jsonschema import validate, ValidationError
try:
    detail = json.loads(os.environ["DETAIL"])
except (json.JSONDecodeError, ValueError) as e:
    print(f"events-append: invalid detail JSON: {e}", file=sys.stderr)
    sys.exit(1)

now = datetime.datetime.now(datetime.timezone.utc)
# ISO 8601 with millisecond precision. Whole-second granularity is too coarse —
# two events fired within the same second on a fast stage would share `t` and
# lose ordering in the JSONL audit log.
ts = now.strftime("%Y-%m-%dT%H:%M:%S.") + f"{now.microsecond // 1000:03d}Z"
record = {
    "t": ts,
    "event": os.environ["EVENT"],
    "stage": os.environ["STAGE"],
    "detail": detail,
}
schema = json.load(open(os.environ["SCHEMA"]))
try:
    validate(record, schema)
except ValidationError as e:
    print(f"events-append: schema validation failed: {e.message}", file=sys.stderr)
    sys.exit(1)
print(json.dumps(record))
')"

printf '%s\n' "$line" >> "$log_path"
