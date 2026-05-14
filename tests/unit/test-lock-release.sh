#!/usr/bin/env bash
set -euo pipefail
PLUGIN_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
RELEASE="$PLUGIN_ROOT/lib/lock-release.sh"
WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

# Case 1: release existing lock (no session_id check) succeeds and is unconditional.
echo "{}" > "$WORKDIR/lock"
"$RELEASE" "$WORKDIR/lock"
[[ ! -e "$WORKDIR/lock" ]] || { echo "FAIL lock still present after unconditional release"; exit 1; }
echo "OK  unconditional release removes lock"

# Case 2: release nonexistent lock is idempotent (succeeds).
"$RELEASE" "$WORKDIR/lock"
echo "OK  release of missing lock is idempotent"

# Case 3: matching session_id releases the lock.
cat > "$WORKDIR/lock" <<'JSON'
{"pid": 1234, "session_id": "session-alice", "stage": "intake", "acquired_at": "2026-05-14T00:00:00Z"}
JSON
"$RELEASE" "$WORKDIR/lock" "session-alice"
[[ ! -e "$WORKDIR/lock" ]] || { echo "FAIL matching-session lock not released"; exit 1; }
echo "OK  matching-session release removes lock"

# Case 4: non-matching session_id is a NO-OP (lock stays, exit 0).
cat > "$WORKDIR/lock" <<'JSON'
{"pid": 1234, "session_id": "session-alice", "stage": "intake", "acquired_at": "2026-05-14T00:00:00Z"}
JSON
"$RELEASE" "$WORKDIR/lock" "session-bob"  # different session
[[ -e "$WORKDIR/lock" ]] || { echo "FAIL non-matching-session release should NOT have removed foreign lock"; exit 1; }
echo "OK  non-matching-session release is a NO-OP"

# Case 5: unparseable lock file -> exit 1, lock stays.
echo "this is not JSON" > "$WORKDIR/lock"
if "$RELEASE" "$WORKDIR/lock" "session-alice" 2>/dev/null; then
  echo "FAIL unparseable lock release should have exited non-zero"
  exit 1
fi
[[ -e "$WORKDIR/lock" ]] || { echo "FAIL unparseable lock should have been left in place"; exit 1; }
echo "OK  unparseable lock is preserved (exit 1, lock untouched)"

rm -f "$WORKDIR/lock"

# Case 6: usage check.
if "$RELEASE" 2>/dev/null; then
  echo "FAIL no-args invocation should have exited non-zero"
  exit 1
fi
if "$RELEASE" a b c 2>/dev/null; then
  echo "FAIL three-args invocation should have exited non-zero"
  exit 1
fi
echo "OK  usage check rejects wrong arg counts"

echo "PASS"
