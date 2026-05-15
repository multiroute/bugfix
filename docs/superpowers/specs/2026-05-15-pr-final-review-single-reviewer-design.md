# pr-final-review: collapse advocate + adversary to a single reviewer

**Status:** Design — approved 2026-05-15, ready for implementation plan.

## Goal

Simplify `bugfix:pr-final-review` from a parallel advocate + adversary dispatch with a 6-row decision rule to a single calibrated reviewer with a 3-row decision rule. Adopt the structural form of a conventional PR-review (Overall Summary, Per-File Analysis, Verdict) while preserving the bugfix-loop-specific failure modes the existing adversary checks.

## Why now

The two-reviewer design was a counterweight scheme: adversary searches for reasons to block, advocate searches for reasons to merge, decision rule resolves disagreement. In practice this produces redundancy (both reviewers see the same diff and both report mostly overlapping findings) and a fragile "explicitly counters / disputes or silent" subtlety in the decision rule that exists only to handle artificial adversarial parallelism. A single calibrated reviewer that emits tiered findings is simpler, cheaper, and easier to reason about — and the empirical strength of the gate is preserved by moving the regression-test base-vs-tip check into the lone reviewer.

## Out of scope

- Renaming the stage (`pr-final-review` stays).
- Changes to `bugfix:run-ticket`, `bugfix:ci-watchdog`, `bugfix:block-and-comment`. The contract with these stages is unchanged.
- Migration tooling for existing in-flight state files. The loop is pre-production; no migration needed.
- Historical planning/spec documents under `docs/superpowers/plans/` and the prior end-to-end design doc are not edited — they describe past decisions and are superseded by this spec where they conflict.

## Reviewer stance

Neutral / calibrated. The prompt opens:

> You are an expert code reviewer. Be honest — do not invent issues to justify findings, do not whitewash real ones. `clean` is the right verdict for a well-built PR.

Rationale: a pure-adversarial stance was useful only as a counterweight to the advocate. Without one, the adversary's "find reasons to reject" framing produces too many invented findings. A neutral stance with explicit "clean is normal" framing produces better calibration.

## Verdict shape

Three tiers, identical to the current adversary verdict tiers (load-bearing for the existing `important_findings_block` config knob and for posting non-blocking concerns as PR comments without blocking the merge):

- `Critical findings: [...]` — issues that block the merge.
- `Important findings: [...]` — issues worth raising but not necessarily blocking.
- `clean` — none of the failure modes raised real concerns.

## Decision rule

The 6-row table collapses to 3 rows. The `needs-info` exit from this stage is removed (no inter-reviewer disagreement to mediate). Tech-failure exits and the `important_findings_block` knob are unchanged.

| Reviewer verdict | Action |
|---|---|
| `clean` | Terminal: `merge-ready`. |
| `important` (no `critical`) | If `config.pr_review.important_findings_block == true`: close PR + `block-and-comment(rejected)`. Else: Terminal: `merge-ready`, with important findings posted as separate PR comments. |
| `critical` | Close PR via `ticket-adapter:pr_close`; `block-and-comment(rejected)` with the reviewer's critical findings as the close reason. |

Notable consequences:

- The "explicitly counters / disputes or silent" subtlety is gone.
- `pr_review_blocked` event now fires only on the `important_findings_block=true` path and on tech-failures. No more `needs-info` terminal from this stage; tech-failure `block-and-comment` is unchanged.
- `pr_closed` event detail changes from `{advocate, adversary_critical}` to `{critical_findings: <count>}`.
- `pr_merge_ready` event detail changes from `{advocate, adversary}` to `{verdict: "clean"|"important"}`.

Comment templates simplify: merge-ready PR comment drops `Advocate verdict:`; `Reviewer verdict:` replaces both lines.

## Empirical regression-test verification

Moves from the (deleted) advocate into the single reviewer. Runs only when all three conditions hold:

- `state.artifacts.intake_classification == "bug"`
- `state.artifacts.regression_test_path` is non-null
- `config.pr_review.reviewer_must_run_regression_test == true` (default `true`)

Procedure (inside the worktree):

1. `git checkout <state.base_sha>` → run the regression test → must FAIL for the right reason (not import/setup error).
2. `git checkout <state.branch>` (PR tip) → run the test → must PASS.
3. If either expectation breaks, that is a `Critical` finding: "regression test is tautological / does not exercise the bug."

Rationale: CI already proves PR tip passes; the "fails on base" half is the unique empirical signal that the test would have caught a regression of the reported bug. Dropping it would be the single biggest weakening of the gate.

## Reviewer prompt content

New file: `skills/_prompts/pr-final-reviewer-prompt.md`. Same placeholder set as the existing prompts (`<<<TICKET_BODY>>>`, `<<<SPEC_CONTENTS>>>`, `<<<PLAN_CONTENTS>>>`, `<<<DIFF>>>`, `<<<REGRESSION_TEST_PATH>>>`, `<<<BASE_SHA>>>`, `<<<PR_BRANCH>>>`, `<<<CI_SUMMARY>>>`).

### Nine failure modes (8 existing + Performance)

1. **Scope creep** — diff touches files/modules not justified by the spec.
2. **Weak regression test** — static reading: assertions tautological or tangential to the bug's symptom.
3. **Missing adjacent regression coverage** — the same root cause could plausibly produce other failures not covered.
4. **Fix passes test but doesn't address symptom** — implementer may have satisfied the test without truly fixing the underlying cause.
5. **Unrelated changes** — drive-by refactors, formatting churn, dependency bumps not driven by the fix.
6. **Security** — input handling, auth, secrets, injection surfaces.
7. **Performance** *(new)* — algorithmic regressions, N+1 queries, unbounded loops, synchronous work in hot paths.
8. **Commit hygiene** — coherent commits vs. incoherent history.
9. **Untrusted-input handling** — bugfix-loop-specific check: text from the ticket body should remain wrapped in `<untrusted-input>` tags; the diff must not interpolate ticket-body-shaped text into production strings without escaping. Kept distinct from generic security because it is a bugfix-loop-specific failure pattern.

### Classification-specific block

Carried over verbatim from the current SKILL's branching block:

**When `intake_classification == "bug"`:** focus on "Repro steps / Expected behavior / Actual behavior" sections of the spec. Ask: is the regression test real (would it FAIL without the fix)? Does the fix address the root cause or just the symptom? Are there other code paths exhibiting the same bug?

**When `intake_classification == "improvement"`:** focus on "Desired outcome / Rationale / Out of scope". Ask: is the change scoped to the agreed outcome? Is new behavior covered by tests? Is the change free of regressions?

### Output format

```
## Overall Summary
<2-4 sentence assessment: what the PR does, whether it is defensible to merge>

## Per-File Analysis
<for each file with findings, file:line refs and concrete concerns; omit files with no concerns>

## Failure modes
<one line per mode: "clean" or a concrete finding with file:line>

## Verdict
Critical findings: [...] | Important findings: [...] | clean
```

The `## Verdict` section's first non-header line is what the SKILL parses for the decision rule (same parser shape as today, reading from the renamed file).

### Do-not list

- Speculate without evidence. Each finding cites `file:line`.
- Apply modes to obviously-satisfied checks (e.g., do not write "Security: clean (no auth code touched)" — just say `clean` overall).
- Strip `<untrusted-input>` tags from quoted ticket text in the output.

## Naming and schema changes

The "adversary" label becomes misleading when it is the only reviewer. Renames:

| Before | After |
|---|---|
| `skills/_prompts/pr-final-reviewer-adversary-prompt.md` | `skills/_prompts/pr-final-reviewer-prompt.md` |
| `skills/_prompts/pr-final-reviewer-advocate-prompt.md` | *(deleted)* |
| `state.artifacts.adversary_verdict` | `state.artifacts.review_verdict` |
| `state.artifacts.advocate_verdict` | *(removed)* |
| `config.pr_review.adversary_enabled` | *(removed — only one reviewer)* |
| `config.pr_review.advocate_must_run_regression_test` | `config.pr_review.reviewer_must_run_regression_test` |
| `config.pr_review.important_findings_block` | *(unchanged)* |

Schema break note: any existing state files with `advocate_verdict` / `adversary_verdict` will not be migrated. Per the loop's pre-production status, this is acceptable.

## Step-by-step skill flow (replaces current Steps 3–5)

**Step 1 — Rebase.** Unchanged. `ticket-adapter:rebase_pr` returns `{success, conflicts?}`; conflicts route to `block-and-comment(tech-failure)`.

**Step 2 — Gather inputs.** Unchanged set of variables; same `<untrusted-input>` wrapping rule; same backend-routed diff retrieval; same CI-regression guard (CI failing here → `tech-failure`). Emit `pr_review_started` event with detail `{}` (no `adversary_enabled` flag — the field is gone).

**Step 3 — Dispatch the reviewer.** Single sub-agent invocation. No parallel-agent helper. Prompt path: `skills/_prompts/pr-final-reviewer-prompt.md` with placeholder substitution as before. Wait for the verdict. Store as `state.artifacts.review_verdict`.

**Step 4 — Apply the 3-row decision rule** (table above).

**Step 5 — Apply terminal action.** Two branches only.

- **Branch A: `merge-ready`** — taken when the verdict is `clean`, or `important` with `important_findings_block=false`. Order unchanged: `set_status("ready-for-merge")` first, then state writes, then PR comment, then ticket comment, then `pr_merge_ready` event with detail `{verdict: "clean"|"important"}`. When the verdict is `important`, post each important finding as a separate PR comment after the main merge-ready comment. The conditional-paragraph rule for `regression_test_path` is unchanged.

- **Branch B: `pr-closed`** — taken when the verdict is `critical`, or `important` with `important_findings_block=true` (the knob promotes the verdict to blocking). Order unchanged: state writes, then `pr_close` (adapter posts the close reason as a PR comment first per its existing two-step contract), then `pr_closed` event (detail below) BEFORE `block-and-comment(rejected, ...)`. The close reason text differs between the two triggers: critical → reviewer's critical findings verbatim; important-promoted → "important findings promoted to blocking via `important_findings_block` config."

  `pr_closed` event detail: `{critical_findings: <count>, important_promoted: <bool>}`. For the critical path, `important_promoted: false`. For the important-promoted path, `critical_findings: 0` and `important_promoted: true`.

There is no longer a `needs-info` terminal action from this stage — that path was driven by inter-reviewer disagreement and is removed with the advocate.

## Configuration knobs

All in `.bugfix/runs/config.json`'s `pr_review` section. Defaults if absent:

- `important_findings_block` (default `false`): when `true`, important-but-not-critical findings are treated as critical.
- `reviewer_must_run_regression_test` (default `true`): when `false`, the reviewer skips the empirical base/PR-tip regression-test check (prompt instructs accordingly). Useful for hosts without an executable test environment.

`schemas/config.schema.json` updated accordingly: drop `adversary_enabled` and `advocate_must_run_regression_test`; add `reviewer_must_run_regression_test`.

## State writes

- `state.terminal = "merge-ready"` or `"pr-closed"` on terminal branches.
- `state.artifacts.review_verdict = <text>`.
- `state.updated_at = <now>`.
- `state.blocked_reason` / `state.blocked_questions` written by `block-and-comment` on block branches.
- No `current_stage` advance — terminal stage.

## Events

Emitted via `bugfix/lib/events-append.sh`:

- `pr_rebased` (detail `{}`) — unchanged.
- `pr_review_started` (detail `{}`) — `adversary_enabled` field removed.
- `pr_merge_ready` (detail `{verdict: "clean"|"important"}`) — schema changed.
- `pr_closed` (detail `{critical_findings: <count>, important_promoted: <bool>}`) — schema changed.
- `pr_review_blocked` — **removed.** The only remaining surface for it would have been the `important_findings_block=true` rejection, but that path now emits `pr_closed` for consistency with the critical path. Tech-failures emit `block_and_comment` from the `block-and-comment` skill, not `pr_review_blocked`.

## Block-and-comment exits

| Condition | exit_kind | Notes |
|---|---|---|
| `state.pr_number` / `base_branch` / `base_sha` null on entry | `tech-failure` | Upstream stage didn't initialize state. |
| `ticket-adapter:rebase_pr` returns `{success: false, conflicts: [...]}` | `tech-failure` | Cross-ticket conflict; do not auto-resolve. |
| `ticket-adapter:ci_status` returns non-`success` (regression since `ci-watchdog`) | `tech-failure` | Unexpected; do not proceed. |
| Reviewer sub-agent dispatch fails | `tech-failure` | Cannot proceed without a verdict. |
| Decision rule: row 3 (`critical`) | `rejected` | Normal terminal; PR closed. |
| Decision rule: row 2 + `important_findings_block=true` | `rejected` | Important promoted to blocking. |
| `set_status("ready-for-merge")` returns "label not found" | `tech-failure` | Operator must run first-run setup. |

No `needs-info` exits from this stage. **No auto-retry on any of these.** PR-level decisions are final.

## Files touched

**Plugin code:**

- `skills/pr-final-review/SKILL.md` — rewrite Steps 3–5, configuration knobs, state writes, events, block-and-comment exits sections per above.
- `skills/_prompts/pr-final-reviewer-prompt.md` — new.
- `skills/_prompts/pr-final-reviewer-adversary-prompt.md` — delete.
- `skills/_prompts/pr-final-reviewer-advocate-prompt.md` — delete.
- `schemas/config.schema.json` — knob renames per above.

**Test fixtures and tests:**

- `tests/fixtures/state-valid.json` — replace `advocate_verdict` / `adversary_verdict` with `review_verdict: null`.
- `tests/fixtures/state-terminal.json` — replace both fields with `review_verdict: "clean"` (or appropriate fixture value).
- `tests/fixtures/config-valid.json` — drop `adversary_enabled` and `advocate_must_run_regression_test`; add `reviewer_must_run_regression_test`.
- `tests/unit/test-pr-final-review-skill.sh` — rewrite:
  - Drop advocate-prompt and parallel-dispatch assertions.
  - Drop "silence is consent" / "explicitly counters" / "disputes or silent" assertions.
  - Drop `adversary_enabled` and `advocate_must_run_regression_test` knob assertions; assert `reviewer_must_run_regression_test`.
  - Drop `advocate_verdict` assertion; assert `review_verdict`.
  - Drop `pr-final-reviewer-adversary-prompt.md` and `pr-final-reviewer-advocate-prompt.md`; assert `pr-final-reviewer-prompt.md`.
  - Drop `pr_review_blocked` from the event-list assertion (event is removed). The asserted set becomes `pr_rebased pr_review_started pr_merge_ready pr_closed`.
  - Keep classification-branching assertions, STAGE COMPLETE footer, lock-removal assertion, regression_test_path conditional rendering, terminal outcomes (`merge-ready`, `pr-closed`).
- `tests/unit/test-prompts.sh` — drop advocate-prompt assertions; rename adversary assertions to the new filename and verdict line (`Critical findings | Important findings | clean`).

**Docs and metadata (light touch):**

- `README.md` — replace "parallel advocate + adversary final PR review" with "calibrated final PR review"; update config example.
- `.claude-plugin/plugin.json` — same description fix.
- `skills/using-bugfix/SKILL.md` — drop "advocate + adversary in parallel" references.
- `skills/autonomous-finishing/SKILL.md` — two comment templates: drop "advocate + adversary" wording.
- `skills/executing-plan/SKILL.md` — one reference about pr-final-review running the regression test: replace "advocate runs" with "reviewer runs (when configured)".

**Not touched:**

- `docs/superpowers/plans/2026-05-14-bugfix-end-to-end.md`, `2026-05-14-remove-locks-plan.md`, `docs/superpowers/specs/2026-05-14-bugfix-end-to-end-design.md` — historical; superseded by this spec where they conflict.

## Acceptance criteria

- A bug-class ticket with a clean PR runs through `pr-final-review` and lands at `state.terminal = "merge-ready"` with `state.artifacts.review_verdict` set to a `clean`-shaped text, no `advocate_verdict` written, and the merge-ready PR comment lists exactly one `Reviewer verdict:` line.
- A bug-class ticket with a tautological regression test (passes on base when it should fail) produces a `critical` verdict from the reviewer; the PR closes, `state.terminal = "pr-closed"`, and the `pr_closed` event precedes `block_and_comment` in the JSONL log.
- The unit test suite (`tests/unit/test-pr-final-review-skill.sh` and `tests/unit/test-prompts.sh`) passes after the rewrite.
- No references to `advocate`, `adversary`, `advocate_verdict`, `adversary_verdict`, `adversary_enabled`, or `advocate_must_run_regression_test` remain in skill code, schemas, fixtures, or current docs (historical plans/specs excluded).
