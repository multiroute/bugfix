#!/usr/bin/env bash
# Usage: lock-release.sh <lock_path> [<session_id>]
#
# Idempotently removes the lock file. Missing file is not an error (this
# preserves the "release is always safe" guarantee callers depend on).
#
# Ownership check: if <session_id> is provided AND the lock file's session_id
# field is readable AND differs from the caller's, the release is a NO-OP
# (exit 0). This prevents a zombie-original release path from deleting a
# successor's lock after stale-recovery has handed ownership over.
#
# Exit codes:
#   0  - lock removed (or absent, or owned by someone else — all "release was safe")
#   1  - I/O or parse error while inspecting the lock file
#   2  - usage error
set -euo pipefail

if [[ $# -lt 1 || $# -gt 2 ]]; then
  echo "usage: lock-release.sh <lock_path> [<session_id>]" >&2
  exit 2
fi

lock_path="$1"
expected_session_id="${2:-}"

# Missing lock file is fine — release is idempotent.
[[ -e "$lock_path" ]] || exit 0

# If no session_id was provided, fall back to the historical unconditional release.
if [[ -z "$expected_session_id" ]]; then
  rm -f "$lock_path"
  exit 0
fi

# Read the existing lock's session_id. If the file is unreadable or unparseable,
# leave it in place and exit 1 — better to keep a possibly-foreign lock than to
# overwrite it blindly. This is the cautious failure mode.
actual_session_id="$(LOCK_PATH="$lock_path" python3 - <<'PY' 2>/dev/null || true
import json, os, sys
try:
    with open(os.environ["LOCK_PATH"], "r", encoding="utf-8") as fh:
        data = json.load(fh)
    sid = data.get("session_id", "")
    sys.stdout.write(str(sid))
except Exception:
    sys.exit(1)
PY
)"

# Empty result means the read/parse failed. Don't risk releasing a foreign lock.
if [[ -z "$actual_session_id" ]]; then
  echo "lock-release: cannot parse lock file at $lock_path; leaving in place" >&2
  exit 1
fi

# Ownership mismatch: caller doesn't own this lock. NO-OP, exit 0 — the caller's
# attempt to release is "safe" from their perspective even though we didn't
# actually delete anything.
if [[ "$actual_session_id" != "$expected_session_id" ]]; then
  exit 0
fi

# Caller owns the lock. Remove it.
rm -f "$lock_path"
