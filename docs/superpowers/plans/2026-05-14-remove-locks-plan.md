# Remove Locks and Split-Session Mode Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Delete the per-ticket lock mechanism, fold `bugfix:resume-run` into `bugfix:run-ticket`, and drop `config.model_hints.stages` — under the assumption that a single long Claude session drives the loop end-to-end.

**Architecture:** Pure subtraction. State file remains the single source of truth. `bugfix:run-ticket` becomes the only driver: it parses the URL, initializes state atomically with `set -o noclobber`, then loops — reading state, checking terminal/blocked, scanning for the resume signal when blocked, dispatching the stage skill named by `current_stage` via the `Skill` tool, and watching for stalled progress / iteration cap. Stage skills no longer touch any lock file.

**Tech Stack:** Bash + `gh` + Python (for JSON manipulation in helpers) + Claude Code skill/hook system. JSON Schema validation via `jsonschema` (existing test dependency).

**Spec:** [docs/superpowers/specs/2026-05-14-remove-locks-design.md](../specs/2026-05-14-remove-locks-design.md)

---

## File Structure

**Files deleted outright:**
- `lib/lock-acquire.sh`
- `lib/lock-release.sh`
- `schemas/lock.schema.json`
- `skills/resume-run/SKILL.md` (folded into `run-ticket`)
- `tests/unit/test-lock-acquire.sh`
- `tests/unit/test-lock-release.sh`
- `tests/unit/test-lock-schema.sh`
- `tests/unit/test-resume-run-skill.sh`
- `tests/fixtures/lock-valid.json`
- `tests/fixtures/lock-invalid-no-pid.json`
- `tests/fixtures/config-invalid-stage-key.json`

**Files modified (schemas):**
- `schemas/events.schema.json` — remove `lock_acquired`, `lock_released`, `lock_stolen` from event enum
- `schemas/config.schema.json` — remove `model_hints.stages` subtree

**Files modified (skills):**
- `skills/run-ticket/SKILL.md` — rewrite driver loop, inline dispatch + resume-from-blocked detection + stage-to-skill table
- `skills/using-bugfix/SKILL.md` — drop `resume-run` bullet, rewrite "Front-door driver" bullet
- `skills/ticket-intake/SKILL.md` — drop step 3 (lock acquire) + lock-release line in "Next stage"
- `skills/writing-plans/SKILL.md` — drop step 3 (lock acquire) + "Lock first, side-effects second" paragraph + lock-release line in "Mandatory plan review"
- `skills/executing-plan/SKILL.md` — drop step 2 (lock acquire) + step 3 (lock release on completion)
- `skills/autonomous-finishing/SKILL.md` — drop step 2 (lock acquire) + "Release the lock" line in "Next stage"
- `skills/ci-watchdog/SKILL.md` — drop step 3 (lock acquire) + every "release lock" mention in polling-loop branches
- `skills/pr-final-review/SKILL.md` — drop step 3 (lock acquire) + "release lock" mentions across the three terminal branches
- `skills/block-and-comment/SKILL.md` — drop effect 5 ("Release the lock"); renumber; rewrite "Resume protocol (for reference)" to point at `bugfix:run-ticket`; drop "releases the lock" from frontmatter description

**Files modified (fixtures):**
- `tests/fixtures/events-valid.jsonl` — remove the `lock_acquired` JSONL line
- `tests/fixtures/config-valid.json` — remove `model_hints.stages` subtree

**Files modified (tests):**
- `tests/unit/test-events-schema.sh` — no source change needed (it just validates fixtures against schema; both move together)
- `tests/unit/test-config-schema.sh` — drop `config-invalid-stage-key.json` validation; drop the "stages enumerates all 6 stages" Python assertion
- `tests/unit/test-transition-graph.sh` — drop validations of `lock.schema.json`, `lib/lock-acquire.sh`, and `resume-run/SKILL.md` dispatch table; add validation of `run-ticket/SKILL.md` dispatch table
- `tests/unit/test-run-ticket-skill.sh` — drop the "resume-run referenced" assertion; add assertions for inlined dispatch table, stage-to-skill mapping, and resume-from-blocked detection
- `tests/unit/test-using-bugfix-skill.sh` — remove `resume-run` from the catalog-reference loop
- `tests/unit/test-block-and-comment-skill.sh` — drop "release the lock" assertion
- `tests/unit/test-ticket-intake-skill.sh` — drop Haiku-recommendation assertion that references `config.model_hints.stages.intake`; keep Haiku recommendation itself (still valid as informal guidance)
- `tests/unit/test-writing-plans-skill.sh` — drop "Lock first, side-effects second" assertion
- `tests/unit/test-ci-watchdog-skill.sh` — drop the `config.model_hints.stages.ci-watching` assertion
- `tests/unit/test-executing-plan-skill.sh` — no lock-specific assertion; pass-through

**Files modified (docs):**
- `README.md` — drop lock-related troubleshooting row; drop `<ticket-id>.lock` from runtime-tree diagram; rewrite "Try it" / "Resuming a blocked ticket" to remove `bugfix:resume-run` and "acquires the per-ticket lock"

The tasks are ordered so each is atomic (test + source change together where coupled) and the test suite passes after every task.

---

## Task 1: Remove lock events from `events.schema.json` + fixture

**Files:**
- Modify: `schemas/events.schema.json` — `properties.event.enum`
- Modify: `tests/fixtures/events-valid.jsonl` — remove the `lock_acquired` line
- Test: `tests/unit/test-events-schema.sh`, `tests/unit/test-event-name-agreement.sh`

- [ ] **Step 1: Remove the three lock events from the enum**

Open `schemas/events.schema.json`. Locate the `properties.event.enum` array. Delete the three string entries: `"lock_acquired"`, `"lock_released"`, `"lock_stolen"`.

Final enum:

```json
"event": {
  "type": "string",
  "enum": [
    "intake_started", "intake_passed", "intake_blocked",
    "worktree_created", "worktree_reused",
    "plan_reviewed", "plan_revised",
    "task_started", "task_spec_review_failed", "task_code_quality_review_failed", "task_done",
    "pr_pushed", "pr_opened",
    "ci_failed", "ci_green", "ci_fix_attempted",
    "pr_rebased", "pr_review_started", "pr_review_blocked", "pr_merge_ready", "pr_closed",
    "block_and_comment", "resumed"
  ]
},
```

- [ ] **Step 2: Remove the `lock_acquired` line from the valid-events fixture**

Open `tests/fixtures/events-valid.jsonl`. Delete the line:

```json
{"t":"2026-05-13T14:00:10Z","event":"lock_acquired","stage":"planning","detail":{"pid":12345}}
```

Leave all other lines intact.

- [ ] **Step 3: Run the events-schema test to verify both files agree**

Run: `bash tests/unit/test-events-schema.sh`
Expected: All four `validate_jsonl` checks pass, including the now-modified `events-valid.jsonl` validating as `valid`. Final line: `PASS`.

- [ ] **Step 4: Run the event-name-agreement test to verify no skill still references the deleted events**

Run: `bash tests/unit/test-event-name-agreement.sh`
Expected: `PASS`. No skill body emits `lock_acquired` / `lock_released` / `lock_stolen` by name, so the cross-check between schema enum and emit-references stays consistent. (The `lib/lock-acquire.sh` helper does reference these strings but the test only scans `skills/*/SKILL.md`, not `lib/`.) The "dead enum space" soft warning should also stay silent for these names since they're now absent from the enum.

- [ ] **Step 5: Commit**

```bash
git add schemas/events.schema.json tests/fixtures/events-valid.jsonl
git commit -m "Drop lock_acquired/lock_released/lock_stolen from events schema"
```

---

## Task 2: Remove `model_hints.stages` from `config.schema.json`

**Files:**
- Modify: `schemas/config.schema.json` — drop `model_hints.properties.stages` subtree
- Modify: `tests/fixtures/config-valid.json` — drop `model_hints.stages` key
- Delete: `tests/fixtures/config-invalid-stage-key.json`
- Modify: `tests/unit/test-config-schema.sh` — drop the `invalid-stage-key` fixture validation and the "stages enumerates all 6 stages" Python assertion

- [ ] **Step 1: Drop the `stages` property from the schema**

Open `schemas/config.schema.json`. Locate `properties.model_hints`. Replace the whole `model_hints` object with this shorter version that omits `stages` and tightens the description:

```json
"model_hints": {
  "type": "object",
  "additionalProperties": false,
  "description": "Host-agnostic model preferences for sub-agents the loop dispatches. Values are short class names ('haiku', 'sonnet', 'opus') that the host translates to concrete model IDs. The single-session driver (bugfix:run-ticket) inherits the session model for stages themselves; these keys configure sub-agent dispatch within the loop.",
  "properties": {
    "planner":     { "type": "string" },
    "implementer": { "type": "string" },
    "reviewer":    { "type": "string" },
    "adversary":   { "type": "string" }
  }
}
```

- [ ] **Step 2: Remove the `stages` block from the valid-config fixture**

Open `tests/fixtures/config-valid.json`. Inside `model_hints`, delete the `"stages": { ... }` key and its braces. Final `model_hints`:

```json
"model_hints": {
  "planner": "opus",
  "implementer": "sonnet",
  "reviewer": "opus",
  "adversary": "opus"
},
```

- [ ] **Step 3: Delete the invalid-stage-key fixture**

```bash
git rm tests/fixtures/config-invalid-stage-key.json
```

The fixture's sole purpose was to verify that `model_hints.stages` rejected stage names outside the canonical six. With the property gone, that test case is moot.

- [ ] **Step 4: Update the config-schema test**

Open `tests/unit/test-config-schema.sh`. Delete these two lines (the invalid-stage-key validation):

```bash
# model_hints.stages must reject keys outside the 6-stage enum.
validate "$FIXTURES/config-invalid-stage-key.json" invalid
```

Also delete the Python block that asserts `model_hints.stages` enumerates all 6 stages — the whole `python3 -c "..."` invocation plus its preceding comment and the `echo "OK  model_hints.stages enumerates all 6 stages"` line. The final test should contain only:

```bash
#!/usr/bin/env bash
set -euo pipefail
PLUGIN_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCHEMA="$PLUGIN_ROOT/schemas/config.schema.json"
FIXTURES="$PLUGIN_ROOT/tests/fixtures"

validate() {
  local fixture="$1"
  local expect="$2"
  python3 -c "
import json
from jsonschema import validate, ValidationError
schema = json.load(open('$SCHEMA'))
try:
    validate(json.load(open('$fixture')), schema)
    print('valid')
except ValidationError:
    print('invalid')
" | grep -q "^$expect$" || { echo "FAIL $fixture"; exit 1; }
  echo "OK  $fixture"
}

validate "$FIXTURES/config-valid.json" valid
validate "$FIXTURES/config-empty.json" valid

echo "PASS"
```

- [ ] **Step 5: Run the config-schema test**

Run: `bash tests/unit/test-config-schema.sh`
Expected: `OK  ...config-valid.json`, `OK  ...config-empty.json`, `PASS`.

- [ ] **Step 6: Commit**

```bash
git add schemas/config.schema.json tests/fixtures/config-valid.json tests/unit/test-config-schema.sh
git rm tests/fixtures/config-invalid-stage-key.json
git commit -m "Drop model_hints.stages from config schema"
```

---

## Task 3: Delete lock infrastructure and update transition-graph test

**Files:**
- Delete: `lib/lock-acquire.sh`, `lib/lock-release.sh`
- Delete: `schemas/lock.schema.json`
- Delete: `tests/unit/test-lock-acquire.sh`, `tests/unit/test-lock-release.sh`, `tests/unit/test-lock-schema.sh`
- Delete: `tests/fixtures/lock-valid.json`, `tests/fixtures/lock-invalid-no-pid.json`
- Modify: `tests/unit/test-transition-graph.sh` — drop lock-schema, lock-acquire, and resume-run dispatch-table extractors; keep state-schema and events-schema extractors

- [ ] **Step 1: Update transition-graph test to drop lock + resume-run references BEFORE deleting files**

Open `tests/unit/test-transition-graph.sh`. Replace the entire file with this version. Note: the run-ticket dispatch-table extractor is intentionally NOT added here — it gets added in Task 11 when `run-ticket` actually grows the table. For this task the test validates only the two surviving schemas.

```bash
#!/usr/bin/env bash
# Transition-graph lint.
#
# Verifies that the stage-machine transition graph is consistent across the
# 2 places it's currently duplicated:
#
# - run-state.schema.json:current_stage.enum (6 stages)
# - events.schema.json:stage.enum
#
# (Lock schema, lib/lock-acquire.sh, and resume-run's dispatch table were
# removed when the plugin dropped split-session mode; run-ticket's inlined
# dispatch table is the new single source of truth and is validated in the
# run-ticket-skill test, not here.)
set -euo pipefail
PLUGIN_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

# Expected canonical set (in alphabetical order for stable comparison).
EXPECTED="$(printf 'ci-watching\nexecuting\nfinishing\nintake\nplanning\npr-reviewing\n')"

extract_state_schema() {
  python3 -c "
import json
schema = json.load(open('$PLUGIN_ROOT/schemas/run-state.schema.json'))
print('\n'.join(sorted(schema['properties']['current_stage']['enum'])))
"
}

extract_events_schema() {
  python3 -c "
import json
schema = json.load(open('$PLUGIN_ROOT/schemas/events.schema.json'))
print('\n'.join(sorted(schema['properties']['stage']['enum'])))
"
}

compare() {
  local name="$1" actual="$2"
  if [[ "$actual" != "$EXPECTED" ]]; then
    echo "FAIL $name diverges from canonical stage set"
    echo "expected:"; echo "$EXPECTED" | sed 's/^/  /'
    echo "actual:";   echo "$actual"   | sed 's/^/  /'
    diff <(echo "$EXPECTED") <(echo "$actual") || true
    exit 1
  fi
  echo "OK  $name matches canonical stage set"
}

compare "run-state.schema.json"   "$(extract_state_schema)"
compare "events.schema.json"      "$(extract_events_schema)"

echo "PASS"
```

- [ ] **Step 2: Delete the lock helper scripts**

```bash
git rm lib/lock-acquire.sh lib/lock-release.sh
```

- [ ] **Step 3: Delete the lock schema**

```bash
git rm schemas/lock.schema.json
```

- [ ] **Step 4: Delete the lock tests and fixtures**

```bash
git rm tests/unit/test-lock-acquire.sh tests/unit/test-lock-release.sh tests/unit/test-lock-schema.sh
git rm tests/fixtures/lock-valid.json tests/fixtures/lock-invalid-no-pid.json
```

- [ ] **Step 5: Run the transition-graph test to verify the surviving extractors pass**

Run: `bash tests/unit/test-transition-graph.sh`
Expected: `OK  run-state.schema.json matches canonical stage set`, `OK  events.schema.json matches canonical stage set`, `PASS`.

- [ ] **Step 6: Run the full unit test suite to verify nothing else regressed**

Run: `bash tests/run-unit-tests.sh`
Expected: Some stage-skill tests will still fail (they still assert lock prose that the skills still contain — those fail in later tasks). But the schema/transition/events/config tests must all pass. If a previously-passing test now fails for an unrelated reason (e.g., missing fixture path), stop and investigate.

- [ ] **Step 7: Commit**

```bash
git add tests/unit/test-transition-graph.sh
git commit -m "Delete lock infrastructure and drop lock/resume-run from transition-graph test"
```

---

## Task 4: Drop lock-release from `block-and-comment` skill + test

**Files:**
- Modify: `skills/block-and-comment/SKILL.md` — drop effect 5 ("Release the lock"), renumber, rewrite Resume protocol prose, edit frontmatter description
- Test: `tests/unit/test-block-and-comment-skill.sh` — drop "release.*lock" assertion

- [ ] **Step 1: Update the test FIRST to assert absence**

Open `tests/unit/test-block-and-comment-skill.sh`. Delete these two lines (the lock-release assertion):

```bash
# Must mention the lock-release step (required by spec §6.1 effects list).
grep -qi "release.*lock\|lock-release" "$SKILL" || { echo "FAIL missing lock release instruction"; exit 1; }
echo "OK  lock release mentioned"
```

Replace them with an inverse assertion:

```bash
# Lock infrastructure was removed (single-session driver — no concurrency races to protect against).
if grep -qiE "release.*lock|lock-release" "$SKILL"; then
  echo "FAIL block-and-comment still references lock release after locks were removed"
  exit 1
fi
echo "OK  no lock-release references"
```

- [ ] **Step 2: Run the test to confirm it FAILS**

Run: `bash tests/unit/test-block-and-comment-skill.sh`
Expected: FAIL at the new "no lock-release references" check — the skill body still references `lock-release.sh`.

- [ ] **Step 3: Update the skill body**

Open `skills/block-and-comment/SKILL.md`. Make these edits:

**Edit 3a: Frontmatter description** — replace the line:

```
description: Use when an autonomous bugfix stage needs human input and cannot proceed - posts a structured ticket comment, persists state, releases the lock, and exits cleanly. The single pause point for the whole autonomous loop.
```

with:

```
description: Use when an autonomous bugfix stage needs human input and cannot proceed - posts a structured ticket comment, persists state, and exits cleanly. The single pause point for the whole autonomous loop.
```

**Edit 3b: Effects list** — delete the entire effect 5 block:

```
5. **Release the lock** at `.bugfix/runs/<ticket_id>.lock` via `bugfix/lib/lock-release.sh` (with the caller's `session_id` for ownership-checked release). The lock MUST be released even though state remains non-terminal - a blocked ticket is not actively being worked on.
6. **Return the sentinel `BLOCKED` to the caller.** The caller must exit cleanly without writing the next-stage marker.
```

Renumber so the `Return the sentinel BLOCKED` step becomes step 5:

```
5. **Return the sentinel `BLOCKED` to the caller.** The caller must exit cleanly without writing the next-stage marker.
```

**Edit 3c: Rewrite the "Resume protocol (for reference)" section** — replace:

```
## Resume protocol (for reference)

A human resumes the ticket by commenting `resume` on it (case-insensitive). `bugfix:resume-run` detects this and clears `blocked_reason` before re-dispatching the stored stage. Comments authored by bot accounts must be ignored when scanning for the `resume` token; only a non-bot author triggers resumption. The GitHub reference adapter is responsible for distinguishing bot vs human authors.
```

with:

```
## Resume protocol (for reference)

A human resumes the ticket by commenting `resume` on it (case-insensitive). The next `fix bug <url>` invocation re-enters `bugfix:run-ticket`, which detects the resume signal in the ticket comments and clears `blocked_reason` before re-dispatching the stored stage. Comments authored by bot accounts must be ignored when scanning for the `resume` token; only a non-bot author triggers resumption. The GitHub reference adapter is responsible for distinguishing bot vs human authors.
```

- [ ] **Step 4: Run the test to confirm it PASSES**

Run: `bash tests/unit/test-block-and-comment-skill.sh`
Expected: `OK  no lock-release references`, all other checks pass, `PASS`.

- [ ] **Step 5: Commit**

```bash
git add skills/block-and-comment/SKILL.md tests/unit/test-block-and-comment-skill.sh
git commit -m "Drop lock-release from block-and-comment skill"
```

---

## Task 5: Drop lock prose from `ticket-intake` skill

**Files:**
- Modify: `skills/ticket-intake/SKILL.md` — drop step 3 of State-file-first context, drop lock-release line in Next stage, drop split-session model-hint paragraph
- Test: `tests/unit/test-ticket-intake-skill.sh` — drop the `config.model_hints.stages.intake` assertion

- [ ] **Step 1: Update the test to drop the split-session model-hint assertion**

Open `tests/unit/test-ticket-intake-skill.sh`. Replace this block:

```bash
# Stage is mechanical enough for Haiku — recommendation must be documented
# so external schedulers can route via config.model_hints.stages.intake.
grep -qiF "Recommended model: Haiku" "$SKILL" || { echo "FAIL ticket-intake must recommend Haiku class"; exit 1; }
grep -qF "config.model_hints.stages.intake" "$SKILL" || { echo "FAIL ticket-intake must reference the stage model-hint config key"; exit 1; }
echo "OK  Haiku recommendation + model-hint config key documented"
```

with this (Haiku recommendation stays as informal guidance; `config.model_hints.stages.intake` assertion is gone because the config key no longer exists):

```bash
# Stage is mechanical enough for Haiku — informal recommendation stays as guidance
# for the single-session driver to consider its costs.
grep -qiF "Recommended model: Haiku" "$SKILL" || { echo "FAIL ticket-intake must recommend Haiku class"; exit 1; }
echo "OK  Haiku recommendation documented"

# Lock infrastructure was removed (single-session driver — no concurrency races).
if grep -qiE "lock-acquire|lock-release|\.lock" "$SKILL"; then
  echo "FAIL ticket-intake still references lock infrastructure after locks were removed"
  exit 1
fi
echo "OK  no lock-infrastructure references"
```

- [ ] **Step 2: Run the test to confirm it FAILS**

Run: `bash tests/unit/test-ticket-intake-skill.sh`
Expected: FAIL at the "no lock-infrastructure references" check.

- [ ] **Step 3: Update the skill body**

Open `skills/ticket-intake/SKILL.md`. Make these edits:

**Edit 3a: State-file-first context** — replace this block:

```
1. Read `.bugfix/runs/<ticket_id>.json`. Confirm `current_stage == "intake"`. If not, exit with an error (resume-run should not have dispatched).
2. Read `state.owner`, `state.repo`, `state.issue_number`. These were initialized by `run-ticket` from the URL parse.
3. Acquire the lock via `bugfix/lib/lock-acquire.sh ".bugfix/runs/<ticket_id>.lock" "<session_id>" "intake"`. If acquire fails (exit 1 = live holder, exit 3 = I/O failure), exit cleanly — resume-run will retry.
```

with:

```
1. Read `.bugfix/runs/<ticket_id>.json`. Confirm `current_stage == "intake"`. If not, exit with an error (the driver should not have dispatched).
2. Read `state.owner`, `state.repo`, `state.issue_number`. These were initialized by `run-ticket` from the URL parse.
```

**Edit 3b: Recommended model paragraph** — replace the whole paragraph that begins "**Recommended model: Haiku.**". Replace:

```
**Recommended model: Haiku.** This stage is mechanical text manipulation — read the ticket body, classify against a fixed trichotomy (bug | improvement | not-actionable), extract structured repro/expected/actual fields, write the spec. No multi-file design judgment, no codebase exploration. A host driving this stage via `bugfix:resume-run` from external scheduling SHOULD honor `config.model_hints.stages.intake` (default: `"haiku"`). In-session hosts (`bugfix:run-ticket` long-running loop) inherit the session model; if that model is heavier than Haiku, the stage still works but at higher cost than necessary.
```

with:

```
**Recommended model: Haiku.** This stage is mechanical text manipulation — read the ticket body, classify against a fixed trichotomy (bug | improvement | not-actionable), extract structured repro/expected/actual fields, write the spec. No multi-file design judgment, no codebase exploration. The single-session `bugfix:run-ticket` driver inherits the session model; if that model is heavier than Haiku, the stage still works but at higher cost than necessary.
```

**Edit 3c: Block-and-comment exits final line** — replace:

```
After block-and-comment runs, do NOT advance `current_stage`. Release the lock and exit.
```

with:

```
After block-and-comment runs, do NOT advance `current_stage`. Exit.
```

**Edit 3d: Next stage section** — replace:

```
On success: write `state.current_stage = "planning"`, release the lock via `bugfix/lib/lock-release.sh`, exit. `resume-run` will dispatch `bugfix:writing-plans` on its next invocation.
```

with:

```
On success: write `state.current_stage = "planning"`, exit. `bugfix:run-ticket` will dispatch `bugfix:writing-plans` on its next loop iteration.
```

**Edit 3e: Frontmatter description** — replace:

```
description: Use as the first stage of the autonomous bug-fix loop. Reads the GitHub issue via `bugfix:ticket-adapter`, classifies as bug/improvement/not-actionable, extracts repro/expected/actual for bugs, writes a spec file, sets the ticket status to in-progress, and advances state to planning. Dispatched by `bugfix:resume-run` when `state.current_stage == "intake"`.
```

with:

```
description: Use as the first stage of the autonomous bug-fix loop. Reads the GitHub issue via `bugfix:ticket-adapter`, classifies as bug/improvement/not-actionable, extracts repro/expected/actual for bugs, writes a spec file, sets the ticket status to in-progress, and advances state to planning. Dispatched by `bugfix:run-ticket` when `state.current_stage == "intake"`.
```

- [ ] **Step 4: Run the test to confirm it PASSES**

Run: `bash tests/unit/test-ticket-intake-skill.sh`
Expected: `PASS`.

- [ ] **Step 5: Commit**

```bash
git add skills/ticket-intake/SKILL.md tests/unit/test-ticket-intake-skill.sh
git commit -m "Drop lock prose from ticket-intake skill"
```

---

## Task 6: Drop lock prose from `writing-plans` skill

**Files:**
- Modify: `skills/writing-plans/SKILL.md`
- Test: `tests/unit/test-writing-plans-skill.sh` — drop "Lock first, side-effects second" assertion

- [ ] **Step 1: Update the test**

Open `tests/unit/test-writing-plans-skill.sh`. Delete these two lines:

```bash
# C6: lock acquisition must precede side-effects.
grep -qiF "Lock first, side-effects second" "$SKILL" || { echo "FAIL writing-plans must enforce lock-first-side-effects-second ordering"; exit 1; }
echo "OK  lock-first-side-effects-second ordering documented"
```

Add an inverse assertion in their place:

```bash
# Lock infrastructure was removed (single-session driver — no concurrency races).
if grep -qiE "lock-acquire|lock-release|\.lock\b" "$SKILL"; then
  echo "FAIL writing-plans still references lock infrastructure"
  exit 1
fi
echo "OK  no lock-infrastructure references"
```

- [ ] **Step 2: Run the test to confirm it FAILS**

Run: `bash tests/unit/test-writing-plans-skill.sh`
Expected: FAIL at the "no lock-infrastructure references" check.

- [ ] **Step 3: Update the skill body**

Open `skills/writing-plans/SKILL.md`. Make these edits:

**Edit 3a: State-file-first context steps 1–6** — replace the entire numbered list (from `1. Read...` through `6. After plan review passes...`) with:

```
1. Read `.bugfix/runs/<ticket-id>.json` and confirm `current_stage == "planning"`. If not, exit with an error (the driver should not have dispatched).
2. Read the spec at `state.spec_path` — that's the input.
3. **Detect whether cwd is already in an isolated worktree.** Run:

   ```bash
   git_dir="$(git rev-parse --git-dir 2>/dev/null || echo "")"
   case "$git_dir" in
     *.git/worktrees/*|*/worktrees/*)
       in_worktree=true ;;
     *)
       in_worktree=false ;;
   esac
   ```

   - **If `in_worktree=true`:** the operator (or a parent harness) already spawned the loop inside an isolated worktree. Do NOT create a sibling `.worktrees/<ticket-id>/`. Record the current location as the ticket's worktree:
     - `state.worktree_path = "$(pwd)"` (absolute).
     - `state.branch = "$(git symbolic-ref --short HEAD)"`.
     - `state.base_sha = "$(git merge-base HEAD "origin/$state.base_branch" 2>/dev/null || git rev-parse HEAD)"` (commit we branched off; falls back to HEAD if no merge base exists, which would be unusual).
     - Verify the test baseline is clean (`git status --porcelain` empty). If dirty, exit via `bugfix:block-and-comment(tech-failure, reason="ticket worktree is not clean — cannot start planning with uncommitted changes")`.
     - Emit `worktree_reused` event (detail: `{"path": "<state.worktree_path>", "branch": "<state.branch>"}`).
   - **If `in_worktree=false`:** inline-invoke `bugfix:using-git-worktrees` to create `.worktrees/<ticket-id>` from `state.base_branch`, verify clean test baseline. Record `state.worktree_path`, `state.branch`, and `state.base_sha`. Emit `worktree_created` event.

4. Continue with planning (per the body below). **Save the plan to `.bugfix/plans/<ticket-id>.md`** — the bugfix runtime keeps operational data under `.bugfix/`, NOT under `docs/superpowers/plans/` (that path is for upstream feature workflows). The upstream "Save plans to:" guidance later in this skill body is overridden by this rule for bug-fix runs.
5. After plan review passes (see "Mandatory plan review" section below), set `state.plan_path = ".bugfix/plans/<ticket-id>.md"` and `state.current_stage = "executing"`, emit `plan_reviewed` event, exit.
```

(Note the renumbering: the old step 4 becomes step 3, old step 5 becomes step 4, old step 6 becomes step 5.)

**Edit 3b: Frontmatter description** — the frontmatter `description` line on this skill is unchanged from upstream and doesn't mention locks; no edit needed.

**Edit 3c: Mandatory plan review final block** — find the section that begins `After "Plan compliant":` and replace:

```
After "Plan compliant":
- Set `state.plan_path = ".bugfix/plans/<ticket-id>.md"`.
- Emit `plan_reviewed` event via `bugfix/lib/events-append.sh`.
- Set `state.current_stage = "executing"`.
- Release the lock.
- Exit.
```

with:

```
After "Plan compliant":
- Set `state.plan_path = ".bugfix/plans/<ticket-id>.md"`.
- Emit `plan_reviewed` event via `bugfix/lib/events-append.sh`.
- Set `state.current_stage = "executing"`.
- Exit.
```

**Edit 3d: State writes preamble** — find the line:

```
Inside the locked region:
```

and replace it with:

```
Inside the planning stage:
```

- [ ] **Step 4: Run the test to confirm it PASSES**

Run: `bash tests/unit/test-writing-plans-skill.sh`
Expected: `PASS`.

- [ ] **Step 5: Commit**

```bash
git add skills/writing-plans/SKILL.md tests/unit/test-writing-plans-skill.sh
git commit -m "Drop lock prose from writing-plans skill"
```

---

## Task 7: Drop lock prose from `executing-plan` skill

**Files:**
- Modify: `skills/executing-plan/SKILL.md`
- Test: `tests/unit/test-executing-plan-skill.sh`

- [ ] **Step 1: Update the test to assert absence of lock references**

Open `tests/unit/test-executing-plan-skill.sh`. Add this block right before the final `echo "PASS"` line:

```bash
# Lock infrastructure was removed (single-session driver — no concurrency races).
if grep -qiE "lock-acquire|lock-release|\.lock\b" "$SKILL"; then
  echo "FAIL executing-plan still references lock infrastructure"
  exit 1
fi
echo "OK  no lock-infrastructure references"
```

- [ ] **Step 2: Run the test to confirm it FAILS**

Run: `bash tests/unit/test-executing-plan-skill.sh`
Expected: FAIL at the "no lock-infrastructure references" check.

- [ ] **Step 3: Update the skill body**

Open `skills/executing-plan/SKILL.md`. Make these edits:

**Edit 3a: State-file-first context** — replace:

```
1. Read `.bugfix/runs/<ticket-id>.json` and confirm `current_stage == "executing"`. If not, exit with an error.
2. Acquire the lock via `bugfix/lib/lock-acquire.sh ".bugfix/runs/<ticket-id>.lock" "<session_id>" "executing"`.
3. cd into the worktree at `state.worktree_path` (created by `writing-plans` in the prior stage).
4. Read the plan at `state.plan_path` once and extract all tasks into working memory (per the upstream skill's pattern below).
5. Run the per-task loop (see body below) following the modifications in this skill that extend the upstream subagent-driven-development pattern.
6. After every task completes review-clean: set `state.current_stage = "finishing"`, release the lock, exit.
```

with:

```
1. Read `.bugfix/runs/<ticket-id>.json` and confirm `current_stage == "executing"`. If not, exit with an error.
2. cd into the worktree at `state.worktree_path` (created by `writing-plans` in the prior stage).
3. Read the plan at `state.plan_path` once and extract all tasks into working memory (per the upstream skill's pattern below).
4. Run the per-task loop (see body below) following the modifications in this skill that extend the upstream subagent-driven-development pattern.
5. After every task completes review-clean: set `state.current_stage = "finishing"`, exit.
```

**Edit 3b: State advance on completion** — replace:

```
1. Read `.bugfix/runs/<ticket-id>.json`, set `state.current_stage = "finishing"`, set `state.updated_at = <now>`, write back.
2. Emit `task_done` for the last task (with detail `{"task_number": N}`) via `bugfix/lib/events-append.sh`. Do NOT emit any finishing-stage events here — `autonomous-finishing` owns those.
3. Release the lock via `bugfix/lib/lock-release.sh`.
4. Exit cleanly. `bugfix:resume-run` will dispatch `bugfix:autonomous-finishing` on its next invocation.
```

with:

```
1. Read `.bugfix/runs/<ticket-id>.json`, set `state.current_stage = "finishing"`, set `state.updated_at = <now>`, write back.
2. Emit `task_done` for the last task (with detail `{"task_number": N}`) via `bugfix/lib/events-append.sh`. Do NOT emit any finishing-stage events here — `autonomous-finishing` owns those.
3. Exit cleanly. `bugfix:run-ticket` will dispatch `bugfix:autonomous-finishing` on its next loop iteration.
```

**Edit 3c: Frontmatter description** — `description` line on this skill is unchanged from upstream; no edit needed. (It says "Use when executing implementation plans with independent tasks in the current session" — already lock-agnostic.)

- [ ] **Step 4: Run the test to confirm it PASSES**

Run: `bash tests/unit/test-executing-plan-skill.sh`
Expected: `PASS`.

- [ ] **Step 5: Commit**

```bash
git add skills/executing-plan/SKILL.md tests/unit/test-executing-plan-skill.sh
git commit -m "Drop lock prose from executing-plan skill"
```

---

## Task 8: Drop lock prose from `autonomous-finishing` skill

**Files:**
- Modify: `skills/autonomous-finishing/SKILL.md`
- Test: `tests/unit/test-autonomous-finishing-skill.sh`

- [ ] **Step 1: Update the test**

Open `tests/unit/test-autonomous-finishing-skill.sh`. Add right before the final `echo "PASS"`:

```bash
# Lock infrastructure was removed.
if grep -qiE "lock-acquire|lock-release|\.lock\b" "$SKILL"; then
  echo "FAIL autonomous-finishing still references lock infrastructure"
  exit 1
fi
echo "OK  no lock-infrastructure references"
```

- [ ] **Step 2: Run the test to confirm it FAILS**

Run: `bash tests/unit/test-autonomous-finishing-skill.sh`
Expected: FAIL at the "no lock-infrastructure references" check.

- [ ] **Step 3: Update the skill body**

Open `skills/autonomous-finishing/SKILL.md`. Make these edits:

**Edit 3a: State-file-first context** — replace:

```
1. Read `.bugfix/runs/<ticket-id>.json`. Confirm `current_stage == "finishing"`. If not, exit with an error.
2. Acquire the lock via `bugfix/lib/lock-acquire.sh ".bugfix/runs/<ticket-id>.lock" "<session_id>" "finishing"`.
3. cd into `state.worktree_path`. All operations from here run inside the worktree.
```

with:

```
1. Read `.bugfix/runs/<ticket-id>.json`. Confirm `current_stage == "finishing"`. If not, exit with an error.
2. cd into `state.worktree_path`. All operations from here run inside the worktree.
```

**Edit 3b: Next stage** — replace:

```
On success: write `state.current_stage = "ci-watching"`, release the lock, exit. `resume-run` dispatches `bugfix:ci-watchdog`, which long-polls CI on the new PR via `ticket-adapter:ci_watch` and either advances to `pr-reviewing` on green, fixes failures (bounded retries), or blocks on timeout.
```

with:

```
On success: write `state.current_stage = "ci-watching"`, exit. `bugfix:run-ticket` dispatches `bugfix:ci-watchdog`, which long-polls CI on the new PR via `ticket-adapter:ci_watch` and either advances to `pr-reviewing` on green, fixes failures (bounded retries), or blocks on timeout.
```

**Edit 3c: Frontmatter description** — replace:

```
description: Use as the post-execution stage of the autonomous bug-fix loop. Verifies local tests pass, pushes the branch, opens a PR via `bugfix:ticket-adapter`, comments the ticket with the PR link, and advances state to ci-watching. Dispatched by `bugfix:resume-run` when `state.current_stage == "finishing"`.
```

with:

```
description: Use as the post-execution stage of the autonomous bug-fix loop. Verifies local tests pass, pushes the branch, opens a PR via `bugfix:ticket-adapter`, comments the ticket with the PR link, and advances state to ci-watching. Dispatched by `bugfix:run-ticket` when `state.current_stage == "finishing"`.
```

- [ ] **Step 4: Run the test to confirm it PASSES**

Run: `bash tests/unit/test-autonomous-finishing-skill.sh`
Expected: `PASS`.

- [ ] **Step 5: Commit**

```bash
git add skills/autonomous-finishing/SKILL.md tests/unit/test-autonomous-finishing-skill.sh
git commit -m "Drop lock prose from autonomous-finishing skill"
```

---

## Task 9: Drop lock prose from `ci-watchdog` skill

**Files:**
- Modify: `skills/ci-watchdog/SKILL.md`
- Test: `tests/unit/test-ci-watchdog-skill.sh` — drop `config.model_hints.stages.ci-watching` assertion

- [ ] **Step 1: Update the test**

Open `tests/unit/test-ci-watchdog-skill.sh`. Replace this block:

```bash
# ci-watchdog controller is mechanical enough for Haiku, but the fix sub-agent
# it dispatches is NOT Haiku — it does real implementation work. Both must be
# documented so a host that splits sessions per stage routes correctly.
grep -qiF "Recommended model: Haiku" "$SKILL" || { echo "FAIL ci-watchdog must recommend Haiku class for the controller"; exit 1; }
grep -qF "config.model_hints.stages.ci-watching" "$SKILL" || { echo "FAIL ci-watchdog must reference the stage model-hint config key"; exit 1; }
grep -qiE "fix sub-agent.*implementer|implementer.*fix sub-agent" "$SKILL" \
  || { echo "FAIL ci-watchdog must clarify that the fix sub-agent runs at implementer tier (NOT haiku)"; exit 1; }
echo "OK  Haiku recommendation for controller + implementer tier for fix sub-agent documented"
```

with:

```bash
# ci-watchdog controller is mechanical enough for Haiku (informal recommendation
# for cost-tuning when the single-session driver runs); the fix sub-agent it
# dispatches is NOT Haiku — it does real implementation work.
grep -qiF "Recommended model: Haiku" "$SKILL" || { echo "FAIL ci-watchdog must recommend Haiku class for the controller"; exit 1; }
grep -qiE "fix sub-agent.*implementer|implementer.*fix sub-agent" "$SKILL" \
  || { echo "FAIL ci-watchdog must clarify that the fix sub-agent runs at implementer tier (NOT haiku)"; exit 1; }
echo "OK  Haiku recommendation for controller + implementer tier for fix sub-agent documented"

# Lock infrastructure was removed.
if grep -qiE "lock-acquire|lock-release|\.lock\b" "$SKILL"; then
  echo "FAIL ci-watchdog still references lock infrastructure"
  exit 1
fi
echo "OK  no lock-infrastructure references"
```

- [ ] **Step 2: Run the test to confirm it FAILS**

Run: `bash tests/unit/test-ci-watchdog-skill.sh`
Expected: FAIL at the "no lock-infrastructure references" check (and the `config.model_hints.stages.ci-watching` assertion that was removed is gone, which is fine since the skill still mentions it currently — let me re-check). Actually: the OLD test required that assertion; we removed it. The skill body still mentions `config.model_hints.stages.ci-watching` — that's fine because removing the assertion doesn't require removing the prose, but the skill edit below also removes that prose.

- [ ] **Step 3: Update the skill body**

Open `skills/ci-watchdog/SKILL.md`. Make these edits:

**Edit 3a: Recommended-model paragraph** — replace:

```
**Recommended model: Haiku for the watchdog controller itself.** The controller's work is mechanical: snapshot CI, call `ci_watch` if pending, classify the result, dispatch a fix sub-agent on failure. A host driving this stage via `bugfix:resume-run` from external scheduling SHOULD honor `config.model_hints.stages.ci-watching` (default: `"haiku"`). **The fix sub-agent dispatched on CI failure is a separate concern** — that sub-agent does real implementation work and should run at implementer-class (the same model the executing-plan implementer would use). The watchdog body explicitly passes `model_hint = config.model_hints.implementer` (default: the host's implementer tier) when constructing the fix-sub-agent dispatch.
```

with:

```
**Recommended model: Haiku for the watchdog controller itself.** The controller's work is mechanical: snapshot CI, call `ci_watch` if pending, classify the result, dispatch a fix sub-agent on failure. The single-session `bugfix:run-ticket` driver inherits the session model, so this recommendation is informational — useful when the host can choose to spawn a cheaper model. **The fix sub-agent dispatched on CI failure is a separate concern** — that sub-agent does real implementation work and should run at implementer-class (the same model the executing-plan implementer would use). The watchdog body explicitly passes `model_hint = config.model_hints.implementer` (default: the host's implementer tier) when constructing the fix-sub-agent dispatch.
```

**Edit 3b: State-file-first context** — replace:

```
1. Read `.bugfix/runs/<ticket-id>.json`. Confirm `current_stage == "ci-watching"`. If not, exit with an error.
2. Confirm `state.pr_number != null` (set by `autonomous-finishing`). If null, exit via `bugfix:block-and-comment(tech-failure, reason="ci-watchdog dispatched with no pr_number — autonomous-finishing should have set it")`.
3. Acquire the lock via `bugfix/lib/lock-acquire.sh ".bugfix/runs/<ticket-id>.lock" "<session_id>" "ci-watching"`. If acquire fails, exit cleanly — resume-run will retry.
4. cd into `state.worktree_path`. All fix-related git operations run inside the worktree.
```

with:

```
1. Read `.bugfix/runs/<ticket-id>.json`. Confirm `current_stage == "ci-watching"`. If not, exit with an error.
2. Confirm `state.pr_number != null` (set by `autonomous-finishing`). If null, exit via `bugfix:block-and-comment(tech-failure, reason="ci-watchdog dispatched with no pr_number — autonomous-finishing should have set it")`.
3. cd into `state.worktree_path`. All fix-related git operations run inside the worktree.
```

**Edit 3c: Polling loop pseudo-code — remove every `release lock` line.** Find each line in the pseudo-code that reads `release lock; exit` and replace with `exit`. There are 5 occurrences in the `while True:` block. Final lines:
- `block-and-comment(...); release lock; exit` → `block-and-comment(...); exit`
- `release lock; exit` → `exit`

After this edit, the algorithm reads identically except for the missing lock-release calls.

**Edit 3d: State writes section** — replace:

```
Each write is a read-modify-write of `.bugfix/runs/<ticket-id>.json`. Holding the file mutable across the entire loop would let two concurrent writers from different runs (shouldn't happen given the lock, but defensive) collide.
```

with:

```
Each write is a read-modify-write of `.bugfix/runs/<ticket-id>.json`. The single-session driver runs one stage at a time per ticket, so concurrent writers are not expected; the read-modify-write discipline is still good practice for survivability across crashes.
```

**Edit 3e: Block-and-comment exits closing paragraph** — replace:

```
After block-and-comment, do NOT advance `current_stage`. Release the lock and exit.
```

with:

```
After block-and-comment, do NOT advance `current_stage`. Exit.
```

**Edit 3f: Next stage** — replace:

```
On `ci_green`: write `state.current_stage = "pr-reviewing"`, release the lock, exit. `resume-run` then dispatches `bugfix:pr-final-review`.
```

with:

```
On `ci_green`: write `state.current_stage = "pr-reviewing"`, exit. `bugfix:run-ticket` then dispatches `bugfix:pr-final-review`.
```

**Edit 3g: Frontmatter description** — replace the trailing `Dispatched by ...` clause:

```
description: Use as the post-PR-opened stage of the autonomous bug-fix loop. Waits for CI on the open PR via `bugfix:ticket-adapter:ci_watch`, dispatches a fix sub-agent on failure (bounded retries), advances state to pr-reviewing on success. Dispatched by `bugfix:resume-run` when `state.current_stage == "ci-watching"`.
```

with:

```
description: Use as the post-PR-opened stage of the autonomous bug-fix loop. Waits for CI on the open PR via `bugfix:ticket-adapter:ci_watch`, dispatches a fix sub-agent on failure (bounded retries), advances state to pr-reviewing on success. Dispatched by `bugfix:run-ticket` when `state.current_stage == "ci-watching"`.
```

**Edit 3h: Alternative section** — the "Alternative: schedule-and-resume" section at the bottom of the file references `resume-run` and the split-session host model. Replace the whole section (from `## Alternative: schedule-and-resume` to end of file) with:

```
## Alternative: schedule-and-resume

The single-session driver runs `ci_watch` synchronously until terminal verdict or 120-minute timeout. A future enhancement could let the driver release the ticket between snapshots (writing `state.next_poll_at` and exiting), with an external scheduler re-invoking `bugfix:run-ticket` later — but the current single-session model holds the watcher open for the full duration. The `state.next_poll_at` field is not in v1.
```

- [ ] **Step 4: Run the test to confirm it PASSES**

Run: `bash tests/unit/test-ci-watchdog-skill.sh`
Expected: `PASS`.

- [ ] **Step 5: Commit**

```bash
git add skills/ci-watchdog/SKILL.md tests/unit/test-ci-watchdog-skill.sh
git commit -m "Drop lock prose from ci-watchdog skill"
```

---

## Task 10: Drop lock prose from `pr-final-review` skill

**Files:**
- Modify: `skills/pr-final-review/SKILL.md`
- Test: `tests/unit/test-pr-final-review-skill.sh`

- [ ] **Step 1: Update the test**

Open `tests/unit/test-pr-final-review-skill.sh`. Add right before the final `echo "PASS"`:

```bash
# Lock infrastructure was removed.
if grep -qiE "lock-acquire|lock-release|\.lock\b" "$SKILL"; then
  echo "FAIL pr-final-review still references lock infrastructure"
  exit 1
fi
echo "OK  no lock-infrastructure references"
```

- [ ] **Step 2: Run the test to confirm it FAILS**

Run: `bash tests/unit/test-pr-final-review-skill.sh`
Expected: FAIL at the "no lock-infrastructure references" check.

- [ ] **Step 3: Update the skill body**

Open `skills/pr-final-review/SKILL.md`. Make these edits:

**Edit 3a: State-file-first context** — replace:

```
1. Read `.bugfix/runs/<ticket-id>.json`. Confirm `current_stage == "pr-reviewing"`. If not, exit with an error.
2. Confirm `state.pr_number != null` and `state.base_branch != null` and `state.base_sha != null`. If any is null, exit via `bugfix:block-and-comment(tech-failure, reason="pr-final-review dispatched with missing state fields — upstream stage didn't initialize them")`.
3. Acquire the lock via `bugfix/lib/lock-acquire.sh ".bugfix/runs/<ticket-id>.lock" "<session_id>" "pr-reviewing"`. If acquire fails, exit cleanly — resume-run will retry.
4. cd into `state.worktree_path`. All git operations run inside the worktree.
```

with:

```
1. Read `.bugfix/runs/<ticket-id>.json`. Confirm `current_stage == "pr-reviewing"`. If not, exit with an error.
2. Confirm `state.pr_number != null` and `state.base_branch != null` and `state.base_sha != null`. If any is null, exit via `bugfix:block-and-comment(tech-failure, reason="pr-final-review dispatched with missing state fields — upstream stage didn't initialize them")`.
3. cd into `state.worktree_path`. All git operations run inside the worktree.
```

**Edit 3b: Branch A (merge-ready) step 10** — replace:

```
10. Release lock; exit.
```

with:

```
10. Exit.
```

**Edit 3c: Branch C (block) — `block-and-comment` already handled the lock release historically; now it doesn't need to.** The Branch C section says:

```
4. Invoke `bugfix:block-and-comment(needs-info, reason=<short>, questions=[<both verdicts, formatted>], artifacts=[{label: "advocate_verdict", path: "(inline)"}, {label: "adversary_verdict", path: "(inline)"}])`.
   - `block-and-comment` handles the ticket comment, status set to `needs-info`, lock release.
```

Replace with:

```
4. Invoke `bugfix:block-and-comment(needs-info, reason=<short>, questions=[<both verdicts, formatted>], artifacts=[{label: "advocate_verdict", path: "(inline)"}, {label: "adversary_verdict", path: "(inline)"}])`.
   - `block-and-comment` handles the ticket comment and status set to `needs-info`.
```

**Edit 3d: Branch B step 6 sub-bullet** — replace:

```
   - `block-and-comment` will:
     - Persist `state.blocked_reason` etc.
     - Call `ticket_comment` with its template (which references the adversary's critical findings).
     - Call `set_status(state.issue_number, "rejected")`.
     - Emit `block_and_comment` event.
     - Release the lock.
```

with:

```
   - `block-and-comment` will:
     - Persist `state.blocked_reason` etc.
     - Call `ticket_comment` with its template (which references the adversary's critical findings).
     - Call `set_status(state.issue_number, "rejected")`.
     - Emit `block_and_comment` event.
```

**Edit 3e: Next stage** — replace:

```
None. `pr-final-review` is the terminal stage. After this skill exits, `state.terminal` is set (or `state.blocked_reason` is set on a block). `bugfix:run-ticket`'s driver loop checks for either and exits cleanly.
```

with:

```
None. `pr-final-review` is the terminal stage. After this skill exits, `state.terminal` is set (or `state.blocked_reason` is set on a block). `bugfix:run-ticket`'s driver loop reads the state file on its next iteration, sees the terminal/blocked field, and exits cleanly.
```

**Edit 3f: Frontmatter description** — replace:

```
description: Use as the terminal stage of the autonomous bug-fix loop. Rebases the PR on top of base_branch, dispatches advocate + adversary reviewers in parallel, applies the decision rule, terminates the loop as merge-ready, pr-closed, or blocks for human resolution. Dispatched by `bugfix:resume-run` when `state.current_stage == "pr-reviewing"`.
```

with:

```
description: Use as the terminal stage of the autonomous bug-fix loop. Rebases the PR on top of base_branch, dispatches advocate + adversary reviewers in parallel, applies the decision rule, terminates the loop as merge-ready, pr-closed, or blocks for human resolution. Dispatched by `bugfix:run-ticket` when `state.current_stage == "pr-reviewing"`.
```

- [ ] **Step 4: Run the test to confirm it PASSES**

Run: `bash tests/unit/test-pr-final-review-skill.sh`
Expected: `PASS`.

- [ ] **Step 5: Commit**

```bash
git add skills/pr-final-review/SKILL.md tests/unit/test-pr-final-review-skill.sh
git commit -m "Drop lock prose from pr-final-review skill"
```

---

## Task 11: Rewrite `run-ticket` skill to inline dispatch and resume-from-blocked, update its test, extend transition-graph test

**Files:**
- Modify: `skills/run-ticket/SKILL.md` — rewrite driver loop + add stage-to-skill table + add resume-from-blocked detection + add stage-not-implemented handler
- Modify: `tests/unit/test-run-ticket-skill.sh` — drop `resume-run` reference assertion; add assertions for the new inlined content
- Modify: `tests/unit/test-transition-graph.sh` — add a `run-ticket/SKILL.md` dispatch-table extractor and compare it to the canonical stage set

- [ ] **Step 1: Update the run-ticket test to assert the new structure**

Open `tests/unit/test-run-ticket-skill.sh`. Replace this block:

```bash
# Body must reference resume-run loop.
grep -qF "resume-run" "$SKILL" || { echo "FAIL body missing resume-run reference"; exit 1; }
echo "OK  resume-run loop referenced"
```

with assertions for the inlined logic:

```bash
# Body must contain the inlined stage-to-skill dispatch table (since resume-run was folded in).
grep -qF "## Stage-to-skill mapping" "$SKILL" || { echo "FAIL body missing stage-to-skill mapping header"; exit 1; }
for stage in intake planning executing finishing ci-watching pr-reviewing; do
  grep -qF "\`$stage\`" "$SKILL" || { echo "FAIL stage mapping missing: $stage"; exit 1; }
done
echo "OK  stage-to-skill mapping inlined with all 6 stages"

# Body must contain resume-from-blocked detection (moved from resume-run).
grep -qF "## Resume-from-blocked detection" "$SKILL" || { echo "FAIL body missing resume-from-blocked section"; exit 1; }
grep -qF "is_bot" "$SKILL" || { echo "FAIL body missing bot-filter rule for resume detection"; exit 1; }
echo "OK  resume-from-blocked detection inlined"

# Body must contain stage-not-implemented terminal handling (moved from resume-run).
grep -qF "stage-not-implemented" "$SKILL" || { echo "FAIL body missing stage-not-implemented terminal handling"; exit 1; }
echo "OK  stage-not-implemented handling inlined"

# Body must NOT reference the deleted resume-run skill or its old indirection.
if grep -qF "bugfix:resume-run" "$SKILL"; then
  echo "FAIL body still references deleted bugfix:resume-run"
  exit 1
fi
echo "OK  no references to deleted bugfix:resume-run"

# Body must NOT reference lock infrastructure.
if grep -qiE "lock-acquire|lock-release|\.lock\b" "$SKILL"; then
  echo "FAIL body still references lock infrastructure"
  exit 1
fi
echo "OK  no lock-infrastructure references"
```

- [ ] **Step 2: Update the transition-graph test to add the run-ticket extractor**

Open `tests/unit/test-transition-graph.sh`. After the `extract_events_schema` function definition, add:

```bash
extract_run_ticket_table() {
  # The dispatch table has lines like "| `<stage>` | `skills/.../SKILL.md` |".
  grep -E '^\| `[a-z-]+` \| `skills/' "$PLUGIN_ROOT/skills/run-ticket/SKILL.md" \
    | sed -E 's/^\| `([a-z-]+)` .*/\1/' | sort
}
```

After the `compare "events.schema.json"` line, add:

```bash
compare "run-ticket/SKILL.md"     "$(extract_run_ticket_table)"
```

Also add this Python block at the bottom (right before `echo "PASS"`) to verify each mapped skill file exists (mirrors the deleted resume-run-side check):

```bash
# Verify that for each stage in run-ticket's table, the mapped skill file exists.
python3 <<PY
import re, os
plugin_root = "$PLUGIN_ROOT"
with open(os.path.join(plugin_root, "skills/run-ticket/SKILL.md")) as f:
    body = f.read()
pat = re.compile(r'^\| \`([a-z-]+)\` \| \`(skills/[^/]+/SKILL\.md)\` \|', re.M)
missing = []
for stage, path in pat.findall(body):
    full = os.path.join(plugin_root, path)
    if not os.path.isfile(full):
        missing.append((stage, path))
if missing:
    print("FAIL skill files missing for stages:")
    for s, p in missing:
        print(f"  {s} -> {p}")
    raise SystemExit(1)
print(f"OK  all {len(pat.findall(body))} mapped skill files exist")
PY
```

Update the top-of-file comment so it lists 3 places (run-state, events, run-ticket) and notes the deletion of the lock-schema and lib/lock-acquire.sh extractors:

```bash
# Transition-graph lint.
#
# Verifies that the stage-machine transition graph is consistent across the
# 3 places it's currently duplicated:
#
# - run-state.schema.json:current_stage.enum (6 stages)
# - events.schema.json:stage.enum
# - run-ticket/SKILL.md dispatch table
#
# (Lock schema, lib/lock-acquire.sh, and resume-run's dispatch table were
# removed when the plugin dropped split-session mode; run-ticket's inlined
# dispatch table is the new single source of truth alongside the two schemas.)
```

- [ ] **Step 3: Run both tests to confirm they FAIL**

Run: `bash tests/unit/test-run-ticket-skill.sh`
Expected: FAIL — current skill body still references `resume-run`, doesn't have the inlined sections.

Run: `bash tests/unit/test-transition-graph.sh`
Expected: FAIL — current `run-ticket/SKILL.md` doesn't contain a stage dispatch table.

- [ ] **Step 4: Rewrite the run-ticket skill**

Open `skills/run-ticket/SKILL.md`. Replace the entire `## Driver loop` section AND the `## Side-effects summary` section AND the `## Forward-compatibility note` section with the following — leave everything ABOVE `## Driver loop` (the frontmatter, URL parsing, state initialization) untouched:

````markdown
## Driver loop

The driver inlines all per-iteration logic (previously delegated to `bugfix:resume-run`, which has been removed):

```
for iteration in 1..100:
  read state from .bugfix/runs/<ticket_id>.json

  if state.terminal != null:
    break  // loop is done (merge-ready, pr-closed, failed, or stage-not-implemented)

  if state.blocked_reason != null:
    // Resume-from-blocked detection (see section below)
    resume_signal = detect_resume_signal(state, events_log)
    if not resume_signal:
      break  // still paused, waiting for human resume
    clear state.blocked_reason and state.blocked_questions
    emit "resumed" event
    write state
    // fall through to dispatch

  skill_path = stage_to_skill[state.current_stage]
  if not exists(skill_path):
    // Stage-not-implemented terminal handling (see section below)
    set state.terminal = "stage-not-implemented"
    set state.blocked_reason = "skill <name> not present in this install"
    write state; emit block_and_comment event; post ticket comment
    break

  prev_stage = state.current_stage
  prev_semantic_state = semantic_fields(state)   // excludes updated_at

  invoke Skill(skill_path)                       // stage skill mutates state directly

  read new_state from .bugfix/runs/<ticket_id>.json
  no_change_this_iter = (
      new_state.current_stage == prev_stage
      and semantic_fields(new_state) == prev_semantic_state
  )

  // Stall guard: two consecutive iterations with no change (one grace iteration
  // before declaring stall).
  if no_change_this_iter and no_change_prev_iter:
    set state.terminal = "failed"
    set state.artifacts.failure_reason = "stalled — no progress across two iterations"
    write state
    break
  no_change_prev_iter = no_change_this_iter

else:
  // Iteration cap reached without hitting break.
  set state.terminal = "failed"
  set state.artifacts.failure_reason = "iteration cap reached"
  write state
```

**Iteration cap:** 100 per invocation. The loop should never need more than ~10 stage transitions (intake → planning → executing → finishing → ci-watching → pr-reviewing → terminal), so 100 is generous and protects against pathological infinite loops. On hit, set `state.terminal = "failed"` (record cause via `state.artifacts.failure_reason = "iteration cap reached"`). Do NOT also set `blocked_reason` — `terminal` and `blocked_reason` are mutually exclusive per the run-state schema.

**Progress guard:** in addition to the cap, two consecutive iterations with no semantic-state change AND no stage advance is declared a stall. Prevents the cap from being a slow timeout when a stage silently no-ops.

## Stage-to-skill mapping

| `state.current_stage` | Skill file path |
|---|---|
| `intake` | `skills/ticket-intake/SKILL.md` |
| `planning` | `skills/writing-plans/SKILL.md` |
| `executing` | `skills/executing-plan/SKILL.md` |
| `finishing` | `skills/autonomous-finishing/SKILL.md` |
| `ci-watching` | `skills/ci-watchdog/SKILL.md` |
| `pr-reviewing` | `skills/pr-final-review/SKILL.md` |

All six skills ship in the production plugin. The skill-not-implemented handler exists as a safety net for stripped-down or custom installs that may omit a skill file; in a default install it should never fire.

## Resume-from-blocked detection

When `state.blocked_reason != null`, the driver scans ticket comments for a non-bot "resume" signal:

1. Read the most-recent `block_and_comment` event's `t` field from `.bugfix/runs/<ticket_id>.events.log`.
2. Call `bugfix:ticket-adapter:read(state.issue_number)`. The adapter returns `comments[]` with `is_bot` flags derived from the bot-author rule (see ticket-adapter §2.5).
3. Filter `comments[]` to: `created_at > most_recent_block_event.t` AND `is_bot == false`.
4. In those filtered comments, check `body` (wrapped inside `<untrusted-input>` tags by the adapter). The comment counts as a resume signal iff, after stripping the wrapper tags, the **first non-whitespace token on the first non-empty line** equals `resume` (case-insensitive). Substring matches like "don't resume yet" or a quoted prior comment that happens to contain the word "resume" MUST NOT trigger. Operators are instructed (via the block-and-comment template) to reply with the single word `resume` on its own line.
5. On resume signal: clear `state.blocked_reason` and `state.blocked_questions`, emit `resumed` event (stage = `state.current_stage`, detail = `{}`), write state, and fall through to dispatch.
6. On no signal: break out of the loop (no state mutation).

Bot-comment filtering is mandatory — the plugin's own `block_and_comment` template contains the word "resume" (in "To resume, please..."), which would self-trigger if not filtered.

## Stage-not-implemented handling

When the resolved skill file does NOT exist on disk (a stripped-down install that removed a skill file):

1. Set `state.terminal = "stage-not-implemented"`.
2. Set `state.blocked_reason = "skill <skill_name> not present in this install"`.
3. Set `state.updated_at = <now>`.
4. Write state back.
5. Invoke `bugfix:ticket-adapter:ticket_comment(state.issue_number, <message>)` with this template:

   ```
   PR opened: <state.pr_url if state.pr_number else "(none)">

   The bugfix plugin's `<stage>` stage is not present in this install (skill file missing). The loop has done everything up to and including the previous stage. Please take over manually from here, or reinstall the plugin to restore the missing stage.

   Run history is in `.bugfix/runs/<ticket_id>.json` and `.bugfix/runs/<ticket_id>.events.log` (project-local files).
   ```

6. Emit `block_and_comment` event (stage = `<current_stage>`, detail = `{"reason": "skill-not-implemented", "missing_skill": "<name>", "exit_kind": "tech-failure"}`).
7. Exit the loop.

In a default install the handler never fires.

## Reporting back to the user

After the loop exits, report:

- One of two outcomes: a terminal value (`merge-ready` | `pr-closed` | `failed` | `stage-not-implemented`) if `state.terminal != null`, or a blocked status (with `state.blocked_reason`) if the loop paused for human input. Terminal and blocked are mutually exclusive — never report both.
- A summary of what happened: stages executed, any block reasons, PR link if `state.pr_number` is set.
- For `stage-not-implemented`: this only fires if the operator points the loop at a stage whose skill is absent. The PR (if any) is open; the operator picks up manually from the ticket comment.

## Side-effects summary

The driver:

- DOES write `.bugfix/runs/<ticket_id>.json` (initialization + state mutations).
- DOES append to `.bugfix/runs/<ticket_id>.events.log` (events from each stage and the driver itself).
- DOES dispatch stage skills (via the `Skill` tool).
- DOES push branches, open PRs, comment on tickets (via stage skills, not the driver itself).
- DOES NOT touch files outside `.bugfix/runs/` and `.worktrees/` from its own driver-level logic — those mutations come from stage skills.
- DOES NOT acquire any lock file — lock infrastructure was removed when the plugin dropped split-session mode.

## Forward-compatibility note

The frontmatter `description` is byte-stable across increments — the test pins it exactly. Body content may evolve as later increments refine the driver behavior. Do not change the frontmatter without a corresponding test update.
````

- [ ] **Step 5: Update the `run-ticket` skill's earlier sections that still reference `resume-run`**

Open `skills/run-ticket/SKILL.md`. In the `## State initialization (first invocation)` section, find the comment that says "Another concurrent invocation initialized this ticket. That's fine — the per-ticket lock acquired by stage skills will serialize subsequent work." and replace with:

```
# Another concurrent invocation initialized this ticket. That's fine —
# the single-session driver runs one stage at a time per ticket, so
# concurrent invocations on the same URL would interleave their loop
# iterations harmlessly (each iteration is its own read-modify-write of
# the state file). Skip the initialization, proceed to the loop.
```

- [ ] **Step 6: Run the run-ticket test to confirm it PASSES**

Run: `bash tests/unit/test-run-ticket-skill.sh`
Expected: `PASS`.

- [ ] **Step 7: Run the transition-graph test to confirm it PASSES**

Run: `bash tests/unit/test-transition-graph.sh`
Expected: `OK  run-state.schema.json matches canonical stage set`, `OK  events.schema.json matches canonical stage set`, `OK  run-ticket/SKILL.md matches canonical stage set`, `OK  all 6 mapped skill files exist`, `PASS`.

- [ ] **Step 8: Commit**

```bash
git add skills/run-ticket/SKILL.md tests/unit/test-run-ticket-skill.sh tests/unit/test-transition-graph.sh
git commit -m "Inline dispatch + resume detection into run-ticket; fold resume-run logic"
```

---

## Task 12: Delete `resume-run` skill and its test

**Files:**
- Delete: `skills/resume-run/SKILL.md`
- Delete: `tests/unit/test-resume-run-skill.sh`

- [ ] **Step 1: Delete the resume-run skill directory**

```bash
git rm -r skills/resume-run
```

- [ ] **Step 2: Delete the resume-run test**

```bash
git rm tests/unit/test-resume-run-skill.sh
```

- [ ] **Step 3: Run the full test suite to verify nothing references the deleted skill**

Run: `bash tests/run-unit-tests.sh`
Expected: All tests pass with final line `ALL PASS`. (The `test-using-bugfix-skill.sh` will still fail because it asserts `bugfix:resume-run` is mentioned in `using-bugfix/SKILL.md` — Task 13 fixes that. If you reach this point and the only failure is `test-using-bugfix-skill.sh`, proceed to Task 13. Any other failure is unexpected and requires investigation.)

- [ ] **Step 4: Commit**

```bash
git commit -m "Delete resume-run skill and its test (folded into run-ticket)"
```

---

## Task 13: Drop `resume-run` from `using-bugfix` meta-skill + test

**Files:**
- Modify: `skills/using-bugfix/SKILL.md`
- Test: `tests/unit/test-using-bugfix-skill.sh`

- [ ] **Step 1: Update the test to drop the `resume-run` entry from the catalog loop**

Open `tests/unit/test-using-bugfix-skill.sh`. In the `for s in \` block (the catalog-references loop), delete the `"resume-run" \` line. The loop should now contain 16 entries, not 17.

Add an inverse assertion right after the `echo "OK  catalog references present"` line:

```bash
# resume-run was folded into run-ticket; using-bugfix must not reference the deleted skill.
if grep -qF "bugfix:resume-run" "$SKILL"; then
  echo "FAIL using-bugfix still references the deleted bugfix:resume-run skill"
  exit 1
fi
echo "OK  no references to deleted bugfix:resume-run"
```

- [ ] **Step 2: Run the test to confirm it FAILS**

Run: `bash tests/unit/test-using-bugfix-skill.sh`
Expected: FAIL at the "no references to deleted bugfix:resume-run" check.

- [ ] **Step 3: Update the skill body**

Open `skills/using-bugfix/SKILL.md`. Make these edits:

**Edit 3a: Front-door driver bullet** — replace:

```
- `bugfix:run-ticket` - Recognizes "fix bug/issue <github-url>" requests, parses the URL, initializes run state under `.bugfix/runs/<ticket-id>.json`, acquires the per-ticket lock, and loops `bugfix:resume-run` until the ticket reaches a terminal state or blocks for human input.
```

with:

```
- `bugfix:run-ticket` - Recognizes "fix bug/issue <github-url>" requests, parses the URL, initializes run state under `.bugfix/runs/<ticket-id>.json`, and loops through the stage skills until the ticket reaches a terminal state or blocks for human input.
```

**Edit 3b: Stage skills preamble** — replace:

```
The autonomous loop progresses through these stage skills in order. You generally don't invoke them directly — `bugfix:run-ticket` and `bugfix:resume-run` dispatch them.
```

with:

```
The autonomous loop progresses through these stage skills in order. You generally don't invoke them directly — `bugfix:run-ticket` dispatches them via its inlined per-stage loop.
```

**Edit 3c: Delete the resume-run bullet from Stage skills list** — delete the entire line:

```
- `bugfix:resume-run` - Dispatches the next stage when invoked from a fresh session (or from `run-ticket`'s in-process loop).
```

- [ ] **Step 4: Run the test to confirm it PASSES**

Run: `bash tests/unit/test-using-bugfix-skill.sh`
Expected: `PASS`.

- [ ] **Step 5: Commit**

```bash
git add skills/using-bugfix/SKILL.md tests/unit/test-using-bugfix-skill.sh
git commit -m "Drop resume-run references from using-bugfix meta-skill"
```

---

## Task 14: Update README

**Files:**
- Modify: `README.md`

There is no direct unit test for README content, so this task uses targeted `grep` assertions after the edits to verify the strings of interest are gone.

- [ ] **Step 1: Drop the lock-troubleshooting row**

Open `README.md`. Find the troubleshooting table. Delete this row:

```
| `lock held by pid=N, refusing` | A previous run is still active OR crashed with a stale lock. Verify the pid isn't live (`ps -p N`); if dead, delete `.bugfix/runs/<ticket-id>.lock` and re-invoke. |
```

- [ ] **Step 2: Drop the `<ticket-id>.lock` line from the runtime-tree diagram**

Find the `.bugfix/` tree:

```
.bugfix/
├── runs/
│   ├── config.json               # plugin-wide knobs (per project)
│   ├── <ticket-id>.json          # run state
│   ├── <ticket-id>.events.log    # append-only JSONL audit trail
│   └── <ticket-id>.lock          # present only while a stage is actively executing
├── specs/
│   └── <ticket-id>.md            # bug spec written by ticket-intake (NOT committed)
└── plans/
    └── <ticket-id>.md            # implementation plan written by writing-plans (NOT committed)
```

Replace it with:

```
.bugfix/
├── runs/
│   ├── config.json               # plugin-wide knobs (per project)
│   ├── <ticket-id>.json          # run state
│   └── <ticket-id>.events.log    # append-only JSONL audit trail
├── specs/
│   └── <ticket-id>.md            # bug spec written by ticket-intake (NOT committed)
└── plans/
    └── <ticket-id>.md            # implementation plan written by writing-plans (NOT committed)
```

(Note: the box-drawing character on the `<ticket-id>.events.log` line changes from `├──` to `└──` since it's now the last entry.)

- [ ] **Step 3: Rewrite the "Try it" paragraph to drop lock + resume-run references**

Find the paragraph that begins `The agent invokes \`bugfix:run-ticket\``. Replace:

```
The agent invokes `bugfix:run-ticket`, parses the URL, initializes `.bugfix/runs/<ticket-id>.json`, acquires the per-ticket lock, and loops the stage skills to a terminal verdict on the PR. Identical behavior with `fix issue <url>` and `resolve issue <url>`.
```

with:

```
The agent invokes `bugfix:run-ticket`, parses the URL, initializes `.bugfix/runs/<ticket-id>.json`, and loops the stage skills to a terminal verdict on the PR. Identical behavior with `fix issue <url>` and `resolve issue <url>`.
```

- [ ] **Step 4: Rewrite the "Resuming a blocked ticket" instructions to drop `bugfix:resume-run`**

Find step 3 of "Resuming a blocked ticket":

```
3. Re-invoke `fix bug <url>` (or call `bugfix:resume-run` directly). The driver detects the resume signal, clears `blocked_reason` under the lock, and continues from the stored stage.
```

Replace with:

```
3. Re-invoke `fix bug <url>`. The driver detects the `resume` signal in the ticket comments, clears `blocked_reason`, and continues from the stored stage.
```

- [ ] **Step 5: Drop the `model_hints.stages` example from the config-section**

Find the example config block in the "Configuration" section. Replace:

```json
{
  "base_branch": "main",
  "ticket_adapter": "github",
  "retry_budgets": {
    "spec_review": 2,
    "code_quality_review": 2,
    "ci": 2,
    "planning": 2
  },
  "pr_review": {
    "adversary_enabled": true,
    "important_findings_block": false,
    "advocate_must_run_regression_test": true
  },
  "model_hints": {
    "stages": {
      "intake": "haiku",
      "ci-watching": "haiku"
    }
  },
  "bot_author_allowlist": ["our-ci-runner", "release-bot"]
}
```

with:

```json
{
  "base_branch": "main",
  "ticket_adapter": "github",
  "retry_budgets": {
    "spec_review": 2,
    "code_quality_review": 2,
    "ci": 2,
    "planning": 2
  },
  "pr_review": {
    "adversary_enabled": true,
    "important_findings_block": false,
    "advocate_must_run_regression_test": true
  },
  "model_hints": {
    "implementer": "opus"
  },
  "bot_author_allowlist": ["our-ci-runner", "release-bot"]
}
```

Also find the paragraph that explains `model_hints.stages.<stage>` (just after the JSON block) and replace:

```
`model_hints.stages.<stage>` is a host-agnostic hint at the model class (`haiku` / `sonnet` / `opus`) the host should spawn for each stage when driving the loop via `bugfix:resume-run` from external scheduling. Defaults: `intake` and `ci-watching` are Haiku-class (mechanical work); other stages inherit the host's session model. In-session drivers (`bugfix:run-ticket`) inherit the session model and ignore these hints — they exist for split-session hosts that can be cost-aware. The fix sub-agent dispatched by ci-watchdog on CI failure is NOT Haiku — it gets routed via `model_hints.implementer` since it does real implementation work.
```

with:

```
`model_hints.implementer` selects the model class (`haiku` / `sonnet` / `opus`) the host should spawn for sub-agents that do real implementation work — the per-task implementers dispatched by `executing-plan` and the CI fix sub-agent dispatched by `ci-watchdog`. The single-session driver itself inherits the session model.
```

- [ ] **Step 6: Verify the strings of interest are gone**

Run each check:

```bash
! grep -qF "lock held by pid" README.md && echo "OK  lock troubleshooting row gone"
! grep -qF "<ticket-id>.lock" README.md && echo "OK  lock file gone from runtime tree"
! grep -qF "acquires the per-ticket lock" README.md && echo "OK  lock-acquire phrasing gone"
! grep -qF "bugfix:resume-run" README.md && echo "OK  resume-run mention gone"
! grep -qF "model_hints.stages" README.md && echo "OK  model_hints.stages gone"
```

Expected: all five `OK` lines printed.

- [ ] **Step 7: Commit**

```bash
git add README.md
git commit -m "Update README — drop lock, resume-run, model_hints.stages references"
```

---

## Task 15: Final verification — full test suite

**Files:**
- (None — verification only.)

- [ ] **Step 1: Run the full unit test suite**

Run: `bash tests/run-unit-tests.sh`
Expected: Final line `ALL PASS`. No `FAILED:` lines anywhere in the output.

- [ ] **Step 2: Verify no lock infrastructure references survive anywhere in the plugin**

Run from the plugin root:

```bash
! grep -rln "lock-acquire\|lock-release\|\.lock\b\|lock_acquired\|lock_released\|lock_stolen" skills/ lib/ schemas/ hooks/ README.md VENDORED.md .claude-plugin/ 2>/dev/null \
  && echo "OK  no lock references in source tree"
```

Expected: `OK  no lock references in source tree`.

- [ ] **Step 3: Verify no `bugfix:resume-run` references survive**

```bash
! grep -rln "bugfix:resume-run\|resume-run/SKILL" skills/ README.md VENDORED.md .claude-plugin/ 2>/dev/null \
  && echo "OK  no bugfix:resume-run references"
```

Expected: `OK  no bugfix:resume-run references`.

- [ ] **Step 4: Verify no `model_hints.stages` references survive**

```bash
! grep -rln "model_hints\.stages\|model_hints/stages\|\"stages\":" schemas/ skills/ README.md tests/fixtures/ 2>/dev/null \
  && echo "OK  no model_hints.stages references"
```

Expected: `OK  no model_hints.stages references`.

- [ ] **Step 5: Verify the directory structure matches expectations**

```bash
[[ ! -e lib/lock-acquire.sh ]] && echo "OK  lib/lock-acquire.sh deleted"
[[ ! -e lib/lock-release.sh ]] && echo "OK  lib/lock-release.sh deleted"
[[ ! -e schemas/lock.schema.json ]] && echo "OK  schemas/lock.schema.json deleted"
[[ ! -e skills/resume-run ]] && echo "OK  skills/resume-run deleted"
[[ ! -e tests/unit/test-lock-acquire.sh ]] && echo "OK  test-lock-acquire.sh deleted"
[[ ! -e tests/unit/test-lock-release.sh ]] && echo "OK  test-lock-release.sh deleted"
[[ ! -e tests/unit/test-lock-schema.sh ]] && echo "OK  test-lock-schema.sh deleted"
[[ ! -e tests/unit/test-resume-run-skill.sh ]] && echo "OK  test-resume-run-skill.sh deleted"
[[ ! -e tests/fixtures/lock-valid.json ]] && echo "OK  lock-valid.json fixture deleted"
[[ ! -e tests/fixtures/lock-invalid-no-pid.json ]] && echo "OK  lock-invalid-no-pid.json fixture deleted"
[[ ! -e tests/fixtures/config-invalid-stage-key.json ]] && echo "OK  config-invalid-stage-key.json fixture deleted"
```

Expected: 11 `OK` lines.

- [ ] **Step 6: Inspect git log for the refactor commit chain**

Run: `git log --oneline main..HEAD`
Expected: 16 commits — the design doc commit at the base, plus one commit per task (Tasks 1-14 each produce one commit; Task 15 verification produces zero commits unless stragglers were found). No commit should be an `--amend` or a force-push artifact.

- [ ] **Step 7: Final commit (optional — only if verification revealed any stragglers)**

If any of the above verification checks failed, fix the issue, run the full test suite again, and create a final cleanup commit:

```bash
git add <files>
git commit -m "Final cleanup — <specific issue>"
```

If all checks passed, no final commit is needed — the refactor is complete.

---

## Self-review against spec

Spot-check the spec's acceptance criteria:

1. ✅ The ten listed files are absent from the repo. (Verified in Task 15, Step 5.)
2. ✅ `events.schema.json` and `config.schema.json` trims pass schema tests. (Verified in Tasks 1, 2, 15.)
3. ✅ No surviving skill mentions `lock-acquire.sh`, `lock-release.sh`, `.lock`, `lock_acquired`, `lock_released`, `lock_stolen`, or `bugfix:resume-run`. (Verified in Task 15, Steps 2 and 3.)
4. ✅ Full `tests/run-unit-tests.sh` suite passes `ALL PASS`. (Verified in Task 15, Step 1.)
5. ✅ README's runtime-tree diagram no longer shows `<ticket-id>.lock`; troubleshooting table no longer contains the lock row; resuming-a-blocked-ticket section no longer references `bugfix:resume-run`. (Verified in Task 14.)
6. ✅ Plugin manifest (`.claude-plugin/plugin.json`) does NOT enumerate skills, so no edit was needed (per the design doc's "if it enumerates skills, remove `resume-run`" conditional).
