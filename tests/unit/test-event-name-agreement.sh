#!/usr/bin/env bash
# Event-name agreement test (R4 #2 from deep code review).
#
# For every event name emitted by a stage skill body, the name MUST be a
# member of the events.schema.json enum. Catches the regression where a
# maintainer adds a new event in a skill body but forgets to declare it in
# the schema (events-append.sh validation would reject it at runtime).
#
# We also warn about events in the schema enum that no stage skill emits —
# dead enum space.
set -euo pipefail
PLUGIN_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

PLUGIN_ROOT="$PLUGIN_ROOT" python3 <<'PY'
import json, os, re, sys

plugin_root = os.environ["PLUGIN_ROOT"]
schema = json.load(open(os.path.join(plugin_root, "schemas/events.schema.json")))
enum = set(schema["properties"]["event"]["enum"])

stage_skills = [
    "ticket-intake", "writing-plans", "executing-plan",
    "autonomous-finishing", "ci-watchdog", "pr-final-review",
    "block-and-comment", "resume-run", "run-ticket",
]

# Strategy: scan skill bodies for explicit "emit X" or "events-append.sh ... X"
# patterns where X looks like an event name. We're conservative on what
# qualifies as an "emit reference" to avoid false positives from prose that
# happens to use a noun like "pr_opened" in a different context.
#
# A token counts as an emit-reference if EITHER:
#   - it appears as the 2nd whitespace-separated arg to events-append.sh
#   - it appears after the verb "Emit" / "emit" / "emits" / "emitting" /
#     "emitted" or in a backticked `event` near words "event", "emit"
patterns = [
    # events-append.sh "<event>" pattern
    re.compile(r'events-append\.sh[^"\n]*?["\'\s]+([a-z][a-z_]+)["\'\s]+'),
    re.compile(r'events-append\.sh[^\n]*?\s([a-z][a-z_]+)\s'),
    # "Emit `event_name`" / "emits `event_name`" / etc.
    re.compile(r'\b[Ee]mit(?:s|ted|ting)?\s+`([a-z][a-z_]+)`'),
]

emitted = set()
for skill in stage_skills:
    path = os.path.join(plugin_root, "skills", skill, "SKILL.md")
    if not os.path.isfile(path):
        continue
    with open(path) as fh:
        body = fh.read()
    for pat in patterns:
        for m in pat.finditer(body):
            emitted.add(m.group(1))

# Filter out obvious non-events: helper names, common nouns that happen to
# match the regex shape but are clearly not events. The schema is the
# authoritative list, so anything outside it AND outside this denylist will
# error.
denylist = {
    "state", "config", "ticket_id", "pr_number", "pr_url", "spec_path",
    "plan_path", "base_sha", "base_branch", "branch", "worktree_path",
    "blocked_reason", "current_stage", "terminal", "retries", "artifacts",
    "updated_at", "started_at", "next_poll_at", "comment_id", "run_id",
    "issue_number", "owner", "repo", "session_id", "stage", "status",
    "conclusion", "details_url", "failed_logs", "runs", "timed_out",
    "files_changed", "attempt", "poll_n", "task_number", "reason", "exit_kind",
    "model_hint", "spec_review", "code_quality_review", "ci", "planning",
}

# Event-shape filter: only flag candidates that have an underscore (every
# schema event except 'resumed' has one) OR are exactly 'resumed'. Single-
# word lowercase tokens like 'emit', 'executing', 'finishing' are
# overwhelmingly prose, not event names.
def looks_like_event(name):
    return "_" in name or name == "resumed"

unknown = sorted(
    ev for ev in emitted
    if ev not in enum and ev not in denylist and looks_like_event(ev)
)

if unknown:
    print("FAIL event names emitted in skill bodies but not in events.schema.json enum:")
    for ev in unknown:
        print(f"  - {ev}")
    print()
    print("Either add these to the schema's event enum, or remove the references.")
    sys.exit(1)
print(f"OK  all {len(emitted - denylist)} emit-shaped event names are in the schema enum")

# Soft warning: events in schema but never emitted in skills (dead enum space).
# This is a warning rather than a failure because the enum may legitimately
# precede emit-site implementation (e.g. lock_released emission planned but
# stage-skill update pending).
import subprocess
unused = []
search_roots = [os.path.join(plugin_root, d) for d in ("skills", "lib")]
for schema_event in enum:
    r = subprocess.run(
        ["grep", "-rqF", schema_event, *search_roots],
        capture_output=True,
    )
    if r.returncode != 0:
        unused.append(schema_event)

if unused:
    print("WARN events in schema enum with NO reference in skills/ (dead enum space):")
    for ev in sorted(unused):
        print(f"  - {ev}")

print("PASS")
PY
