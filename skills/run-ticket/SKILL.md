---
name: run-ticket
description: Use when the user asks to fix a bug or resolve an issue referenced by a GitHub issue URL (e.g., "fix bug https://github.com/owner/repo/issues/N", "fix issue <url>", "resolve issue <url>"). Front-door entry point for the autonomous bug-fix loop.
---

# bugfix:run-ticket

Front-door driver for the autonomous bug-fix loop. Recognizes natural-language requests that pair a verb ("fix", "resolve") with a GitHub issue URL, initializes per-ticket run state, and loops until the ticket reaches a terminal state or blocks for human input.

## When triggered

Trigger conditions — any of these phrasings, paired with a GitHub issue URL:

- `fix bug <github-issue-url>`
- `fix issue <github-issue-url>`
- `resolve issue <github-issue-url>`

Example user messages:

```
fix bug https://github.com/multiroute/platform/issues/125
fix issue https://github.com/multiroute/platform/issues/125
resolve issue https://github.com/multiroute/platform/issues/125
```

## URL parsing

Apply the **fully-anchored** regex to the user's message:

```
^https://github\.com/([A-Za-z0-9._-]+)/([A-Za-z0-9._-]+)/issues/([0-9]+)/?$
```

Anchors and charset constraints are intentional:
- Leading `^` and trailing `/?$` reject URLs with appended garbage (e.g., `.../issues/118foobar` or `.../issues/118/../evil`).
- Owner and repo charset `[A-Za-z0-9._-]+` matches GitHub's allowed characters for those fields. Rejects URL-encoded slashes (`%2F`), path traversal segments, and metacharacters that could smuggle into a worktree path or `gh` argument.
- Issue number is `[0-9]+` (greedy, but the trailing `/?$` forces the whole tail to be only digits + optional slash).

Capture groups are `owner`, `repo`, `number`.

Reject and report when:
- The URL doesn't match the anchored regex (PR URLs like `/pull/123`, malformed, non-`github.com` host, owner/repo with invalid characters).
- The host is `github.com` but the path doesn't fit `/<owner>/<repo>/issues/<number>`.

On a successful match, derive `ticket_id = <owner>-<repo>-<number>`. Examples:
- `https://github.com/multiroute/platform/issues/125` -> `ticket_id = multiroute-platform-125`
- `https://github.com/acme/api/issues/7` -> `ticket_id = acme-api-7`

On URL parse failure: reply to the user
> "That URL doesn't look like a GitHub issue URL. Expected `https://github.com/<owner>/<repo>/issues/<number>` with owner/repo using only `A-Za-z0-9._-` characters. Got: `<user's url verbatim>`."

Then exit. Do NOT initialize state for an unparseable URL.

## State initialization (first invocation)

Check whether `.bugfix/runs/<ticket_id>.json` exists. If it does, the loop is resuming an in-flight ticket — do NOT overwrite; proceed directly to the loop.

If the file does NOT exist, create it **atomically** using `set -o noclobber`. This prevents two concurrent `run-ticket` invocations on the same URL from both seeing "file absent" and both writing initial state.

```bash
mkdir -p .runs
# Atomic create — fails (non-zero exit) if the file appeared between the
# absent-check above and this write. On collision the OTHER invocation
# initialized the state; we simply join the loop without overwriting.
if ! ( set -o noclobber; cat > ".bugfix/runs/<ticket_id>.json" <<'JSON'
{
  "ticket_id": "<owner>-<repo>-<number>",
  "owner": "<owner>",
  "repo": "<repo>",
  "issue_number": <integer>,
  "started_at": "<now ISO 8601 UTC with millisecond precision>",
  "updated_at": "<now>",
  "current_stage": "intake",
  "terminal": null,
  "base_branch": "<from config.base_branch, default 'main'>",
  "retries": {},
  "artifacts": {}
}
JSON
) 2>/dev/null; then
  # Another concurrent invocation initialized this ticket. That's fine —
  # the single-session driver runs one stage at a time per ticket, so
  # concurrent invocations on the same URL would interleave their loop
  # iterations harmlessly (each iteration is its own read-modify-write of
  # the state file). Skip the initialization, proceed to the loop.
  :
else
  # We initialized. Emit the intake_started event.
  bugfix/lib/events-append.sh ".bugfix/runs/<ticket_id>.events.log" intake_started intake '{}'
fi
```

The `intake_started` event is emitted only by the invocation that won the noclobber race — never twice.

## Driver loop

The driver inlines all per-iteration logic (the former separate stage-dispatch skill has been removed and its logic folded in here):

```
no_change_prev_iter = false  // initialized so the stall guard's first iteration never trips

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

### Red flags during the driver loop

If you catch yourself thinking any of these, STOP and let the loop above dispatch the next stage:

| Thought | Reality |
|---|---|
| "I already have the data, I can do this inline" | The driver loop's iterations exist so each stage's state-file read picks up changes from the prior stage cleanly. Inlining breaks that handoff. |
| "User said fix it, I should just deliver" | Delivery comes from finishing the loop, not from skipping it. |
| "Stage X is simple, I can collapse it with Y" | Stages are independent for a reason — review checkpoints, retry budgets, terminal-state tracking. Don't collapse. |
| "The adapter failed, I'll work around it" | Adapter failures must escalate via `block-and-comment(tech-failure)`. Don't improvise. |

Every iteration MUST go through the driver loop's stage dispatch (via the `Skill` tool on the resolved stage skill). Bypassing the loop to inline stage work violates the contract.

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
