---
name: autonomous-finishing
description: Use as the post-execution stage of the autonomous bug-fix loop. Verifies local tests pass, pushes the branch, opens a PR via `bugfix:ticket-adapter`, comments the ticket with the PR link, and advances state to ci-watching. Dispatched by `bugfix:run-ticket` when `state.current_stage == "finishing"`.
---

# bugfix:autonomous-finishing

The post-execution stage: turn committed work into a public PR with a ticket comment, then hand off to CI watching.

## State-file-first context

This skill is invoked by `bugfix:run-ticket` when `state.current_stage == "finishing"`. Before doing any work:

1. Read `.bugfix/runs/<ticket-id>.json`. Confirm `current_stage == "finishing"`. If not, exit with an error.
2. cd into `state.worktree_path`. All operations from here run inside the worktree.

## Local test verification

BEFORE pushing or opening a PR, verify the project's tests pass locally. `executing-plan` should have ensured this, but `autonomous-finishing` runs an independent confirmation — the cost is cheap, the cost of opening a broken PR is high.

The skill detects the test command using these heuristics (in order):

1. If `package.json` exists with a `test` script: `npm test`
2. If `Cargo.toml` exists: `cargo test`
3. If `pyproject.toml` exists with `pytest`: `uv run pytest` (run `uv sync` first if `.venv` is missing)
4. If `go.mod` exists: `go test ./...`
5. If `Makefile` has a `test` target: `make test`
6. Else: refuse to proceed via `bugfix:block-and-comment(tech-failure, reason="could not detect a test command")`.

If the detected command exits non-zero, **refuses to proceed**: exit via `bugfix:block-and-comment(tech-failure, reason="tests fail at finishing — executing-plan should have caught this", artifacts=[test output])`. This is an invariant violation (executing-plan should never advance with failing tests), but defensive against it nonetheless.

## Operations called

- `bugfix:ticket-adapter:push(branch)` — push the branch from `state.branch` (e.g., `fix/<ticket-id>`).
- `bugfix:ticket-adapter:open_pr(branch, base, title, body)` — open the PR. `base` is `state.base_branch`. `title` and `body` per the template below.
- `bugfix:ticket-adapter:ticket_comment(issue_number, body)` — comment on the source ticket with the PR link.

## PR body template

Construct the PR body using exactly this template:

```
Closes #<issue_number>

## What changed

<one-paragraph summary of the diff, in your own words, NOT inside untrusted-input tags>

## Why

<from the spec at state.spec_path — the "Problem statement" section, paraphrased; quoting ticket text wrap in <untrusted-input>>

## Regression test

The failing-test-first task from the plan (Task 1) added a regression test at: `<test path>`. This test fails on `<base_branch>` (commit `<base_sha>`) and passes on this PR's tip.

## Plan and review history

- Spec: `<state.spec_path>`
- Plan: `<state.plan_path>`
- Final code-reviewer pass: clean (per executing-plan's final review step)

🤖 Opened by bugfix autonomous loop. CI watching and parallel advocate + adversary final review run next; this comment will be supplemented with their verdicts before merge-ready.
```

PR title: `Fix #<issue_number>: <ticket title>` where `<ticket title>` is the ticket title sanitized for human display: strip the `<untrusted-input>` wrapper tags (the title is human-visible in the GitHub UI, not LLM-consumed at this point), strip any control characters, replace newlines with spaces, and truncate to 70 chars including an ellipsis. The wrapper-stripping is unusual for adapter-returned text — explicitly: the title is the one place we render ticket text for human reading, so the LLM-safety wrapper would just appear as literal `<untrusted-input>` characters in the PR header.

The ticket comment uses a shorter template (substitute `<pr_url>` with the constructed `state.pr_url` value):

```
PR opened: <pr_url>

The bugfix autonomous loop has executed the plan and opened a PR. CI watching and the PR-level final review (parallel advocate + adversary) run automatically next; you'll see another comment when the loop reaches a terminal verdict.
```

## State writes

- `state.pr_number = <returned by open_pr>` (integer)
- `state.pr_url = "https://github.com/<state.owner>/<state.repo>/pull/<state.pr_number>"` (constructed string — ticket-adapter:open_pr returns only the integer, so this skill is responsible for assembling the URL form for downstream consumers and ticket-comment templates)
- `state.updated_at = <now>`
- `state.current_stage = "ci-watching"`

One read-modify-write at the end.

## Events

Emit via `bugfix/lib/events-append.sh ".bugfix/runs/<ticket-id>.events.log" <event> finishing '<detail-json>'`:

- `pr_pushed` (detail: `{}`) — after a successful push, before open_pr.
- `pr_opened` (detail: `{"pr_number": <int>}`) — after open_pr returns.

## Block-and-comment exits

| Condition | exit_kind |
|---|---|
| Test command not detected | `tech-failure` |
| Local tests fail | `tech-failure` (invariant violation) |
| `ticket-adapter:push` returns error | `tech-failure` |
| `ticket-adapter:open_pr` returns error | `tech-failure` |
| `ticket-adapter:ticket_comment` returns error | `tech-failure` (PR is open but ticket not updated — operator must reconcile) |

## Next stage

On success: write `state.current_stage = "ci-watching"`, exit. `bugfix:run-ticket` dispatches `bugfix:ci-watchdog`, which long-polls CI on the new PR via `ticket-adapter:ci_watch` and either advances to `pr-reviewing` on green, fixes failures (bounded retries), or blocks on timeout.
