#!/usr/bin/env bash
set -euo pipefail
PLUGIN_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
ACQUIRE="$PLUGIN_ROOT/lib/lock-acquire.sh"
WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

cd "$WORKDIR"

# Case 1: first acquire succeeds.
if "$ACQUIRE" "$WORKDIR/lock" sess_a executing >/dev/null; then
  echo "OK  first acquire succeeded"
else
  echo "FAIL first acquire failed"; exit 1
fi

# Case 1b: lock contents valid JSON with required fields.
python3 -c "
import json
doc = json.load(open('$WORKDIR/lock'))
assert doc['session_id'] == 'sess_a', doc
assert doc['stage'] == 'executing', doc
assert isinstance(doc['pid'], int) and doc['pid'] > 0, doc
assert 'acquired_at' in doc, doc
" || { echo "FAIL lock contents wrong"; exit 1; }
echo "OK  lock contents valid"

# Case 2: second acquire (same lock present, live pid) refuses with exit code 1.
if "$ACQUIRE" "$WORKDIR/lock" sess_b executing >/dev/null 2>&1; then
  echo "FAIL second acquire should have refused"; exit 1
else
  echo "OK  second acquire refused"
fi

# Case 3: stale lock (pid that's definitely dead) gets stolen.
python3 -c "
import json, sys
doc = json.load(open('$WORKDIR/lock'))
doc['pid'] = 99  # almost certainly dead
json.dump(doc, open('$WORKDIR/lock', 'w'))
"
if "$ACQUIRE" "$WORKDIR/lock" sess_c executing >/dev/null; then
  echo "OK  stale lock stolen"
else
  echo "FAIL stale lock should have been stolen"; exit 1
fi

# Verify stolen lock has session_id sess_c
python3 -c "
import json
doc = json.load(open('$WORKDIR/lock'))
assert doc['session_id'] == 'sess_c', doc
" || { echo "FAIL stolen lock wrong session_id"; exit 1; }
echo "OK  stolen lock has correct session_id"

# Case 6: missing parent dir exits 3, not 1.
set +e
"$ACQUIRE" "$WORKDIR/no-such-subdir/lock" sess_x intake >/dev/null 2>&1
rc=$?
set -e
[[ "$rc" -eq 3 ]] || { echo "FAIL missing parent dir should exit 3 (got $rc)"; exit 1; }
echo "OK  missing parent dir exits 3"

# Case 7: garbage in lock file is treated as stale.
echo "not json" > "$WORKDIR/lock"
"$ACQUIRE" "$WORKDIR/lock" sess_d intake >/dev/null || { echo "FAIL corrupt-lock recovery"; exit 1; }
python3 -c "
import json
doc = json.load(open('$WORKDIR/lock'))
assert doc['session_id'] == 'sess_d', doc
" || { echo "FAIL corrupt lock not overwritten correctly"; exit 1; }
echo "OK  corrupt lock recovered"

# Case 8: missing args exit 2.
set +e
"$ACQUIRE" >/dev/null 2>&1
rc=$?
set -e
[[ "$rc" -eq 2 ]] || { echo "FAIL no-args should exit 2 (got $rc)"; exit 1; }
echo "OK  bad arg count exits 2"

# Case 9: apostrophe in session_id no longer breaks (I1 regression test).
rm -f "$WORKDIR/lock"
"$ACQUIRE" "$WORKDIR/lock" "sess_d'oh" intake >/dev/null || { echo "FAIL apostrophe session_id"; exit 1; }
python3 -c "
import json
doc = json.load(open('$WORKDIR/lock'))
assert doc['session_id'] == \"sess_d'oh\", doc
" || { echo "FAIL apostrophe session_id not preserved"; exit 1; }
echo "OK  apostrophe in session_id preserved"

# Case 10: stage outside the 6-value enum rejected with exit 2.
# Schema (lock.schema.json) restricts stage; helper must mirror that
# constraint so the lock file is schema-valid by construction.
rm -f "$WORKDIR/lock"
set +e
"$ACQUIRE" "$WORKDIR/lock" sess_e "not-a-real-stage" >/dev/null 2>&1
rc=$?
set -e
[[ "$rc" -eq 2 ]] || { echo "FAIL invalid stage should exit 2 (got $rc)"; exit 1; }
[[ ! -e "$WORKDIR/lock" ]] || { echo "FAIL invalid stage should not write a lock file"; exit 1; }
echo "OK  invalid stage rejected"

# Case 11: shell-injection attempt in stage rejected (stage'$(...)" form).
# The case statement matches literally, not via shell expansion, so the
# whole string is the stage value and falls through to the rejection branch.
set +e
"$ACQUIRE" "$WORKDIR/lock" sess_f "stage'\$(echo evil)" >/dev/null 2>&1
rc=$?
set -e
[[ "$rc" -eq 2 ]] || { echo "FAIL injection-attempt stage should exit 2 (got $rc)"; exit 1; }
[[ ! -e "$WORKDIR/lock" ]] || { echo "FAIL injection-attempt stage should not write a lock file"; exit 1; }
echo "OK  injection-attempt stage rejected"

# Case 12: each of the 6 valid stages accepted.
for s in intake planning executing finishing ci-watching pr-reviewing; do
  rm -f "$WORKDIR/lock"
  "$ACQUIRE" "$WORKDIR/lock" "sess_$s" "$s" >/dev/null \
    || { echo "FAIL valid stage '$s' rejected"; exit 1; }
  python3 -c "
import json
assert json.load(open('$WORKDIR/lock'))['stage'] == '$s'
" || { echo "FAIL stage '$s' not recorded"; exit 1; }
done
echo "OK  all 6 valid stages accepted"

# Case 13: empty session_id rejected.
rm -f "$WORKDIR/lock"
set +e
"$ACQUIRE" "$WORKDIR/lock" "" executing >/dev/null 2>&1
rc=$?
set -e
[[ "$rc" -eq 2 ]] || { echo "FAIL empty session_id should exit 2 (got $rc)"; exit 1; }
[[ ! -e "$WORKDIR/lock" ]] || { echo "FAIL empty session_id should not write a lock"; exit 1; }
echo "OK  empty session_id rejected"

# Case 14: acquired_at has millisecond precision (matches the events-append helper).
rm -f "$WORKDIR/lock"
"$ACQUIRE" "$WORKDIR/lock" sess_ms executing >/dev/null
python3 -c "
import json, re
doc = json.load(open('$WORKDIR/lock'))
assert re.match(r'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$', doc['acquired_at']), doc['acquired_at']
" || { echo "FAIL acquired_at lacks millisecond precision"; exit 1; }
echo "OK  acquired_at has millisecond precision"

# Case 15: lock_acquired event emitted when EVENTS_LOG_PATH is set.
rm -f "$WORKDIR/lock" "$WORKDIR/events.log"
EVENTS_LOG_PATH="$WORKDIR/events.log" "$ACQUIRE" "$WORKDIR/lock" sess_ev executing >/dev/null
[[ -f "$WORKDIR/events.log" ]] || { echo "FAIL events.log not created"; exit 1; }
python3 -c "
import json
with open('$WORKDIR/events.log') as f:
    rec = json.loads(f.readline())
assert rec['event'] == 'lock_acquired', rec
assert rec['stage'] == 'executing', rec
assert rec['detail']['session_id'] == 'sess_ev', rec
" || { echo "FAIL lock_acquired event malformed"; exit 1; }
echo "OK  lock_acquired event emitted when EVENTS_LOG_PATH is set"

# Case 16: lock_stolen event emitted on stale-recovery.
# Make the existing lock stale (pid 99 is almost certainly dead), then re-acquire.
python3 -c "
import json
doc = json.load(open('$WORKDIR/lock'))
doc['pid'] = 99
json.dump(doc, open('$WORKDIR/lock', 'w'))
"
> "$WORKDIR/events.log"  # truncate
EVENTS_LOG_PATH="$WORKDIR/events.log" "$ACQUIRE" "$WORKDIR/lock" sess_steal executing >/dev/null
python3 -c "
import json
with open('$WORKDIR/events.log') as f:
    rec = json.loads(f.readline())
assert rec['event'] == 'lock_stolen', rec
" || { echo "FAIL lock_stolen event malformed"; exit 1; }
echo "OK  lock_stolen event emitted on stale-recovery"

# Case 17: when EVENTS_LOG_PATH is unset, no event is emitted (no spurious writes).
rm -f "$WORKDIR/lock" "$WORKDIR/events.log"
unset EVENTS_LOG_PATH
"$ACQUIRE" "$WORKDIR/lock" sess_noev executing >/dev/null
[[ ! -f "$WORKDIR/events.log" ]] || { echo "FAIL events.log should not have been touched"; exit 1; }
echo "OK  no event emitted when EVENTS_LOG_PATH unset"

echo "PASS"
