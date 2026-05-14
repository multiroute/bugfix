#!/usr/bin/env bash
# Usage: lock-acquire.sh <lock_path> <session_id> <stage>
# Atomically creates <lock_path> with JSON {pid, session_id, stage, acquired_at}.
# Stage MUST be one of the 6 stages defined in schemas/lock.schema.json.
# session_id MUST be non-empty (matches the schema's minLength: 1).
# Exit 0: lock acquired (initial create OR stolen from a dead pid via best-effort
#         overwrite — see "Steal race" note below).
# Exit 1: lock is held by a live pid; refuses.
# Exit 2: bad arguments (wrong arg count OR invalid stage OR empty session_id).
# Exit 3: I/O failure (e.g. parent dir missing, permission denied).
#
# Steal race: when the helper decides to overwrite a corrupt or stale lock,
# the overwrite uses a plain `printf >` not an atomic rename. Two concurrent
# stealers can both observe a dead pid and both write — the second wins
# without error. v1 accepts this because §9.5 of the design spec assumes
# one parent invocation per ticket; concurrent stealers would already
# violate that invariant.
#
# Event emission: on successful acquisition or steal, the helper emits a
# lock_acquired or lock_stolen event via events-append.sh — but only if an
# `EVENTS_LOG_PATH` env var is set by the caller. The helper itself stays
# decoupled from the events log location; callers (typically stage skills)
# point it at the ticket-specific .bugfix/runs/<id>.events.log.
set -euo pipefail

if [[ $# -ne 3 ]]; then
  echo "usage: lock-acquire.sh <lock_path> <session_id> <stage>" >&2
  exit 2
fi

lock_path="$1"
session_id="$2"
stage="$3"

# session_id must be non-empty (matches schemas/lock.schema.json minLength: 1).
if [[ -z "$session_id" ]]; then
  echo "lock-acquire: session_id must be non-empty" >&2
  exit 2
fi

# Validate stage against the 6 values defined in schemas/lock.schema.json.
# Mirroring the schema's enum here keeps lock files schema-valid by construction.
case "$stage" in
  intake|planning|executing|finishing|ci-watching|pr-reviewing) ;;
  *)
    echo "lock-acquire: invalid stage '$stage' (must be one of: intake, planning, executing, finishing, ci-watching, pr-reviewing)" >&2
    exit 2
    ;;
esac

pid="${PPID:-$$}"
# ISO 8601 with millisecond precision. Two events emitted within the same
# second on a fast stage no longer share `t` and lose ordering.
acquired_at="$(python3 -c '
from datetime import datetime, timezone
now = datetime.now(timezone.utc)
print(now.strftime("%Y-%m-%dT%H:%M:%S.") + f"{now.microsecond // 1000:03d}Z")
')"

payload="$(PID="$pid" SESSION_ID="$session_id" STAGE="$stage" ACQUIRED_AT="$acquired_at" python3 -c '
import json, os
print(json.dumps({
  "pid": int(os.environ["PID"]),
  "session_id": os.environ["SESSION_ID"],
  "stage": os.environ["STAGE"],
  "acquired_at": os.environ["ACQUIRED_AT"],
}))
')"

# Helper: emit a lock event if EVENTS_LOG_PATH is set. Failures here are
# non-fatal — the lock acquisition itself has already succeeded by the time we
# call this. The event log helps audit but isn't load-bearing for correctness.
emit_lock_event() {
  local event="$1"
  [[ -n "${EVENTS_LOG_PATH:-}" ]] || return 0
  local script_dir
  script_dir="$(cd "$(dirname "$0")" && pwd)"
  local detail
  detail="$(PID="$pid" SESSION_ID="$session_id" python3 -c '
import json, os
print(json.dumps({"pid": int(os.environ["PID"]), "session_id": os.environ["SESSION_ID"]}))
')"
  "$script_dir/events-append.sh" "$EVENTS_LOG_PATH" "$event" "$stage" "$detail" 2>/dev/null || true
}

# Attempt atomic create (noclobber-based O_EXCL semantics).
if ( set -o noclobber; printf '%s' "$payload" > "$lock_path" ) 2>/dev/null; then
  emit_lock_event lock_acquired
  exit 0
fi

# Atomic create did not succeed. Distinguish "file exists" from "I/O failed":
if [[ ! -e "$lock_path" ]]; then
  echo "lock-acquire: I/O failure writing $lock_path (parent dir missing or permission denied)" >&2
  exit 3
fi

# Lock exists. Read existing pid and check liveness.
existing_pid="$(LOCK_PATH="$lock_path" python3 -c '
import json, os, sys
try:
    print(json.load(open(os.environ["LOCK_PATH"]))["pid"])
except (KeyError, ValueError, TypeError):
    sys.exit(1)
' 2>/dev/null || echo "")"
if [[ -z "$existing_pid" ]]; then
  # Corrupt lock — overwrite (treat as stale).
  printf '%s' "$payload" > "$lock_path"
  emit_lock_event lock_stolen
  exit 0
fi

if kill -0 "$existing_pid" 2>/dev/null; then
  # Live pid holds the lock.
  echo "lock held by pid=$existing_pid, refusing" >&2
  exit 1
fi

# Stale: pid is dead. Steal.
printf '%s' "$payload" > "$lock_path"
emit_lock_event lock_stolen
exit 0
