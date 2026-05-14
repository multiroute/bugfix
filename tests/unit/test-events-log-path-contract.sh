#!/usr/bin/env bash
# Verifies the events_log_path contract:
#
#   1. bugfix:run-ticket writes state.artifacts.events_log_path as an absolute
#      path at state initialization (before any stage cds into a worktree).
#   2. Every stage skill that emits events documents reading events_log_path
#      from state instead of constructing a relative .bugfix/runs/...
#      path. Relative paths break the audit log when the emitter's cwd is a
#      worktree — observed in a production run where executing-plan's
#      task_done emit failed with "No such file or directory" after cd-ing
#      into the worktree.
#
# Catches regressions where a new emit site reverts to the old
# relative-path template.
set -euo pipefail
PLUGIN_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

RUN_TICKET="$PLUGIN_ROOT/skills/run-ticket/SKILL.md"

# 1. run-ticket's state init computes the absolute events log path AND writes
#    it into state.artifacts.events_log_path.
grep -q 'RUNS_DIR="\$(cd \.bugfix/runs && pwd)"' "$RUN_TICKET" \
  || { echo "FAIL run-ticket does not resolve RUNS_DIR to an absolute path at init"; exit 1; }
grep -q 'EVENTS_LOG="\$RUNS_DIR/<ticket_id>\.events\.log"' "$RUN_TICKET" \
  || { echo "FAIL run-ticket does not derive EVENTS_LOG from RUNS_DIR at init"; exit 1; }
grep -q '"events_log_path": "\$EVENTS_LOG"' "$RUN_TICKET" \
  || { echo "FAIL run-ticket does not write artifacts.events_log_path at init"; exit 1; }
grep -q '"state_path": "\$STATE_PATH"' "$RUN_TICKET" \
  || { echo "FAIL run-ticket does not write artifacts.state_path at init"; exit 1; }
grep -q 'events-append\.sh "\$EVENTS_LOG" intake_started intake' "$RUN_TICKET" \
  || { echo "FAIL run-ticket does not emit intake_started using \$EVENTS_LOG"; exit 1; }
echo "OK  run-ticket initializes events_log_path/state_path absolutely and emits via \$EVENTS_LOG"

# 2. Every stage skill that emits events documents reading events_log_path
#    from state. Excludes run-ticket (covered above with its own bash block).
emit_skills=(
  "ticket-intake"
  "writing-plans"
  "executing-plan"
  "autonomous-finishing"
  "ci-watchdog"
  "pr-final-review"
  "block-and-comment"
)
for s in "${emit_skills[@]}"; do
  skill="$PLUGIN_ROOT/skills/$s/SKILL.md"
  [[ -f "$skill" ]] || { echo "FAIL missing skill file: $skill"; exit 1; }

  # The emit site must reference artifacts.events_log_path AND must NOT pass
  # a relative .bugfix/runs/<ticket...>.events.log literal to events-append.sh.
  grep -q "artifacts\.events_log_path" "$skill" \
    || { echo "FAIL $s does not read state.artifacts.events_log_path"; exit 1; }

  if grep -nE 'events-append\.sh[[:space:]]+"?\.bugfix/runs/<ticket' "$skill" >/dev/null; then
    echo "FAIL $s still passes a relative .bugfix/runs/... path to events-append.sh:"
    grep -nE 'events-append\.sh[[:space:]]+"?\.bugfix/runs/<ticket' "$skill"
    exit 1
  fi
  echo "OK  $s reads events_log_path from state (no relative emit template)"
done

# 3. Functional check: simulate run-ticket's state-init bash block and verify
#    the resulting state file has absolute paths in artifacts.
WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT
(
  cd "$WORKDIR"
  mkdir -p .bugfix/runs
  ticket_id="test-owner-test-repo-1"
  RUNS_DIR="$(cd .bugfix/runs && pwd)"
  EVENTS_LOG="$RUNS_DIR/${ticket_id}.events.log"
  STATE_PATH="$RUNS_DIR/${ticket_id}.json"
  cat > ".bugfix/runs/${ticket_id}.json" <<JSON
{
  "ticket_id": "${ticket_id}",
  "owner": "test-owner",
  "repo": "test-repo",
  "issue_number": 1,
  "started_at": "2026-05-15T00:00:00.000Z",
  "updated_at": "2026-05-15T00:00:00.000Z",
  "current_stage": "intake",
  "terminal": null,
  "base_branch": "main",
  "retries": {},
  "artifacts": {
    "events_log_path": "$EVENTS_LOG",
    "state_path": "$STATE_PATH"
  }
}
JSON
)
state_file="$WORKDIR/.bugfix/runs/test-owner-test-repo-1.json"
events_log_path="$(jq -r .artifacts.events_log_path "$state_file")"
state_path="$(jq -r .artifacts.state_path "$state_file")"
case "$events_log_path" in
  /*) echo "OK  events_log_path is absolute ($events_log_path)" ;;
  *)  echo "FAIL events_log_path is not absolute: $events_log_path"; exit 1 ;;
esac
case "$state_path" in
  /*) echo "OK  state_path is absolute ($state_path)" ;;
  *)  echo "FAIL state_path is not absolute: $state_path"; exit 1 ;;
esac

# 4. End-to-end: events-append.sh accepts the absolute path even from a
#    different cwd (simulating a sub-agent that has cd'd into a worktree).
mkdir -p "$WORKDIR/fake-worktree"
( cd "$WORKDIR/fake-worktree" && "$PLUGIN_ROOT/lib/events-append.sh" "$events_log_path" intake_started intake '{}' )
[[ -f "$events_log_path" ]] || { echo "FAIL events log was not created at absolute path"; exit 1; }
line_count="$(wc -l < "$events_log_path")"
[[ "$line_count" -eq 1 ]] || { echo "FAIL expected 1 event line, got $line_count"; exit 1; }
echo "OK  events-append.sh writes to absolute path even when invoked from a different cwd"

# Validate the appended line schema-passes.
PLUGIN_ROOT="$PLUGIN_ROOT" LOG="$events_log_path" python3 -c "
import json, os, sys
sys.path.insert(0, os.path.join(os.environ['PLUGIN_ROOT'], 'lib'))
from jsonschema_mini import validate
schema = json.load(open(os.path.join(os.environ['PLUGIN_ROOT'], 'schemas/events.schema.json')))
with open(os.environ['LOG']) as f:
    for line in f:
        validate(json.loads(line), schema)
" || { echo "FAIL appended event invalid against schema"; exit 1; }
echo "OK  appended event valid against schema"

echo "PASS"
