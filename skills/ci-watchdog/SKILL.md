---
name: ci-watchdog
description: Use as the post-PR-opened stage of the autonomous bug-fix loop. Waits for CI on the open PR via `bugfix:ticket-adapter:ci_watch`, dispatches a fix sub-agent on failure (bounded retries), advances state to pr-reviewing on success. Dispatched by `bugfix:run-ticket` when `state.current_stage == "ci-watching"`.
---

# bugfix:ci-watchdog

Watches CI on the PR opened by `autonomous-finishing`. On `success` → advance to `pr-reviewing`. On `failure` → dispatch a fix sub-agent (bounded retries) → resume watching. On retry exhaustion or watch timeout → block-and-comment.

**Recommended model: Haiku for the watchdog controller itself.** The controller's work is mechanical: snapshot CI, call `ci_watch` if pending, classify the result, dispatch a fix sub-agent on failure. The single-session `bugfix:run-ticket` driver inherits the session model, so this recommendation is informational — useful when the host can choose to spawn a cheaper model. **The fix sub-agent dispatched on CI failure is a separate concern** — that sub-agent does real implementation work and should run at implementer-class (the same model the executing-plan implementer would use). The watchdog body explicitly passes `model_hint = config.model_hints.implementer` (default: the host's implementer tier) when constructing the fix-sub-agent dispatch.

## State-file-first context

This skill is invoked by `bugfix:run-ticket` when `state.current_stage == "ci-watching"`. Before doing any work:

1. Read `.bugfix/runs/<ticket-id>.json`. Confirm `current_stage == "ci-watching"`. If not, exit with an error.
2. Confirm `state.pr_number != null` (set by `autonomous-finishing`). If null, exit via `bugfix:block-and-comment(tech-failure, reason="ci-watchdog dispatched with no pr_number — autonomous-finishing should have set it")`.
3. cd into `state.worktree_path`. All fix-related git operations run inside the worktree.

## Polling loop

The skill blocks via `bugfix:ticket-adapter:ci_watch`, a single long-running `gh pr checks --watch --fail-fast` invocation. The agent issues it through Bash with `run_in_background: true` so the host's runtime delivers a completion notification when the watch process exits — no idle in-session polling, no dependency on the deferred `Monitor` tool. (Schedule-and-resume mode is still a documented alternative — see "Alternative: schedule-and-resume" at the bottom.)

Algorithm (the agent executes this verbatim):

```
consecutive_adapter_errors = 0
while True:
    # Snapshot first: if CI is already terminal, skip the long-running watch.
    snapshot = bugfix:ticket-adapter:ci_status(state.pr_number)
    if snapshot.error:
        consecutive_adapter_errors += 1
        if consecutive_adapter_errors >= 3:
            block-and-comment(tech-failure, reason="ci_status returned errors on 3 consecutive snapshots", artifacts=[snapshot.error])
            exit
        # Adapter flake: short wait and retry the snapshot via a background-
        # notified Bash sleep so the agent isn't blocked. Bounded by
        # consecutive_adapter_errors (at most 3 of these before block-and-comment).
        Bash(command="sleep 30", run_in_background=true)
        # Wait for the background sleep to complete before re-snapshotting.
        continue
    consecutive_adapter_errors = 0  # successful snapshot resets the counter

    if snapshot.status == "success":
        emit ci_green (detail: {})
        set state.current_stage = "pr-reviewing"
        update state.updated_at = <now>
        exit

    if snapshot.status == "failure":
        result = snapshot  # already terminal; reuse the snapshot
    else:
        # snapshot.status == "pending" — block on ci_watch until terminal or timeout.
        # 120 minutes is the hard ceiling enforced by the adapter's `timeout` wrapper.
        result = bugfix:ticket-adapter:ci_watch(state.pr_number, timeout_minutes=120)
        # ci_watch internally invokes the gh subprocess via Bash with
        # run_in_background: true; the agent is notified when it exits.
        if result.error:
            consecutive_adapter_errors += 1
            if consecutive_adapter_errors >= 3:
                block-and-comment(tech-failure, reason="ci_watch returned errors on 3 consecutive attempts", artifacts=[result.error])
                exit
            continue

    if result.status == "timeout":
        block-and-comment(tech-failure, reason="ci_watch exceeded 120 minutes (2 hours) without a terminal verdict")
        exit

    if result.status == "success":
        emit ci_green (detail: {})
        set state.current_stage = "pr-reviewing"
        update state.updated_at = <now>
        exit

    if result.status == "failure":
        emit ci_failed (detail: {runs: <result.runs>})
        if (state.retries["ci-watching"] or 0) >= config.retry_budgets.ci (default 2):
            block-and-comment(tech-failure, reason="CI failed <N> times", artifacts=[result.failed_logs])
            exit
        dispatch_fix_sub_agent(failed_logs=result.failed_logs)
        emit ci_fix_attempted (detail: {attempt: <N+1>, files_changed: <count>})
        state.retries["ci-watching"] = (state.retries["ci-watching"] or 0) + 1
        update state.updated_at = <now>
        # Loop continues — next iteration takes a snapshot and (if CI is pending
        # again because a new workflow run kicked off after the fix push) blocks
        # in ci_watch again.
        continue
```

Why this is better than the prior 30-poll sleep loop:

- **No idle in-session sleeps.** `ci_watch` is invoked through Bash with `run_in_background: true`; the agent is notified by the host runtime on completion. The agent is free for other work in the interim (in practice, the loop dispatches one ticket at a time, but the notification model removes the cache-cost of 5+ minute sleeps and the "Bash long-sleep blocked" failure mode).
- **No deferred-tool dependency.** Earlier production runs improvised by reaching for the deferred `Monitor` tool, which triggered a ToolSearch step and a permission prompt. `gh pr checks --watch` runs in Bash (already permitted in any bugfix-capable host).
- **Hard ceiling preserved.** `ci_watch`'s 120-minute timeout matches the prior cap (30 polls × max-240s ≈ 2h). The 120-minute value is the v1 default; future increments may surface it as `config.ci_watch_timeout_minutes`.

## On failure: fix sub-agent

When CI reports `failure`, dispatch a fresh sub-agent using `bugfix/skills/_prompts/implementer-prompt.md` (the same template `executing-plan` uses for per-task implementers). DO NOT use `implementer-retry-prompt.md` — CI fixes are not retries of a prior reviewer's verdict; the CI logs ARE the verdict.

Construct the task description for the sub-agent by combining:

- **CI status summary:** which checks failed, by name (`runs[].name` where `conclusion == "failure"`).
- **Failed logs:** the `failed_logs` field returned by `ci_status` (already wrapped where appropriate by the adapter).
- **Recent commit context:** output of `git log -5 --oneline` from inside the worktree.
- **Plan reference:** path to `state.plan_path` for the sub-agent to consult if it needs to understand the surrounding work.
- **Regression-test invariant (conditional on `state.artifacts.regression_test_path`):**
  - **When `state.artifacts.regression_test_path` is non-null** (typical for bug fixes; set by `executing-plan` when the plan's Task 1 declared a regression test file): pass the path AND an explicit instruction: *"This is the regression test for the original bug. It MUST continue to FAIL on `state.base_sha` and PASS on the PR tip. If your CI fix would touch this file at all, STOP and report BLOCKED — weakening or reverting the regression test is never an acceptable CI fix. Find a fix that keeps the regression test green on the tip."* Without this rule, a fix sub-agent could green CI by reverting the regression test undetected.
  - **When `state.artifacts.regression_test_path` is null** (typical for improvement plans that did not include a Task 1 regression test): omit the path-specific invariant and replace it with a softer instruction: *"This PR does not have a designated regression test. Your CI fix MUST NOT weaken existing test coverage — do not delete, skip, or relax assertions in any existing test file to make CI green. If the only way to green CI is to weaken a test, STOP and report BLOCKED."*

The sub-agent's job:

1. Read the logs, identify the root cause.
2. Apply a minimal targeted fix inside the worktree. If `state.artifacts.regression_test_path` is non-null, the fix MUST NOT touch that file — signal BLOCKED if it would. If `state.artifacts.regression_test_path` is null, the fix MUST NOT weaken existing test coverage (no deletions, skips, or relaxed assertions in existing tests) — signal BLOCKED if the only viable path requires weakening coverage.
3. Run the affected tests locally to confirm the fix works AND (when set) the regression test still passes on the tip.
4. Commit with a message starting `fix(ci): <short description>` so the commit history makes the fix attempt visible.
5. Signal `DONE` (or `BLOCKED` / `NEEDS_CONTEXT` if it can't proceed without touching the regression test, weakening coverage, or for any other reason).

After sub-agent reports `DONE`:

- Skill body invokes `bugfix:ticket-adapter:push(state.branch)` to publish the fix.
- If push fails, treat as a fix-attempt failure (do not retry the sub-agent; increment counter and continue the watch loop).

After sub-agent reports `BLOCKED` or `NEEDS_CONTEXT`:

- Skill body does NOT re-dispatch the same sub-agent. The retry counter increments and the loop continues (with the same failed-CI state).

## Retry policy

- Counter location: `state.retries["ci-watching"]` (single integer, starts at 0 or absent → treat as 0).
- Increment ONLY after a fix sub-agent has been dispatched (whether it succeeded or not).
- Budget: read from `config.retry_budgets.ci` (default 2). When the counter reaches the budget AND CI is still failing, exit via `bugfix:block-and-comment(tech-failure)` with the latest failed logs attached.
- Watch timeout: 120 minutes (`ci_watch`'s `timeout_minutes` default). When `ci_watch` returns `status="timeout"`, `block-and-comment(tech-failure, reason="ci_watch exceeded 120 minutes")`.

## State writes

- `state.retries["ci-watching"]`: incremented per fix attempt (read-modify-write).
- `state.updated_at`: refreshed after each snapshot AND after each retry counter bump.
- On `ci_green`: `state.current_stage = "pr-reviewing"`.
- No `state.terminal` or `state.blocked_reason` writes here — those happen via `block-and-comment` on exhaustion.

Each write is a read-modify-write of `.bugfix/runs/<ticket-id>.json`. The single-session driver runs one stage at a time per ticket, so concurrent writers are not expected; the read-modify-write discipline is still good practice for survivability across crashes.

## Events

Emit via `bugfix/lib/events-append.sh ".bugfix/runs/<ticket-id>.events.log" <event> ci-watching '<detail-json>'`:

- `ci_failed` — detail: `{"runs": [<failed run names>]}`. Emitted on the first `failure` observation per watch cycle.
- `ci_fix_attempted` — detail: `{"attempt": <int 1..budget>, "files_changed": <int>}`. After the fix sub-agent's commit lands.
- `ci_green` — detail: `{}`. Once on the transition to `pr-reviewing`.

No `ci_pending` event — pending is the default state and would not surface a notable transition.

## Block-and-comment exits

| Condition | exit_kind | Notes |
|---|---|---|
| `state.pr_number == null` on entry | `tech-failure` | Invariant violation (autonomous-finishing should have set it) |
| `state.retries["ci-watching"] >= config.retry_budgets.ci` AND CI still failing | `tech-failure` | Attach latest `failed_logs` and the per-attempt fix-commit SHAs |
| `ci_watch` returns `status="timeout"` (120 minutes elapsed with no terminal verdict) | `tech-failure` | Operator can resume the ticket; the watchdog re-enters watching |
| `ticket-adapter:ci_status` or `ci_watch` returns `{error: ...}` repeatedly | `tech-failure` | After 3 adapter errors in a row, fail rather than infinite-loop |
| `ticket-adapter:push` returns error after a fix-sub-agent commit | (handled as fix-attempt failure, no block) | Increment retry counter; continue the watch loop |

After block-and-comment, do NOT advance `current_stage`. Exit.

## Next stage

On `ci_green`: write `state.current_stage = "pr-reviewing"`, exit. `bugfix:run-ticket` then dispatches `bugfix:pr-final-review`.

## Alternative: schedule-and-resume

The single-session driver runs `ci_watch` synchronously until terminal verdict or 120-minute timeout. A future enhancement could let the driver release the ticket between snapshots (writing `state.next_poll_at` and exiting), with an external scheduler re-invoking `bugfix:run-ticket` later — but the current single-session model holds the watcher open for the full duration. The `state.next_poll_at` field is not in v1.

## STAGE COMPLETE — STOP HERE

Your work as the `ci-watchdog` stage is done. You MUST stop here. Your next action MUST be to resume the next iteration of `bugfix:run-ticket`'s driver loop (read the state file, check terminal/blocked, let the loop dispatch the next stage). Do NOT:
- Start the next stage's work inline.
- Read files relevant to the next stage.
- Implement / test / push / open PRs beyond this stage's documented operations.

If you continue past this point, you violate the loop contract. The PostToolUse hook will surface a reminder; ignoring it compounds the violation.
