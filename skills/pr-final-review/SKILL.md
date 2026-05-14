---
name: pr-final-review
description: Use as the terminal stage of the autonomous bug-fix loop. Rebases the PR on top of base_branch, dispatches advocate + adversary reviewers in parallel, applies the decision rule, terminates the loop as merge-ready, pr-closed, or blocks for human resolution. Dispatched by `bugfix:run-ticket` when `state.current_stage == "pr-reviewing"`.
---

# bugfix:pr-final-review

Terminal stage of the autonomous loop. Rebases the PR on `base_branch`, dispatches an advocate and an adversary reviewer in parallel, applies a 6-row decision rule, and produces one of three outcomes: `merge-ready` (terminal), `pr-closed` (terminal), or `block-and-comment(needs-info)` (human resolves).

**This stage never auto-retries.** PR-level rejections in public are visible flailing; a fix-and-re-review loop on a public PR creates a confusing trail. Outcomes here are final-or-blocked.

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

## Step 2: Gather inputs for reviewers

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

Emit `pr_review_started` event (detail: `{adversary_enabled: <bool>}`).

### Diff retrieval by adapter backend

Reviewers get the PR diff by calling the right tool for the active backend:

- **When `state.artifacts.adapter_backend == "gh"`:** invoke `gh pr diff <state.pr_number>` via Bash. The output is plain unified diff.
- **When `state.artifacts.adapter_backend == "mcp"`:** call `mcp__github__get_pull_request_files(owner=<state.owner>, repo=<state.repo>, pull_number=<state.pr_number>)` for the file list, then `mcp__github__get_pull_request_diff` (or the canonical MCP server's equivalent) for the unified diff body. Concatenate into the same format as the gh output.

Both paths produce the same input shape for the reviewer prompts. Reviewers SHOULD NOT branch on backend themselves — this skill handles the routing once before dispatching.

### Reviewer prompt branching by classification

Both the advocate and adversary reviewer prompts include a classification-specific "what to look for" section. Read `state.artifacts.intake_classification` and use the matching block:

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

The advocate and adversary use the same branching block; the difference between the two reviewers is their stance (advocate: probable PASS, looks for "is this defensible?"; adversary: probable FAIL, looks for "what would make me close this?").

## Step 3: Dispatch advocate + adversary in parallel

Use the vendored `bugfix:dispatching-parallel-agents` skill to dispatch both reviewers concurrently.

**Advocate:**
- Prompt: `bugfix/skills/_prompts/pr-final-reviewer-advocate-prompt.md`.
- Substitute `<<<TICKET_BODY>>>`, `<<<SPEC_CONTENTS>>>`, `<<<PLAN_CONTENTS>>>`, `<<<DIFF>>>`, `<<<REGRESSION_TEST_PATH>>>`, `<<<BASE_SHA>>>`, `<<<PR_BRANCH>>>`, `<<<CI_SUMMARY>>>` with the gathered values.
- If `config.pr_review.advocate_must_run_regression_test` is `false` (operator override), the prompt's regression-test verification clause is moot but the advocate runs anyway; it will skip the empirical check if the config says so. Default: `true` (advocate runs the test both ways).

**Adversary:**
- Prompt: `bugfix/skills/_prompts/pr-final-reviewer-adversary-prompt.md`.
- Same substitutions.
- **Skip the adversary entirely if `config.pr_review.adversary_enabled == false`.** In that case, dispatch ONLY the advocate. For decision-rule purposes, treat adversary verdict as `clean`.

Wait for both verdicts (or only advocate's if adversary disabled). Store at `state.artifacts.advocate_verdict` and `state.artifacts.adversary_verdict` (as JSON-stringified text, or `null` for skipped adversary).

## Step 4: Apply decision rule

Apply the 6-row table verbatim. Rows are checked top-to-bottom; first match wins.

| Advocate | Adversary | Action |
|---|---|---|
| `Ready: yes` | `clean` | Terminal: `merge-ready`. |
| `Ready: conditional` | `clean` | Terminal: `merge-ready` with advocate's conditional concerns posted as a separate PR comment for the human reviewer. |
| `Ready: yes`/`conditional` | `important` (no `critical`) | If `config.pr_review.important_findings_block == true`: treat as `critical` → close + block. Else: Terminal: `merge-ready` with advocate's concerns (if any) AND adversary's important findings posted as separate PR comments. |
| any | `critical`, advocate **explicitly counters** | Close PR via `ticket-adapter:pr_close`; `block-and-comment(rejected)`. (Both reviewers agree something is fundamentally wrong: the adversary found it and the advocate, having seen the same diff, did not push back.) |
| `Ready: yes`/`conditional` | `critical`, advocate **disputes or silent** | `block-and-comment(needs-info)` with both verdicts. PR stays open. Human decides. |
| `Ready: no` | any | `block-and-comment(needs-info)` with advocate's "no" reasoning. PR stays open. |

**"Advocate explicitly counters" determination:** the advocate text must contain an explicit acknowledgment of the adversary's specific `critical` findings AND an argument that those findings are valid blockers. **Silence on those findings is NOT consent** — under parallel dispatch the advocate writes its verdict without seeing the adversary's, so silence is uninformative. Default behavior when the advocate text does not address the adversary's findings: route to `block-and-comment(needs-info)` (row 5), not auto-close (row 4). The "explicitly counters" branch fires only when the advocate's text directly engages with the adversary's findings and confirms them as blockers. This is the conservative reading: auto-close is restricted to the rare case of explicit advocate-side confirmation; everything else asks a human.

## Step 5: Apply terminal action

### Branch A: `merge-ready`

**Order matters here.** `set_status("ready-for-merge")` runs FIRST so a label-missing failure is surfaced before any state mutations or public PR comments. If `set_status` fails, the ticket has no merge-ready signal posted anywhere — operator fixes the label and the loop can re-enter cleanly.

1. Call `bugfix:ticket-adapter:set_status(state.issue_number, "ready-for-merge")`. If `set_status` returns "label not found", exit via `bugfix:block-and-comment(tech-failure, reason="bugfix-status:ready-for-merge label missing — run first-run setup")`. Do NOT proceed; do NOT set `state.terminal` yet; do NOT post PR comments.
2. Set `state.terminal = "merge-ready"`.
3. Set `state.artifacts.advocate_verdict = <advocate output text>`.
4. Set `state.artifacts.adversary_verdict = <adversary output text, or "skipped" if disabled>`.
5. Set `state.updated_at = <now>`.
6. Call `bugfix:ticket-adapter:pr_comment(state.pr_number, <merge-ready comment>)`. Comment template:
   ```
   bugfix loop reached `merge-ready` for this PR.

   Advocate verdict: <Ready: yes | conditional>
   <advocate reasoning summary>

   Adversary verdict: <clean | important>
   <adversary summary if non-clean>

   CI: green (per ci-watchdog)
   Regression test: <state.artifacts.regression_test_path>

   Manual merge action required: review the diff, merge if appropriate. The bugfix loop will NOT auto-merge.
   ```

   **Conditional regression-test paragraph.** The `Regression test: <state.artifacts.regression_test_path>` line in the template above is rendered ONLY when `state.artifacts.regression_test_path` is non-null. When `regression_test_path` is null (improvement-class tickets without a regression test, per `bugfix:executing-plan`'s "Classification-aware Task 1 marker handling"), omit the paragraph entirely — do NOT render with `null` (or any other unrendered placeholder text) in the public PR comment. The other lines of the template are unaffected.
7. If advocate was `conditional` OR adversary returned `important` findings: post each set of concerns as a SEPARATE PR comment via additional `pr_comment` calls, so the human reviewer sees them as discrete review items.
8. Call `bugfix:ticket-adapter:ticket_comment(state.issue_number, <ticket merge-ready comment>)`. Template:
   ```
   bugfix loop reached `merge-ready` for PR #<state.pr_number> (<pr_url>).

   The loop completed successfully through CI watching and final review. Please review and merge manually.
   ```

   The ticket merge-ready comment template above does not reference `regression_test_path`, so the same conditional rule has no effect here. If a future revision adds a `Regression test: ...` line to this ticket template, the same rule applies: rendered ONLY when `state.artifacts.regression_test_path` is non-null; otherwise omit the paragraph entirely.
9. Emit `pr_merge_ready` event (detail: `{advocate: "yes/conditional", adversary: "clean/important"}`).
10. Exit.

### Branch B: `pr-closed`

**Order matters here too.** The `pr_closed` event must land in the JSONL log BEFORE the `block_and_comment` event so the timeline reads close-then-block. Sequence:

1. Set `state.terminal = "pr-closed"`.
2. Set verdict artifacts.
3. Set `state.updated_at = <now>`.
4. Call `bugfix:ticket-adapter:pr_close(state.pr_number, <close reason from adversary's critical findings>)`. The adapter posts the reason as a PR comment via `pr_comment --body-file -` then closes (per ticket-adapter §5.8 two-step).
5. Emit `pr_closed` event (detail: `{advocate: "...", adversary_critical: <count>}`) BEFORE the next step — the JSONL events log must show pr_closed preceding block_and_comment.
6. Invoke `bugfix:block-and-comment(rejected, reason="adversary identified critical issues; advocate agreed (or silent)", questions=[], artifacts=[{label: "advocate_verdict", path: "(inline)"}, {label: "adversary_verdict", path: "(inline)"}])`.
   - `block-and-comment` will:
     - Persist `state.blocked_reason` etc.
     - Call `ticket_comment` with its template (which references the adversary's critical findings).
     - Call `set_status(state.issue_number, "rejected")`.
     - Emit `block_and_comment` event.
7. Exit.

### Branch C: `block` (any blocking decision-rule path)

1. Set `state.artifacts.advocate_verdict` and `state.artifacts.adversary_verdict`.
2. Set `state.updated_at = <now>`.
3. Emit `pr_review_blocked` event (detail: `{reason: <short>, advocate: <verdict>, adversary: <verdict>}`).
4. Invoke `bugfix:block-and-comment(needs-info, reason=<short>, questions=[<both verdicts, formatted>], artifacts=[{label: "advocate_verdict", path: "(inline)"}, {label: "adversary_verdict", path: "(inline)"}])`.
   - `block-and-comment` handles the ticket comment and status set to `needs-info`.
5. Exit.

## Configuration knobs

All read from `.bugfix/runs/config.json`'s `pr_review` section. Defaults if absent:

- `adversary_enabled` (default `true`): when `false`, only the advocate runs; adversary verdict treated as `clean`.
- `important_findings_block` (default `false`): when `true`, important-but-not-critical adversary findings are treated as critical (block).
- `advocate_must_run_regression_test` (default `true`): when `false`, advocate skips the regression-test empirical verification (prompt instructs accordingly). Useful for hosts without an executable test environment.

These are declared in `bugfix/schemas/config.schema.json` under `pr_review.*`.

## State writes

- `state.terminal = "merge-ready"` or `"pr-closed"` (terminal branches).
- `state.artifacts.advocate_verdict = <text>`.
- `state.artifacts.adversary_verdict = <text or null>`.
- `state.updated_at = <now>`.
- `state.blocked_reason` and `state.blocked_questions` written by `block-and-comment` (Branch C).
- No `current_stage` advance — this stage is terminal.

All writes are read-modify-write of `.bugfix/runs/<ticket-id>.json`.

## Events

Emit via `bugfix/lib/events-append.sh ".bugfix/runs/<ticket-id>.events.log" <event> pr-reviewing '<detail-json>'`:

- `pr_rebased` (detail: `{}`) — after successful rebase, before Step 2.
- `pr_review_started` (detail: `{adversary_enabled: <bool>}`) — at the start of Step 3.
- `pr_merge_ready` (detail: `{advocate: <verdict>, adversary: <verdict>}`) — terminal merge-ready outcome.
- `pr_closed` (detail: `{advocate: <verdict>, adversary_critical: <count>}`) — terminal pr-closed outcome, emitted BEFORE block-and-comment's `block_and_comment` event.
- `pr_review_blocked` (detail: `{reason: <short>, advocate: <verdict>, adversary: <verdict>}`) — block-for-human-input outcome, emitted BEFORE block-and-comment's `block_and_comment` event.

## Block-and-comment exits

| Condition | exit_kind | Notes |
|---|---|---|
| `state.pr_number` or `base_branch` or `base_sha` null on entry | `tech-failure` | Upstream stage didn't initialize state |
| `ticket-adapter:rebase_pr` returns `{success: false, conflicts: [...]}` | `tech-failure` | Cross-ticket conflict; do NOT auto-resolve |
| `ticket-adapter:ci_status` returns `failure` or `pending` (unexpected since ci-watchdog passed) | `tech-failure` | CI regressed between ci-watchdog and pr-final-review |
| Either reviewer sub-agent dispatch fails | `tech-failure` | Cannot proceed without verdicts |
| Decision rule: row 4 (any + critical + advocate agrees) | `rejected` | Close PR; this is a normal terminal outcome, not a tech failure |
| Decision rule: row 5 or 6 (disputes or Ready:no) | `needs-info` | Human resolves disagreement |
| `set_status("ready-for-merge")` returns "label not found" | `tech-failure` | Operator must run first-run setup for the new label |

**No auto-retry on any of these.** PR-level decisions are final.

## Next stage

None. `pr-final-review` is the terminal stage. After this skill exits, `state.terminal` is set (or `state.blocked_reason` is set on a block). `bugfix:run-ticket`'s driver loop reads the state file on its next iteration, sees the terminal/blocked field, and exits cleanly.

## STAGE COMPLETE — STOP HERE

Your work as the `pr-final-review` stage is done. You MUST stop here. Your next action MUST be to return control to `bugfix:run-ticket`'s driver loop. Do NOT:
- Start the next stage's work inline.
- Read files relevant to the next stage.
- Implement / test / push / open PRs beyond this stage's documented operations.

If you continue past this point, you violate the loop contract. The PostToolUse hook will surface a reminder; ignoring it compounds the violation.
