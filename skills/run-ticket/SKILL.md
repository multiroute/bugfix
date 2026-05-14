---
name: run-ticket
description: Use when the user asks to fix a bug or resolve an issue referenced by a GitHub issue URL (e.g., "fix bug https://github.com/owner/repo/issues/N", "fix issue <url>", "resolve issue <url>"). Front-door entry point for the autonomous bug-fix loop.
---

# bugfix:run-ticket

Front-door driver for the autonomous bug-fix loop. Recognizes natural-language requests that pair a verb ("fix", "resolve") with a GitHub issue URL, initializes per-ticket run state, and loops `bugfix:resume-run` until the ticket reaches a terminal state or blocks for human input.

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

If the file does NOT exist, create it **atomically** using `set -o noclobber` (the same primitive `lock-acquire.sh` uses). This prevents two concurrent `run-ticket` invocations on the same URL from both seeing "file absent" and both writing initial state.

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
  # the per-ticket lock acquired by stage skills will serialize subsequent
  # work. Skip the initialization, proceed to the loop.
  :
else
  # We initialized. Emit the intake_started event.
  bugfix/lib/events-append.sh ".bugfix/runs/<ticket_id>.events.log" intake_started intake '{}'
fi
```

The `intake_started` event is emitted only by the invocation that won the noclobber race — never twice.

## Driver loop

```
loop:
  invoke bugfix:resume-run with ticket_id
  read .bugfix/runs/<ticket_id>.json (state-file-first)
  if state.terminal != null:
    break  // loop is done (merge-ready, pr-closed, blocked, failed, or stage-not-implemented)
  if state.blocked_reason != null:
    break  // human must take over
  continue  // next iteration; resume-run advanced current_stage
```

Each loop iteration dispatches exactly one stage via `resume-run`. The loop exits when state reaches a terminal value OR a blocked state OR (in pathological cases) an iteration count cap.

### Red flags during the driver loop

If you catch yourself thinking any of these, STOP and re-invoke `bugfix:resume-run`:

| Thought | Reality |
|---|---|
| "I already have the data, I can do this inline" | The whole point of resume-run is fresh-context isolation. Invoke it. |
| "User said fix it, I should just deliver" | Delivery comes from finishing the loop, not from skipping it. |
| "Stage X is simple, I can collapse it with Y" | Stages are independent for a reason — review checkpoints, retry budgets, terminal-state tracking. Don't collapse. |
| "The adapter failed, I'll work around it" | Adapter failures must escalate via `block-and-comment(tech-failure)`. Don't improvise. |

Every iteration MUST be one `Skill: bugfix:resume-run` call. If your next tool call after this section is anything other than `Skill: bugfix:resume-run`, you are violating the contract.

**Iteration cap:** maximum 100 iterations per invocation. The bugfix loop should never need more than ~10 stage transitions (intake → planning → executing → finishing → ci-watching → pr-reviewing → terminal), so a cap of 100 is generous and protects against pathological infinite loops. If the cap is hit, set `state.terminal = "failed"` (record the cause via `state.artifacts.failure_reason = "iteration cap reached"`) and exit. Do NOT also set `blocked_reason` — `terminal` and `blocked_reason` are mutually exclusive per the run-state schema.

**Progress guard:** in addition to the cap, if `state.current_stage` is unchanged AND no state mutation occurred across two consecutive iterations, declare progress lost and set `state.terminal = "failed"` (artifacts.failure_reason = "stalled — no progress across two consecutive iterations") immediately. Prevents the cap from being a slow timeout when a stage silently no-ops.

## Reporting back to the user

After the loop exits, report:

- One of two outcomes: a terminal value (`merge-ready` | `pr-closed` | `failed` | `stage-not-implemented`) if `state.terminal != null`, or a blocked status (with `state.blocked_reason`) if the loop paused for human input. Terminal and blocked are mutually exclusive — never report both.
- A summary of what happened: stages executed, any block reasons, PR link if `state.pr_number` is set.
- For `stage-not-implemented`: this only fires if the operator points the loop at a stage whose skill is absent (e.g., a stripped-down install or a custom branch that removed a skill file). The PR (if any) is open; the operator picks up manually from the ticket comment.

## Side-effects summary

The driver:

- DOES write `.bugfix/runs/<ticket_id>.json` (initialization + state mutations from each stage).
- DOES acquire `.bugfix/runs/<ticket_id>.lock` (indirectly via each stage skill).
- DOES append to `.bugfix/runs/<ticket_id>.events.log` (events from each stage).
- DOES dispatch sub-agents (via stage skills like `executing-plan`).
- DOES push branches, open PRs, comment on tickets (via `autonomous-finishing`).
- DOES NOT touch files outside `.bugfix/runs/` and `.worktrees/` from its own driver-level logic — those mutations come from stage skills.

## Forward-compatibility note

The frontmatter `description` is byte-stable across increments — the test pins it exactly. Body content may evolve as later increments refine the driver behavior. Do not change the frontmatter without a corresponding test update.
