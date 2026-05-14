---
name: pr-final-review
description: Use as the terminal stage of the autonomous bug-fix loop. Rebases the PR on top of base_branch, dispatches a single calibrated reviewer, applies the decision rule, terminates the loop as merge-ready or pr-closed. Dispatched by `bugfix:run-ticket` when `state.current_stage == "pr-reviewing"`.
---

# bugfix:pr-final-review

Terminal stage of the autonomous loop. Rebases the PR on `base_branch`, dispatches a single calibrated reviewer, applies a 3-row decision rule keyed on the reviewer's verdict tier, and produces one of two outcomes: `merge-ready` (terminal) or `pr-closed` (terminal). Tech-failures route to `block-and-comment(tech-failure)`.

**This stage never auto-retries.** PR-level rejections in public are visible flailing; a fix-and-re-review loop on a public PR creates a confusing trail. Outcomes here are final.

## State-file-first context

This skill is invoked by `bugfix:run-ticket` when `state.current_stage == "pr-reviewing"`. Before doing any work:

1. Read `.bugfix/runs/<ticket-id>.json`. Confirm `current_stage == "pr-reviewing"`. If not, exit with an error.
2. Confirm `state.pr_number != null` and `state.base_branch != null` and `state.base_sha != null`. If any is null, exit via `bugfix:block-and-comment(tech-failure, reason="pr-final-review dispatched with missing state fields — upstream stage didn't initialize them")`.
3. cd into `state.worktree_path`. All git operations run inside the worktree.

## Step 1: Rebase

Call `bugfix:ticket-adapter:rebase_pr(state.pr_number, state.base_branch)`. The adapter handles:
- Checks out the PR branch into the worktree — `gh pr checkout <pr_number>` for the gh backend, `git fetch origin pull/<pr_number>/head` (plus a local branch checkout) for the MCP backend; the adapter routes automatically on `state.artifacts.adapter_backend`.
- `git fetch origin <base_branch>` to refresh.
- `git rebase origin/<base_branch>`.
- Conflict detection via `git diff --name-only --diff-filter=U` (catches all unmerged states).
- On clean rebase: `git push --force-with-lease`.

Outcomes:
- `{success: true}` → emit `pr_rebased` event (detail: `{}`); proceed to Step 2.
- `{success: false, conflicts: [...]}` → exit via `bugfix:block-and-comment(tech-failure, reason="cross-ticket conflict on rebase", artifacts=[conflicts])`. The adapter already ran `git rebase --abort` so the worktree is clean. Do NOT attempt auto-resolution.

## Step 2: Gather inputs for the reviewer

Read these into structured variables for substitution into the reviewer prompts:

- **ticket_body:** call `bugfix:ticket-adapter:read(state.issue_number)`; extract `body` (which the adapter has already wrapped in `<untrusted-input>` tags). Do NOT strip the tags.
- **spec_contents:** `cat state.spec_path`.
- **plan_contents:** `cat state.plan_path`.
- **diff:** retrieve the PR diff via the backend-routed path described in "Diff retrieval by adapter backend" below; fall back to `git diff state.base_sha..HEAD` from inside the worktree (post-rebase tip is HEAD) only if the adapter call fails.
- **regression_test_path:** `state.artifacts.regression_test_path` (set by `executing-plan`'s Task 1).
- **regression_test_contents:** `cat <regression_test_path>` (if the path is non-empty).
- **base_sha:** `state.base_sha`.
- **pr_branch:** `state.branch`.
- **ci_summary:** call `bugfix:ticket-adapter:ci_status(state.pr_number)`; expect `{status: "success", runs: [...]}` since `ci-watchdog` already confirmed green. **If `ci_summary.status != "success"`, exit via `bugfix:block-and-comment(tech-failure, reason="CI regressed between ci-watchdog and pr-final-review", artifacts=[ci_summary])` — do NOT proceed to reviewer dispatch.** Otherwise summarize as text for the reviewer prompts.

Emit `pr_review_started` event (detail: `{}`).

### Diff retrieval by adapter backend

Reviewers get the PR diff by calling the right tool for the active backend:

- **When `state.artifacts.adapter_backend == "gh"`:** invoke `gh pr diff <state.pr_number>` via Bash. The output is plain unified diff.
- **When `state.artifacts.adapter_backend == "mcp"`:** call `mcp__github__get_pull_request_files(owner=<state.owner>, repo=<state.repo>, pull_number=<state.pr_number>)` for the file list, then `mcp__github__get_pull_request_diff` (or the canonical MCP server's equivalent) for the unified diff body. Concatenate into the same format as the gh output.

Both paths produce the same input shape for the reviewer prompts. Reviewers SHOULD NOT branch on backend themselves — this skill handles the routing once before dispatching.

### Reviewer prompt branching by classification

The reviewer prompt includes both classification-specific "what to look for" blockquotes below. The reviewer reads `state.artifacts.intake_classification` from the spec and applies the matching block:

**When `intake_classification == "bug"`:**

> Look at the diff and the spec's "Repro steps" / "Expected behavior" / "Actual behavior" sections. Ask:
> - Is the regression test real — does it actually exercise the reported repro and would it FAIL without the fix?
> - Does the fix address the root cause, or just mask the symptom?
> - Are there other code paths that exhibit the same bug that this PR doesn't touch?

**When `intake_classification == "improvement"`:**

> Look at the diff and the spec's "Desired outcome" / "Rationale" / "Out of scope" sections. Ask:
> - Is the change scoped to the agreed outcome, or does it overshoot (out-of-scope refactors)?
> - Is new behavior covered by tests? If not, is the absence of coverage justified?
> - Is the change free of regressions — do existing tests still pass, and are there obvious behaviors the diff might silently change?

## Step 3: Dispatch the reviewer

Invoke a single sub-agent with the prompt template `bugfix/skills/_prompts/pr-final-reviewer-prompt.md`. Substitute `<<<TICKET_BODY>>>`, `<<<SPEC_CONTENTS>>>`, `<<<PLAN_CONTENTS>>>`, `<<<DIFF>>>`, `<<<REGRESSION_TEST_PATH>>>`, `<<<BASE_SHA>>>`, `<<<PR_BRANCH>>>`, `<<<CI_SUMMARY>>>` with the values gathered in Step 2.

If `config.pr_review.reviewer_must_run_regression_test == false`, instruct the sub-agent (via an additional line appended to the substituted prompt) to skip the empirical regression-test check. The reviewer's prompt already documents that opting out is acceptable and is not a finding. Default: `true` (the reviewer runs the test on both base and PR tip via `git checkout <<<BASE_SHA>>>` then `git checkout <<<PR_BRANCH>>>`; the test must FAIL on base and PASS on PR tip).

Wait for the verdict. Store the full reviewer output at `state.artifacts.review_verdict` as a JSON-stringified text blob.

If the sub-agent dispatch itself fails (host error, timeout, no output), exit via `bugfix:block-and-comment(tech-failure, reason="reviewer dispatch failed", artifacts=[<host error>])`. Do NOT proceed to Step 4 without a verdict.

## Step 4: Apply decision rule

Parse the first non-header line of the reviewer's `## Verdict` section. It matches exactly one of three forms: `Critical findings: [...]`, `Important findings: [...]`, or `clean`. Apply this table:

| Reviewer verdict | Action |
|---|---|
| `clean` | Terminal: `merge-ready`. |
| `important` (no `critical`) | If `config.pr_review.important_findings_block == true`: close PR + `block-and-comment(rejected)` with reason "important findings promoted to blocking via `important_findings_block` config." Else: Terminal: `merge-ready`, with each important finding posted as a separate PR comment after the main merge-ready comment. |
| `critical` | Close PR via `ticket-adapter:pr_close`; `block-and-comment(rejected)` with the reviewer's critical findings verbatim as the close reason. |

There is no `needs-info` terminal action from this stage — that path was driven by inter-reviewer disagreement and is removed with the single-reviewer design. Tech-failure exits in Step 1 (rebase conflict), Step 2 (CI regression), and Step 3 (dispatch failure) are unchanged and route to `block-and-comment(tech-failure)`.

## Step 5: Apply terminal action

Two branches only.

### Branch A: `merge-ready`

Taken when the verdict is `clean`, or `important` with `important_findings_block=false`.

**Order matters here.** `set_status("ready-for-merge")` runs FIRST so a label-missing failure is surfaced before any state mutations or public PR comments. If `set_status` fails, the ticket has no merge-ready signal posted anywhere — operator fixes the label and the loop can re-enter cleanly.

1. Call `bugfix:ticket-adapter:set_status(state.issue_number, "ready-for-merge")`. If `set_status` returns "label not found", exit via `bugfix:block-and-comment(tech-failure, reason="bugfix-status:ready-for-merge label missing — run first-run setup")`. Do NOT proceed; do NOT set `state.terminal` yet; do NOT post PR comments.
2. Set `state.terminal = "merge-ready"`.
3. Set `state.artifacts.review_verdict = <reviewer output text>`.
4. Set `state.updated_at = <now>`.
5. Call `bugfix:ticket-adapter:pr_comment(state.pr_number, <merge-ready comment>)`. Comment template:
   ```
   bugfix loop reached `merge-ready` for this PR.

   Reviewer verdict: <clean | important>
   <reviewer summary>

   CI: green (per ci-watchdog)
   Regression test: <state.artifacts.regression_test_path>

   Manual merge action required: review the diff, merge if appropriate. The bugfix loop will NOT auto-merge.
   ```

   **Conditional regression-test paragraph.** The `Regression test: <state.artifacts.regression_test_path>` line in the template above is rendered ONLY when `state.artifacts.regression_test_path` is non-null. When `regression_test_path` is null (improvement-class tickets without a regression test, per `bugfix:executing-plan`'s "Classification-aware Task 1 marker handling"), omit the paragraph entirely — do NOT render with `null` (or any other unrendered placeholder text) in the public PR comment. The other lines of the template are unaffected.
6. If the verdict is `important`: post each important finding as a SEPARATE PR comment via additional `pr_comment` calls, so the human reviewer sees them as discrete review items.
7. Call `bugfix:ticket-adapter:ticket_comment(state.issue_number, <ticket merge-ready comment>)`. Template:
   ```
   bugfix loop reached `merge-ready` for PR #<state.pr_number> (<pr_url>).

   The loop completed successfully through CI watching and final review. Please review and merge manually.
   ```

   The ticket merge-ready comment template above does not reference `regression_test_path`, so the same conditional rule has no effect here. If a future revision adds a `Regression test: ...` line to this ticket template, the same rule applies: rendered ONLY when `state.artifacts.regression_test_path` is non-null; otherwise omit the paragraph entirely.
8. Emit `pr_merge_ready` event (detail: `{verdict: "clean" | "important"}`).
9. Exit.

### Branch B: `pr-closed`

Taken when the verdict is `critical`, or `important` with `important_findings_block=true` (the knob promotes the verdict to blocking).

**Order matters here too.** The `pr_closed` event must land in the JSONL log BEFORE the `block_and_comment` event so the timeline reads close-then-block. Sequence:

1. Set `state.terminal = "pr-closed"`.
2. Set `state.artifacts.review_verdict = <reviewer output text>`.
3. Set `state.updated_at = <now>`.
4. Call `bugfix:ticket-adapter:pr_close(state.pr_number, <close reason>)`. The close reason text differs between the two triggers:
   - **critical:** reviewer's critical findings verbatim.
   - **important-promoted:** "important findings promoted to blocking via `important_findings_block` config", followed by the reviewer's important findings verbatim.

   The adapter posts the reason as a PR comment via `pr_comment --body-file -` then closes (per ticket-adapter §5.8 two-step).
5. Emit `pr_closed` event with detail `{critical_findings: <count>, important_promoted: <bool>}`:
   - For the critical path: `{critical_findings: <count from reviewer output>, important_promoted: false}`.
   - For the important-promoted path: `{critical_findings: 0, important_promoted: true}`.

   This emission must precede the next step — the JSONL events log must show `pr_closed` preceding `block_and_comment`.
6. Invoke `bugfix:block-and-comment(rejected, reason=<short reason matching the close reason above>, questions=[], artifacts=[{label: "review_verdict", path: "(inline)"}])`.
   - `block-and-comment` will:
     - Persist `state.blocked_reason` etc.
     - Call `ticket_comment` with its template (which references the reviewer's findings).
     - Call `set_status(state.issue_number, "rejected")`.
     - Emit `block_and_comment` event.
7. Exit.

## Configuration knobs

All read from `.bugfix/runs/config.json`'s `pr_review` section. Defaults if absent:

- `important_findings_block` (default `false`): when `true`, important-but-not-critical findings are treated as critical (close the PR instead of rendering them as PR comments on a merge-ready outcome).
- `reviewer_must_run_regression_test` (default `true`): when `false`, the reviewer skips the empirical base/PR-tip regression-test check (the dispatching skill appends a "skip empirical check" instruction to the substituted prompt). Useful for hosts without an executable test environment.

These are declared in `bugfix/schemas/config.schema.json` under `pr_review.*`.

## State writes

- `state.terminal = "merge-ready"` or `"pr-closed"` (terminal branches).
- `state.artifacts.review_verdict = <text>`.
- `state.updated_at = <now>`.
- `state.blocked_reason` and `state.blocked_questions` written by `block-and-comment` (Branch B, when invoked).
- No `current_stage` advance — this stage is terminal.

All writes are read-modify-write of `.bugfix/runs/<ticket-id>.json`.

## Events

Emit via `bugfix/lib/events-append.sh ".bugfix/runs/<ticket-id>.events.log" <event> pr-reviewing '<detail-json>'`:

- `pr_rebased` (detail: `{}`) — after successful rebase, before Step 2.
- `pr_review_started` (detail: `{}`) — at the start of Step 3.
- `pr_merge_ready` (detail: `{verdict: <"clean" | "important">}`) — terminal merge-ready outcome.
- `pr_closed` (detail: `{critical_findings: <count>, important_promoted: <bool>}`) — terminal pr-closed outcome, emitted BEFORE block-and-comment's `block_and_comment` event.

The needs-info path (which previously fired on inter-reviewer disagreement) is removed in this design. Tech-failures emit `block_and_comment` from the `block-and-comment` skill body.

## Block-and-comment exits

| Condition | exit_kind | Notes |
|---|---|---|
| `state.pr_number` or `base_branch` or `base_sha` null on entry | `tech-failure` | Upstream stage didn't initialize state |
| `ticket-adapter:rebase_pr` returns `{success: false, conflicts: [...]}` | `tech-failure` | Cross-ticket conflict; do NOT auto-resolve |
| `ticket-adapter:ci_status` returns `failure` or `pending` (unexpected since ci-watchdog passed) | `tech-failure` | CI regressed between ci-watchdog and pr-final-review |
| Reviewer sub-agent dispatch fails | `tech-failure` | Cannot proceed without a verdict |
| Decision rule: verdict is `critical` | `rejected` | Close PR; this is a normal terminal outcome, not a tech failure |
| Decision rule: verdict is `important` AND `important_findings_block == true` | `rejected` | Important findings promoted to blocking by config |
| `set_status("ready-for-merge")` returns "label not found" | `tech-failure` | Operator must run first-run setup for the new label |

There is no `needs-info` exit from this stage. **No auto-retry on any of these.** PR-level decisions are final.

## Next stage

None. `pr-final-review` is the terminal stage. After this skill exits, `state.terminal` is set (or `state.blocked_reason` is set on a block). `bugfix:run-ticket`'s driver loop reads the state file on its next iteration, sees the terminal/blocked field, and exits cleanly.

## STAGE COMPLETE — STOP HERE

Your work as the `pr-final-review` stage is done. You MUST stop here. Your next action MUST be to resume the next iteration of `bugfix:run-ticket`'s driver loop (read the state file, check terminal/blocked, let the loop dispatch the next stage). Do NOT:
- Start the next stage's work inline.
- Read files relevant to the next stage.
- Implement / test / push / open PRs beyond this stage's documented operations.

If you continue past this point, you violate the loop contract. The PostToolUse hook will surface a reminder; ignoring it compounds the violation.
