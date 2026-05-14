---
name: writing-plans
description: Use when you have a spec or requirements for a multi-step task, before touching code
---

## State-file-first context

This skill is invoked by `bugfix:run-ticket` when `state.current_stage == "planning"`. Before producing any plan:

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

If anything fails before the plan is reviewed, exit via `bugfix:block-and-comment` with the appropriate `exit_kind` (`needs-info` for spec ambiguity, `tech-failure` for tooling errors).

---



# Writing Plans

## Overview

Write comprehensive implementation plans assuming the engineer has zero context for our codebase and questionable taste. Document everything they need to know: which files to touch for each task, code, testing, docs they might need to check, how to test it. Give them the whole plan as bite-sized tasks. DRY. YAGNI. TDD. Frequent commits.

Assume they are a skilled developer, but know almost nothing about our toolset or problem domain. Assume they don't know good test design very well.

**Announce at start:** "I'm using the writing-plans skill to create the implementation plan."

**Context:** This should be run in a dedicated worktree (created by brainstorming skill).

**Save plans to:** `.bugfix/plans/YYYY-MM-DD-<feature-name>.md`
- (User preferences for plan location override this default)

## Scope Check

If the spec covers multiple independent subsystems, it should have been broken into sub-project specs during brainstorming. If it wasn't, suggest breaking this into separate plans — one per subsystem. Each plan should produce working, testable software on its own.

## File Structure

Before defining tasks, map out which files will be created or modified and what each one is responsible for. This is where decomposition decisions get locked in.

- Design units with clear boundaries and well-defined interfaces. Each file should have one clear responsibility.
- You reason best about code you can hold in context at once, and your edits are more reliable when files are focused. Prefer smaller, focused files over large ones that do too much.
- Files that change together should live together. Split by responsibility, not by technical layer.
- In existing codebases, follow established patterns. If the codebase uses large files, don't unilaterally restructure - but if a file you're modifying has grown unwieldy, including a split in the plan is reasonable.

This structure informs the task decomposition. Each task should produce self-contained changes that make sense independently.

## Bite-Sized Task Granularity

**Each step is one action (2-5 minutes):**
- "Write the failing test" - step
- "Run it to make sure it fails" - step
- "Implement the minimal code to make the test pass" - step
- "Run the tests and make sure they pass" - step
- "Commit" - step


## Plan content depends on classification

Before writing tasks, read `state.artifacts.intake_classification` (set by `ticket-intake`). The Task 1 rule branches:

### When `intake_classification == "bug"`: regression test first

Task 1 MUST be a failing regression test that exercises the repro steps from the spec and transitions FAIL on the base branch to PASS once the fix is in. This is non-negotiable for bug plans — the regression test is the loop's strongest guard against fake fixes.

Example Task 1 shape (substitute the bug's actual repro):

### Task 1: Regression test for <one-line bug description>

**Regression test file:** `tests/<path>/test_<bug>.py`

**Files:**
- Test: `tests/<path>/test_<bug>.py`

The leading `**Regression test file:** <path>` declaration above is **mandatory** for every bug-class Task 1. Downstream stages (`bugfix:executing-plan`, `bugfix:ci-watchdog`, `bugfix:pr-final-review`) parse this line to discover the canonical regression-test path — the diff heuristic was removed because it was fragile when Task 1 touched multiple files. If a bug-class plan omits this declaration, `bugfix:executing-plan` will exit via `bugfix:block-and-comment(tech-failure)`.

- [ ] **Step 1: Write the failing regression test**

```python
def test_<bug_name>():
    # Exact reproduction from spec's "Repro steps" section.
    result = <call_that_currently_misbehaves>
    assert result == <expected_from_spec>
```

- [ ] **Step 2: Run test, verify FAIL with the bug's actual behavior**

Run: `pytest tests/<path>/test_<bug>.py::test_<bug_name> -v`
Expected FAIL output: <paste the actual error message the user would see>

- [ ] **Step 3: Commit**

```bash
git add tests/<path>/test_<bug>.py
git commit -m "test: add failing regression test for <bug>"
```

Subsequent tasks implement the fix and verify the test transitions to PASS.

### When `intake_classification == "improvement"`: Task 1 by judgment

Improvement plans do NOT have a defect to reproduce, so the mandatory failing-test-first rule is relaxed. Task 1 is whatever structurally makes sense for the change:

- If the improvement adds new behavior, Task 1 SHOULD be a test for that behavior (which fails because the behavior doesn't exist yet — same TDD cycle).
- If the improvement is a refactor or cleanup with no behavior change, Task 1 MAY be the refactoring step itself, with existing tests proving non-regression.
- If the improvement is documentation or comment cleanup, Task 1 MAY be the change itself.

In all cases, the improvement plan SHOULD produce test coverage for any new behavior added. Coverage adequacy is judged by the plan reviewer (second-stage review below) and the PR-final-review adversary, not by a fixed rule.


## Plan Document Header

**Every plan MUST start with this header:**

```markdown
# [Feature Name] Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: In the bugfix autonomous loop, this header's REQUIRED SUB-SKILL note is informational only — the loop's `bugfix:run-ticket` driver dispatches `bugfix:executing-plan` automatically to consume this plan. For manual plan execution outside the loop, use `bugfix:executing-plan` directly. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** [One sentence describing what this builds]

**Architecture:** [2-3 sentences about approach]

**Tech Stack:** [Key technologies/libraries]

---
```

## Task Structure

````markdown
### Task N: [Component Name]

**Files:**
- Create: `exact/path/to/file.py`
- Modify: `exact/path/to/existing.py:123-145`
- Test: `tests/exact/path/to/test.py`

- [ ] **Step 1: Write the failing test**

```python
def test_specific_behavior():
    result = function(input)
    assert result == expected
```

- [ ] **Step 2: Run test to verify it fails**

Run: `uv run pytest tests/path/test.py::test_name -v`
Expected: FAIL with "function not defined"

- [ ] **Step 3: Write minimal implementation**

```python
def function(input):
    return expected
```

- [ ] **Step 4: Run test to verify it passes**

Run: `uv run pytest tests/path/test.py::test_name -v`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add tests/path/test.py src/path/file.py
git commit -m "feat: add specific feature"
```
````

## No Placeholders

Every step must contain the actual content an engineer needs. These are **plan failures** — never write them:
- "TBD", "TODO", "implement later", "fill in details"
- "Add appropriate error handling" / "add validation" / "handle edge cases"
- "Write tests for the above" (without actual test code)
- "Similar to Task N" (repeat the code — the engineer may be reading tasks out of order)
- Steps that describe what to do without showing how (code blocks required for code steps)
- References to types, functions, or methods not defined in any task

## Remember
- Exact file paths always
- Complete code in every step — if a step changes code, show the code
- Exact commands with expected output
- DRY, YAGNI, TDD, frequent commits

## Mandatory plan review (fresh sub-agent)

After saving the plan, dispatch a fresh sub-agent using the prompt template at `bugfix/skills/_prompts/plan-document-reviewer-prompt.md`. The reviewer reads the spec and the plan independently and reports `Plan compliant` or `Issues found: [...]`.

Substitute `<<<SPEC_PATH>>>` and `<<<PLAN_PATH>>>` in the template with the actual paths before dispatching.

On `Issues found`:
1. Read `.bugfix/runs/<ticket-id>.json`, increment `state.retries.planning` by 1, write back.
2. If `state.retries.planning >= config.retry_budgets.planning` (default 2): exit via `bugfix:block-and-comment(tech-failure, reason="could not produce a reviewable plan after 2 attempts", artifacts=[plan path, reviewer verdict path])`.
3. Otherwise: revise the plan addressing the reviewer's findings, save, re-dispatch the reviewer.

DO NOT skip this review or run it in-line. The fresh sub-agent's isolated context is the whole point.

After "Plan compliant":
- Set `state.plan_path = ".bugfix/plans/<ticket-id>.md"`.
- Emit `plan_reviewed` event via `bugfix/lib/events-append.sh`.
- Set `state.current_stage = "executing"`.
- Exit.

## State writes

Inside the planning stage:

- `state.worktree_path = ".worktrees/<ticket-id>"` (after worktree creation).
- `state.branch = "<branch name created by using-git-worktrees>"`.
- `state.base_sha = "<commit at base of worktree>"`.
- `state.plan_path = ".bugfix/plans/<ticket-id>.md"` (after plan review passes).
- `state.retries.planning = N` (incremented on each plan-review revision; capped by `config.retry_budgets.planning`, default 2).
- `state.updated_at = <now>` (refreshed on every write).
- `state.current_stage = "executing"` (only on plan-review pass; this is the next-stage marker).

All writes are read-modify-write of `.bugfix/runs/<ticket-id>.json`. No write touches `state.terminal` or `state.blocked_reason` — terminal/blocked transitions go through `bugfix:block-and-comment`.

## Events

Emitted via `bugfix/lib/events-append.sh ".bugfix/runs/<ticket-id>.events.log" <event> planning '<detail-json>'`:

- `worktree_created` — detail: `{"branch": "<branch>", "base_sha": "<sha>"}`. After a fresh worktree is created and verified clean.
- `worktree_reused` — detail: `{"path": "<absolute>", "branch": "<branch>"}`. Emitted instead of `worktree_created` when the planning step detects cwd is already inside an isolated git worktree (the operator pre-staged the workspace).
- `plan_revised` — detail: `{"attempt": <int>}`. After each plan-revision pass triggered by the mandatory reviewer.
- `plan_reviewed` — detail: `{}`. Once on the transition to `executing`.

## Block-and-comment exits

| Condition | exit_kind |
|---|---|
| Spec at `state.spec_path` is missing / unreadable | `tech-failure` |
| `bugfix:using-git-worktrees` fails (dirty baseline, branch conflict, etc.) | `tech-failure` |
| Spec is too ambiguous to produce a plan (mandatory reviewer flags it) | `needs-info` |
| Plan reviewer rejects ≥ `config.retry_budgets.planning` times | `tech-failure` |

## Execution Handoff

In the bugfix autonomous loop this skill does NOT ask the user which execution mode to use — `bugfix:run-ticket` always dispatches `bugfix:executing-plan` after the plan is reviewed and `current_stage` advances to `executing`. Do NOT pause to offer "Subagent-Driven vs Inline Execution" choices; those upstream options are not exposed in the autonomous loop. The autonomous flow continues automatically via the loop's state-file-first dispatch.

## STAGE COMPLETE — STOP HERE

Your work as the `writing-plans` stage is done. You MUST stop here. Your next action MUST be to return control to `bugfix:run-ticket`'s driver loop. Do NOT:
- Start the next stage's work inline.
- Read files relevant to the next stage.
- Implement / test / push / open PRs beyond this stage's documented operations.

If you continue past this point, you violate the loop contract. The PostToolUse hook will surface a reminder; ignoring it compounds the violation.
