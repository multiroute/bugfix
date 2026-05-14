---
name: resume-run
description: Use to advance an in-flight bugfix ticket by one stage. Reads `.bugfix/runs/<ticket-id>.json`, checks for terminal/blocked states, acquires the lock, dispatches the skill named by `current_stage`, releases the lock, exits. Does NOT loop — `bugfix:run-ticket` is the loop driver. Use directly from an external scheduler that wants fresh-session-per-stage execution.
---

# bugfix:resume-run

Single-stage dispatcher. The contract is small, the failure modes are explicit, and the skill MUST exit cleanly after exactly one stage dispatch (or one terminal-state observation).

**Single-dispatcher rule:** resume-run dispatches exactly one stage skill via the `Skill` tool, then exits. If you find yourself wanting to inline the stage's work instead of invoking it as a skill, STOP — the dispatch must happen via the `Skill` tool so the next agent context can pick up cleanly if the run is split across sessions, and so the PostToolUse hook can fire on the stage invocation.

## Contract

**Input:** `ticket_id` (string, of the form `<owner>-<repo>-<number>`).

**Behavior:**

1. Read `.bugfix/runs/<ticket_id>.json`. If file is absent → exit with error "no run state for ticket <ticket_id>; use `bugfix:run-ticket` to initialize."
2. If `state.terminal != null` → exit (terminal status, nothing to do).
3. If `state.blocked_reason != null` → check resume-from-blocked detection (see below). If a non-bot "resume" comment is detected, clear `blocked_reason` and `blocked_questions`, emit `resumed` event, proceed. Otherwise exit ("still blocked, waiting for human resume").
4. Resolve the skill file path from `current_stage` via the mapping below.
5. **Skill-not-implemented check:** if the skill file does NOT exist on disk, perform the not-implemented terminal handling (see below). `resume-run` is responsible for acquiring + releasing the lock on this branch ONLY, since no stage skill runs.
6. Invoke the skill at that path via the `Skill` tool. **The dispatched stage skill is responsible for its own lock acquire AND release** (via `bugfix/lib/lock-acquire.sh` and `bugfix/lib/lock-release.sh`). `resume-run` does NOT touch the lock when a stage skill runs.
7. After the skill exits, do NOT advance state yourself (the dispatched skill already did that or invoked `block-and-comment`). Just exit.

**Does NOT loop.** This is exactly one stage per invocation. `bugfix:run-ticket` is the loop driver.

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

## Per-stage model hints (external schedulers)

A host that drives `resume-run` from an external scheduler (one fresh session per stage) SHOULD pick the model to spawn based on `config.model_hints.stages.<current_stage>` before invoking. The recommended defaults, when the key is absent:

| Stage | Recommended class | Why |
|---|---|---|
| `intake` | `haiku` | Mechanical text classification + spec extraction. No design judgment. |
| `planning` | session default | Real design work; the planner reviewer dispatched here is the second-stage check. |
| `executing` | session default | Implementer + reviewer sub-agents do the heavy lifting; the executing-plan controller orchestrates. |
| `finishing` | session default | Test verification + push + PR open. Mechanical but error-handling matters. |
| `ci-watching` | `haiku` | Mechanical poll-classify-dispatch loop. Fix sub-agents it spawns are NOT haiku (they get `model_hints.implementer`). |
| `pr-reviewing` | session default | Decision rule + advocate/adversary dispatch; the reviewers themselves are the heavy work. |

In-session drivers (`bugfix:run-ticket` long-running loop) cannot switch models mid-run, so they inherit the session model regardless. The hints exist to let split-session hosts (cron, webhook → fresh session, etc.) be cost-aware.

## Skill-not-implemented handling

When the resolved skill file does NOT exist on disk:

1. Read `.bugfix/runs/<ticket_id>.json` again (state may have changed since step 5 above).
2. Set `state.terminal = "stage-not-implemented"`.
3. Set `state.blocked_reason = "skill <skill_name> not present in this install"`.
4. Set `state.updated_at = <now>`.
5. Write state back.
6. Invoke `bugfix:ticket-adapter:ticket_comment(issue_number, <message>)` with this template:

```
PR opened: <pr_url if state.pr_number else "(none)">

The bugfix plugin's `<stage>` stage is not present in this install (skill file missing). The loop has done everything up to and including the previous stage. Please take over manually from here, or reinstall the plugin to restore the missing stage.

Run history is in `.bugfix/runs/<ticket_id>.json` and `.bugfix/runs/<ticket_id>.events.log` (project-local files).
```

7. Emit `block_and_comment` event (stage="<current_stage>", detail={"reason": "skill-not-implemented", "missing_skill": "<name>"}).
8. Release the lock.
9. Exit.

In a default install the handler never fires; it exists so a stripped-down install that omits a stage skill still produces a clean terminal verdict instead of crashing mid-loop.

## Resume-from-blocked detection

When `state.blocked_reason != null`, scan ticket comments for a non-bot "resume" signal:

1. Read the most-recent `block_and_comment` event's `t` field from `.bugfix/runs/<ticket_id>.events.log`.
2. Call `bugfix:ticket-adapter:read(state.issue_number)`. The adapter returns `comments[]` with `is_bot` flags derived from the bot-author rule (see ticket-adapter §2.5).
3. Filter `comments[]` to: `created_at > most_recent_block_event.t` AND `is_bot == false`.
4. In those filtered comments, check `body` (which is inside `<untrusted-input>` tags). The comment counts as a resume signal iff, after stripping the wrapper tags, the **first non-whitespace token on the first non-empty line** equals `resume` (case-insensitive). Substring matches like "don't resume yet", "I'll resume tomorrow", or a quoted prior comment that happens to contain the word "resume" MUST NOT trigger. Operators are instructed (via the block-and-comment template) to reply with the single word `resume` on its own line.
5. On resume signal: **acquire the lock first** (`bugfix/lib/lock-acquire.sh ".bugfix/runs/<ticket_id>.lock" "<session_id>" "<state.current_stage>"`), then read the state again under the lock, then clear `state.blocked_reason` and `state.blocked_questions`, emit `resumed` event, write state, release the lock, and re-enter the dispatch loop. This ordering prevents two racing `resume-run` invocations from both clearing `blocked_reason` and both emitting `resumed` events.
6. On no signal: exit cleanly, no state mutation.

Bot-comment filtering is mandatory — the plugin's own `block_and_comment` template contains the word "resume" (in "To resume, please..."), which is a self-trigger if not filtered.

## Operation order

```
read state
  -> terminal? exit
  -> blocked? check resume; if no -> exit
resolve skill path from current_stage
  -> file missing? acquire lock; skill-not-implemented handling; release lock; exit
dispatch skill via Skill tool (stage skill acquires lock first, then releases on exit)
  -> skill returns: skill itself acquired+released lock + wrote state; just exit
  -> on BLOCKED: block-and-comment already commented + released lock; just exit
```

**Lock ownership:** stage skills own the lock — each stage skill acquires (via `bugfix/lib/lock-acquire.sh`) at the start of its work AND releases (via `bugfix/lib/lock-release.sh`) on every exit path (clean, blocked, or stage error). `resume-run` does NOT acquire the lock when dispatching a stage skill. The ONLY place `resume-run` touches the lock is the skill-not-implemented branch, where it acquires the lock just to write `state.terminal` safely, then releases before exiting. This single-owner-per-call model prevents the double-acquire deadlock where both `resume-run` and the dispatched stage try to hold the lock simultaneously.
