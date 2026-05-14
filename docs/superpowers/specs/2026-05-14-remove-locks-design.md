# Remove locks and split-session mode

## Goal

Simplify the bugfix plugin under the assumption that a single long Claude session drives the bug-fix loop end-to-end. Per-ticket file locks and the "fresh session per stage" external-scheduler mode are deleted. `resume-run` is folded into `run-ticket`.

## Motivation

The current plugin supports two execution modes:

1. **In-session loop** — `run-ticket` invokes `resume-run` repeatedly in one session.
2. **External scheduler** — a cron/webhook spawns a fresh Claude session per stage and calls `resume-run` directly.

Locks (`.bugfix/runs/<ticket-id>.lock`, `lib/lock-acquire.sh`, `lib/lock-release.sh`, `schemas/lock.schema.json`) exist primarily to protect mode 2 from races and to provide stale-recovery for crashed sessions. With mode 2 dropped, locks become dead weight: stage skills, `resume-run`, and `block-and-comment` all carry acquire/release boilerplate that buys nothing in single-session operation.

The plugin's `config.model_hints.stages.<stage>` knob and `resume-run`'s "per-stage model hints" documentation similarly exist only for split-session hosts that can swap models between stages. They go too.

## Non-goals

- No change to the stage graph (`intake → planning → executing → finishing → ci-watching → pr-reviewing`) or to terminal/blocked verdicts.
- No change to `block-and-comment`'s pause semantics beyond removing the lock-release step.
- No change to the ticket-adapter contract.
- No change to events-log shape beyond removing the three lock-related event names from the enum.
- No new public surface. This change is pure subtraction.

## What gets deleted

**Files removed outright:**

- `lib/lock-acquire.sh`
- `lib/lock-release.sh`
- `schemas/lock.schema.json`
- `tests/unit/test-lock-acquire.sh`
- `tests/unit/test-lock-release.sh`
- `tests/unit/test-lock-schema.sh`
- `tests/unit/test-resume-run-skill.sh`
- `tests/fixtures/lock-valid.json`
- `tests/fixtures/lock-invalid-no-pid.json`
- `skills/resume-run/SKILL.md`

**Schema-enum trims:**

- `schemas/events.schema.json` — remove `lock_acquired`, `lock_released`, `lock_stolen` from the `event` enum.
- `schemas/config.schema.json` — remove `model_hints.stages`. `model_hints.implementer` is kept (it's per-sub-agent, independent of split-session).

**Rationale for accepting the schema break:** `.bugfix/` is project-local, gitignored, ephemeral. Old event logs aren't artifacts; any in-flight run on the old plugin is restarted from scratch under the new one.

## What stays

- **Per-ticket state file** `.bugfix/runs/<ticket-id>.json` — still the single source of truth. State-file-first invariant in stage skills is kept; survives crashes mid-stage and is the only way `resume-after-block` works across sessions.
- **Events log** `.bugfix/runs/<ticket-id>.events.log` — audit trail, schema unchanged except for the three lock-event removals.
- **Atomic state initialization** in `run-ticket` — keeps `set -o noclobber` for the initial-state write. Cheap defense against two `fix bug <same-url>` invocations racing.
- **`block-and-comment`** — unchanged in role. Effect 5 ("Release the lock") is deleted; idempotency check, ticket comment, status set, event append, return `BLOCKED` all remain.
- **Resume-from-blocked re-entry** — when a paused ticket is resumed via a new `fix bug <url>` invocation, `run-ticket` reads state, sees `blocked_reason != null`, scans for a non-bot `resume` comment after the most-recent `block_and_comment` event timestamp, clears `blocked_reason` / `blocked_questions`, emits `resumed` event, continues the loop.
- **Iteration cap (100) and progress-stall guard** in `run-ticket`'s loop — protect against pathological runs, independent of locking.
- **Stage-not-implemented safety net** — moves from `resume-run` into `run-ticket`'s dispatch step. When a stage skill file is missing, set `state.terminal = "stage-not-implemented"`, post the ticket comment, exit. No lock acquire/release needed.

## New `run-ticket` control flow

The current loop body delegates each iteration to `resume-run`. The new design inlines that body:

```
parse URL -> (owner, repo, number); reject and report on mismatch
ticket_id = "<owner>-<repo>-<number>"
state_path = ".bugfix/runs/<ticket_id>.json"

initialize state via `set -o noclobber` if absent; emit intake_started if we won the race

for iteration in 1..100:
  state = read(state_path)

  if state.terminal != null:
    break

  if state.blocked_reason != null:
    # Resume-from-blocked detection (moved from resume-run)
    last_block_t = most-recent block_and_comment event timestamp from events.log
    comments = ticket-adapter:read(state.issue_number).comments
    resume_signal = first non-bot comment after last_block_t whose first
                    non-whitespace token on the first non-empty line is "resume"
                    (case-insensitive)
    if not resume_signal:
      break  # still paused, exit cleanly
    clear state.blocked_reason, state.blocked_questions
    emit "resumed" event
    write state
    # fall through to dispatch

  skill_path = stage_to_skill[state.current_stage]
  if not exists(skill_path):
    state.terminal = "stage-not-implemented"
    state.blocked_reason = "skill <name> not present in this install"
    write state
    emit block_and_comment event
    post ticket comment
    break

  prev_stage = state.current_stage
  prev_semantic_state = semantic_fields(state)   # excludes `updated_at`
  invoke Skill(skill_path)                       # stage skill mutates state directly
  new_state = read(state_path)
  no_change_this_iter = (
      new_state.current_stage == prev_stage
      and semantic_fields(new_state) == prev_semantic_state
  )

  # Stall guard: two consecutive iterations with no change. Preserves the
  # current run-ticket semantics (one grace iteration before declaring stall).
  if no_change_this_iter and no_change_prev_iter:
    state.terminal = "failed"
    state.artifacts.failure_reason = "stalled — no progress across two iterations"
    write state
    break
  no_change_prev_iter = no_change_this_iter
else:
  # Iteration cap hit
  state.terminal = "failed"
  state.artifacts.failure_reason = "iteration cap reached"
  write state
```

**Stage-to-skill mapping** (moved from `resume-run` verbatim):

| `state.current_stage` | Skill file path                       |
|-----------------------|----------------------------------------|
| `intake`              | `skills/ticket-intake/SKILL.md`        |
| `planning`            | `skills/writing-plans/SKILL.md`        |
| `executing`           | `skills/executing-plan/SKILL.md`       |
| `finishing`           | `skills/autonomous-finishing/SKILL.md` |
| `ci-watching`         | `skills/ci-watchdog/SKILL.md`          |
| `pr-reviewing`        | `skills/pr-final-review/SKILL.md`      |

## Skill-by-skill edits

**Stage skills (drop lock acquire/release; keep all other behavior):**

| Skill                                | Edit |
|--------------------------------------|------|
| `skills/ticket-intake/SKILL.md`      | Remove step 3 (lock acquire) and the "release the lock" line in success/exit paths. |
| `skills/writing-plans/SKILL.md`      | Remove step 3 (lock acquire) and the "lock first, side-effects second" paragraph. |
| `skills/executing-plan/SKILL.md`     | Remove step 2 (lock acquire) and step 3 (lock release at end). |
| `skills/autonomous-finishing/SKILL.md` | Remove step 2 (lock acquire). |
| `skills/ci-watchdog/SKILL.md`        | Remove step 3 (lock acquire) and its release. |
| `skills/pr-final-review/SKILL.md`    | Remove step 3 (lock acquire) and its release. |
| `skills/block-and-comment/SKILL.md`  | Remove effect 5 ("Release the lock"); renumber. Update "Resume protocol (for reference)" to point at `bugfix:run-ticket` (resume-run no longer exists). Drop the "release the lock" mention from the description frontmatter. |

**Driver skill:**

- `skills/run-ticket/SKILL.md` — rewrite "Driver loop" and "Side-effects summary" to reflect the inlined control flow above. Remove "DOES acquire `.bugfix/runs/<ticket_id>.lock`". Add the stage-to-skill mapping and resume-from-blocked detection (moved from `resume-run`).

**Meta-skill:**

- `skills/using-bugfix/SKILL.md` — drop the `bugfix:resume-run` bullet from "Stage skills". Rewrite the "Front-door driver" bullet to remove "acquires the per-ticket lock, and loops `bugfix:resume-run`".

**Plugin manifest:**

- `.claude-plugin/plugin.json` — if it enumerates skills, remove `resume-run`.

**Docs:**

- `README.md` — drop the `lock held by pid=N` troubleshooting row. Drop the `<ticket-id>.lock` line from the runtime-tree diagram. Remove the "acquires the per-ticket lock" phrasing from "Try it" / "Resuming a blocked ticket". Resume protocol now points only at re-invoking `fix bug <url>`, not `bugfix:resume-run`.
- `VENDORED.md` — no changes (lock helpers are first-party).

**Tests that need touch (beyond deletions):**

- `tests/unit/test-events-schema.sh` — fixtures or assertions referencing the three lock event names get pruned.
- `tests/unit/test-event-name-agreement.sh` — scans skill bodies for event-name usage; the three lock events disappear from the corpus.
- `tests/unit/test-using-bugfix-skill.sh` — drop assertions on the `resume-run` bullet.
- `tests/unit/test-state-schema.sh` — no schema change; verify it still passes.
- `tests/unit/test-transition-graph.sh` — no transition change; verify it still passes.
- `tests/unit/test-run-ticket-skill.sh` (if present; if absent, add) — assertions on driver-loop language and on the inlined resume-from-blocked detection.
- Per-stage skill tests (`test-ticket-intake-skill.sh`, `test-writing-plans-skill.sh`, `test-executing-plan-skill.sh`, `test-autonomous-finishing-skill.sh`, `test-ci-watchdog-skill.sh`, `test-pr-final-review-skill.sh`, `test-block-and-comment-skill.sh`) — drop assertions on lock-acquire/release language.

## Risks and edge cases

**Concurrency posture.** With locks gone, the plugin assumes one active driver per ticket per host. Failure modes:

- Two `fix bug <url>` invocations on the same URL in the same session: initial state write is protected by `set -o noclobber` (the loser joins the loop). If both proceed past initialization, both call the same stage skill on stale `current_stage`. Accepted; documented as "don't launch two `fix bug <url>` for the same URL."
- Crashed Claude session leaving a stale `.bugfix/runs/<ticket-id>.json`: harmless. Re-invoking `fix bug <url>` reads state and continues from `current_stage`. The old "stale `.lock` file confuses the next invocation" failure mode disappears.

**`block-and-comment` idempotency.** Unchanged. The `(reason, exit_kind)` dedupe key still prevents duplicate ticket comments on re-invocation.

**Resume detection correctness.** Moves verbatim from `resume-run` into `run-ticket`: bot-author filtering, "first non-whitespace token on first non-empty line == resume" rule (case-insensitive), `created_at > most_recent_block_event.t` filter, all preserved. The `test-resume-run-skill.sh` assertions on this logic are re-homed in `test-run-ticket-skill.sh`.

**Stage-not-implemented.** Still produces a clean `stage-not-implemented` terminal verdict; the only change is no lock dance around the state-write.

**Events log.** `lock_acquired` / `lock_released` / `lock_stolen` are gone from the enum. Existing per-project logs that contain these would fail schema validation if validated, but the validator is only run by unit tests on synthetic fixtures, so this is a non-issue.

## Acceptance criteria

1. The ten listed files are absent from the repo.
2. `events.schema.json` and `config.schema.json` no longer contain the trimmed enums/fields, and existing unit tests for both pass.
3. None of the surviving skill files mentions `lock-acquire.sh`, `lock-release.sh`, `.lock`, `lock_acquired`, `lock_released`, `lock_stolen`, or `bugfix:resume-run`. (Verified by grep in a meta-test.)
4. The full `tests/run-unit-tests.sh` suite passes with `ALL PASS`.
5. README's runtime-tree diagram does not show `<ticket-id>.lock`. README's troubleshooting table does not contain the lock row. The "Resuming a blocked ticket" section directs users at re-invoking `fix bug <url>`, not at `bugfix:resume-run`.
