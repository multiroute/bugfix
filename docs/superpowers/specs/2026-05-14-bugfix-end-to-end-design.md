# Bugfix loop — end-to-end reliability design

**Date:** 2026-05-14
**Status:** Approved (brainstorm complete; pending implementation plan)
**Owner:** kodart

## Problem

The autonomous bug-fix loop is designed to drive a GitHub issue from intake all the way to a merge-ready PR. In a recent real-world run on issue `multiroute/platform#282`, the loop reached `git push` but never opened a PR, never advanced through `autonomous-finishing` → `ci-watching` → `pr-reviewing`, and stopped reporting "all done" with no terminal verdict on the ticket.

Three interleaved failures caused this:

1. **`gh` CLI was unavailable** in the session. The `ticket-adapter` skill is hard-wired to `gh` (preflight fails fast if `gh` is missing or `< 2.40`). The adapter returned an error, but the agent improvised instead of escalating via `block-and-comment(tech-failure)`.
2. **The agent abandoned the loop contract.** It invoked `bugfix:run-ticket` correctly, then jumped straight to invoking `bugfix:ticket-adapter` directly — never invoking `bugfix:resume-run` even once. From that point it inlined the work of intake, planning, executing, and most of finishing, then stopped at "branch pushed" without opening a PR.
3. **The ticket was classified `improvement`, not `bug`.** Per the current intake rules, improvements should `block-and-comment(rejected)` at intake. The agent rationalized past that rule ("user said fix it"), but the rule itself prevented the loop from being designed to handle improvements end-to-end in the first place.

These failures combine to make the loop unreliable in two common environments: any host that prefers MCP over `gh` CLI, and any ticket where the human operator wants a non-defect change processed by the loop.

## Goals

Make the bugfix loop run end-to-end reliably in the following scenarios:

- The host has GitHub MCP but no `gh` CLI installed.
- The host has both, and the operator's stated preference is MCP-first.
- The ticket is an improvement (not a defect) and the operator wants the loop to process it the same way as a bug, with relaxed test-first requirements.
- The agent is tempted to inline stage work during a single-session run; the design surfaces an enforcing reminder rather than relying solely on prose discipline.

## Non-goals

- Splitting the adapter into multiple skill files. It stays as one file with two documented backends.
- Per-stage subagent isolation (running each stage as a fresh agent via the Task tool). The plugin's existing single-session loop is preserved; split-session execution is already supported via the external scheduler path on `resume-run`.
- Recovering the in-flight `claude/awesome-wright-yo0bX` branch from the failed run. That's a one-time manual cleanup, not a plugin feature.
- Adding a separate observability log channel beyond `events.log`. The existing event log carries enough signal.
- Changing `schemas/run-state.schema.json`. New fields fit in `artifacts` (which is `additionalProperties: true`).

## Design

Three coordinated changes, shipped together in a single PR.

### Change 1: Adapter dual-mode (MCP-first, gh fallback)

`skills/ticket-adapter/SKILL.md` grows from one backend to two. The skill remains a single file; callers (stage skills) never know which backend is in use.

**Backend selection — cached once per run:**

At the top of every operation, the adapter checks `state.artifacts.adapter_backend`:

1. If set → use that backend for this operation. Consistency across the run is required so a single run never half-uses MCP and half-uses `gh`.
2. If unset → probe:
   - **MCP first.** Check if `mcp__github__get_issue` (or the canonical GitHub MCP server's equivalent) is available in the agent's current toolset. The agent introspects its loaded tool list to determine this.
   - **gh fallback.** Run `command -v gh && gh auth status && gh --version >= 2.40`.
   - **Neither available.** Return `{"error": "neither MCP GitHub nor gh CLI available"}`. The caller (a stage skill) escalates via `block-and-comment(tech-failure)`.
3. Write the chosen backend to `state.artifacts.adapter_backend` under the per-ticket lock. Subsequent operations within the same run read from this cache.

**Operation map — each of the 11 existing operations documents both paths:**

| Op | gh path (existing) | MCP path (new) |
|---|---|---|
| `read` | `gh issue view --json title,body,state,labels,comments` | `mcp__github__get_issue` + `mcp__github__get_issue_comments`, merged into the same return shape |
| `ticket_comment` | `gh issue comment <N> --body-file -` | `mcp__github__add_issue_comment` |
| `set_status` | `gh label create` (idempotent) + `gh issue edit --add-label --remove-label` | `mcp__github__update_issue` with read-modify-write of the labels array; label creation via `mcp__github__create_label` where available, otherwise the adapter assumes pre-created labels and surfaces a clear error if a label is missing |
| `list_ready` | `gh issue list --label <label> --json number` | `mcp__github__list_issues` with label filter |
| `push` | `git push` (not `gh`) | unchanged — `git push` either way |
| `open_pr` | `gh pr create` | `mcp__github__create_pull_request(owner, repo, title, body, head, base)` |
| `pr_comment` | `gh pr comment <N> --body-file -` | `mcp__github__add_issue_comment` (GitHub treats PR comments as issue comments at the API level) |
| `pr_close` | `pr_comment` (close reason) + `gh pr close <N>` (two-step) | `add_issue_comment` (close reason) + `mcp__github__update_pull_request(state="closed")` |
| `ci_status` | `gh pr checks <N> --json status,conclusion,name,detailsUrl` | `mcp__github__get_pull_request_status` (one-shot) |
| `ci_watch` | `gh pr checks <N> --watch --fail-fast` (blocking, backgrounded) | **Polling loop** in the adapter: call `ci_status` every 30 s, exit when no checks pending or `timeout_minutes` exceeded |
| `rebase_pr` | `gh pr checkout <N>` + `git rebase <base>` + `git push --force-with-lease` | `gh pr checkout` is `gh`-only; MCP has no equivalent. The MCP path uses `git fetch origin pull/<N>/head` + manual checkout + `git rebase` + `git push --force-with-lease`. Net effect identical. |

**Reviewer-side diff access** is via `gh pr diff` (gh path) or `mcp__github__get_pull_request_files` + `mcp__github__get_pull_request_diff` (MCP path). This is not a dedicated adapter op — reviewers issue the call directly within the `pr-final-review` skill, which sees `state.artifacts.adapter_backend` and routes accordingly.

`ci_watch` is the one operationally different op. `gh` provides a blocking `--watch` flag that the existing `ci-watchdog` stage runs as a backgrounded `Bash` invocation. MCP has no equivalent; the MCP path implements it as an in-skill polling loop with a default 30-second interval, capped by `timeout_minutes`. The `ci-watchdog` stage's outer logic is unchanged — it sees the same return shape regardless of backend.

**Argument validation, untrusted-input wrapping, bot-author detection, and the `<owner>-<repo>-<number>` → `<number>` extraction rules are backend-agnostic and unchanged.**

**Tradeoffs:**

- The adapter grows from ~460 to ~750 lines. It stays as a single file because splitting would force callers to know which backend they're using, defeating the abstraction.
- The polling `ci_watch` consumes more session time than `gh`'s native `--watch`. For CI runs longer than ~15 minutes this is meaningful. Hosts with `gh` available keep the efficient blocking behavior.
- The MCP path needs `owner` and `repo` as explicit arguments. The adapter pulls these from `state.owner` and `state.repo`, which `run-ticket` already initializes from the URL parse.

### Change 2: Improvements as first-class

The current intake routing rejects improvements at the gate. The new routing lets them through, with the test-first requirement relaxed downstream.

**Classification routing:**

| Classification | Old behavior | New behavior |
|---|---|---|
| `bug` | Write spec, advance to `planning` | Unchanged |
| `improvement` | `block-and-comment(rejected)` | Write spec (improvement template), advance to `planning` |
| `not-actionable` | `block-and-comment(rejected)` | Unchanged |

**Spec template — branch on classification:**

The spec at `.bugfix/specs/<ticket_id>.md` keeps its frontmatter, `Problem statement`, and untrusted-input note regardless of classification. The middle sections diverge:

- **Bug spec** (existing): `Repro steps`, `Expected behavior`, `Actual behavior`, `Acceptance criterion = "regression test must transition FAIL → PASS"`.
- **Improvement spec** (new): `Desired outcome`, `Rationale`, `Out of scope`, `Acceptance criterion = "the agreed-upon change is implemented, existing tests pass, and new behavior has appropriate test coverage"`.

Both templates carry a top-line `**Classification:** bug | improvement` so downstream stages can branch without re-parsing the prose.

**Writing-plans stage:**

The planning skill reads `state.artifacts.intake_classification` once at the top:

- **`bug`:** existing rule unchanged. Task 1 MUST be a failing regression test that exercises the repro steps and transitions FAIL → PASS once the fix is in.
- **`improvement`:** Task 1 is whatever structurally makes sense for the change (often the implementation itself, sometimes a test scaffold). The plan SHOULD still produce test coverage for new behavior where applicable, but it's a SHOULD-not-MUST. The plan reviewer judges the choice rather than rejecting on a hard rule.

**Stages explicitly unchanged:**

- `executing-plan` — runs whatever the plan says. Classification-agnostic.
- `autonomous-finishing` — PR title prefix derives from classification (`Fix: ...` for bugs, `Improve: ...` for improvements). Mechanical.
- `ci-watchdog` — runs the test suite either way. Classification-agnostic.

**Stage with branching prompts:**

`pr-final-review` — the adversary and advocate reviewer prompt templates branch on classification:

- For bugs, both reviewers ask: "Is the regression test real, scoped to the bug, and does it actually catch the defect?"
- For improvements, both reviewers ask: "Is the change sensible, scoped, and free of regressions? Does new behavior have appropriate test coverage?"

This is the strongest guard against weak "improvement" PRs and replaces the mandatory-failing-test rule with reviewer judgment.

**Hybrid tickets** (something both a bug and an improvement) classify as `bug`, because the bug path has stricter rules. The improvement aspects ride along inside the same PR.

**The classification is set once at intake and never changes mid-run.** No re-classification after planning.

### Change 3: Loop discipline — hook + prose

The agent's tendency to inline stage work is the root cause of the loop never reaching `autonomous-finishing`. Prose alone wasn't enough in the observed run. The fix combines a `PostToolUse` hook with anti-rationalization framing across the skill bodies.

**PostToolUse hook:**

A new shell script at `hooks/post-tool-use/check-stage-handoff.sh` reads the PostToolUse event from stdin, inspects `tool_input.skill`, and emits a `systemMessage` if the invoked skill is one of the seven orchestration skills (`run-ticket`, `ticket-intake`, `writing-plans`, `executing-plan`, `autonomous-finishing`, `ci-watchdog`, `pr-final-review`).

The reminder is:

> "You just invoked `<skill>`. The bugfix loop's only dispatcher is `bugfix:resume-run` — your next tool call MUST be `Skill: bugfix:resume-run` with the active ticket_id. Do NOT invoke another stage skill directly, and do NOT inline stage-specific work (writing files, running tests, pushing branches) outside the dispatcher loop."

For any other skill the script exits silently. Emission is unconditional for orchestration skills — false positives are harmless (the reminder is always correct) while false negatives are exactly the failure mode this design addresses.

`resume-run` itself is NOT in the trigger list. Reminding after resume-run would create a reminder loop, since resume-run's expected next-call is a stage skill (which it dispatches in its own body).

Registration in `hooks/hooks.json`:

```json
{
  "PostToolUse": [
    {
      "matcher": "Skill",
      "hooks": [
        { "type": "command", "command": "${CLAUDE_PROJECT_DIR}/hooks/post-tool-use/check-stage-handoff.sh" }
      ]
    }
  ]
}
```

**Prose hardening — four targets:**

1. **`skills/using-bugfix/SKILL.md`** — new "Loop discipline" section near the top:
   > The loop has exactly one dispatcher: `bugfix:resume-run`. Stage skills are invoked BY resume-run, never by the agent directly. If you have data in context and feel the urge to skip the dispatcher and "just finish the work," STOP. That instinct is the failure mode the loop is designed to prevent.

2. **`skills/run-ticket/SKILL.md`** — new "Red flags during the driver loop" subsection modeled on `systematic-debugging`'s Red Flags table:

   | Thought | Reality |
   |---|---|
   | "I already have the data, I can do this inline" | The whole point of resume-run is fresh-context isolation. Invoke it. |
   | "User said fix it, I should just deliver" | Delivery comes from finishing the loop, not from skipping it. |
   | "Stage X is simple, I can collapse it with Y" | Stages are independent for a reason — review checkpoints, retry budgets, terminal-state tracking. Don't collapse. |
   | "The adapter failed, I'll work around it" | Adapter failures must escalate via `block-and-comment(tech-failure)`. Don't improvise. |

3. **Each of the six stage skills** — new end-of-body footer:

   > ## STAGE COMPLETE — STOP HERE
   >
   > Your work as the `<stage>` stage is done. You MUST stop here. Your next action MUST be to return control. Do NOT:
   > - Start the next stage's work inline.
   > - Read files relevant to the next stage.
   > - Implement / test / push / open PRs beyond this stage's documented operations.
   >
   > If you continue past this point, you violate the loop contract. The PostToolUse hook will surface a reminder; ignoring it compounds the violation.

4. **`skills/resume-run/SKILL.md`** — short addition near the top: "resume-run dispatches exactly one stage skill via the Skill tool, then exits. If you find yourself wanting to inline the stage's work instead of invoking it as a skill, STOP — the dispatch must happen via Skill so the next agent context can pick up cleanly if the run is split across sessions."

**Tradeoffs:**

- The hook fires on every Skill invocation, then exits quickly for non-matches. The shell startup overhead is roughly 10 ms per Skill call — negligible.
- The reminder is added to every stage skill invocation, including legitimate ones dispatched by resume-run. This is intentional — the reminder is correct in both cases. The cost is a small token expansion per stage; the benefit is that the agent cannot miss the next-call instruction.

## Testing

The plugin's existing tests are structural skill-validation tests that `grep` skill files for required prose, section headers, and command verbs. Several need updates; two new tests are added.

**Updated tests:**

- `test-ticket-adapter-skill.sh` — heavy. Replace "description must mention `gh`" with "must mention `gh` OR `MCP`." Replace "preflight has `command -v gh`" with backend-selection prose. Each operation must document both a gh path and an MCP path. `ci_watch` keeps `--watch --fail-fast` on the gh path; MCP path uses a polling loop with a documented interval. Add assertion that `state.artifacts.adapter_backend` is documented as the cache key.
- `test-ticket-intake-skill.sh` — moderate. Block table for `improvement` no longer says `block-and-comment(rejected)`; new assertion is `improvement → write spec, advance to planning`. Both spec templates are documented.
- `test-writing-plans-skill.sh` — moderate. Task 1 rule is classification-conditional: `bug` requires failing regression test; `improvement` relaxes.
- `test-pr-final-review-skill.sh` — small. Reviewer prompts branch on classification.
- `test-hooks-json.sh` — small. New `PostToolUse` matcher block is registered.
- All six stage-skill tests get a `## STAGE COMPLETE — STOP HERE` footer assertion (~3 lines each).

**New tests:**

- `tests/unit/test-post-tool-use-hook.sh` (~50 lines). Pipe synthetic events into the script and assert correct emission/silence for: orchestration skills (emit `systemMessage`), non-orchestration skills (silent), non-Skill tools (silent), malformed events (silent, no crash).
- `tests/unit/test-adapter-backend-selection.sh` (~30 lines). Adapter documents MCP-first probe order, gh fallback, and "neither available" error path.

**Unchanged tests:**

- `test-lock-acquire.sh` / `test-lock-release.sh` — lock primitives are backend-agnostic.
- `test-events-schema.sh` / `test-events-append.sh` — event log unchanged.
- `test-state-schema.sh` — schema unchanged (artifacts already `additionalProperties: true`).
- `test-config-schema.sh` — no new config knobs. Polling interval is a hardcoded 30 s with a code comment for tuners.
- `validate-skill.sh` (generic) — frontmatter rules unchanged.

**Manual smoke tests (post-merge, not in CI):**

- Run the loop on a real bug ticket where only `gh` is available → verify end-to-end completion (existing behavior preserved).
- Run the loop on a real bug ticket where only MCP GitHub is registered → verify end-to-end completion (new path works).
- Run the loop on an improvement ticket → verify it proceeds through planning/executing/finishing/CI/review instead of rejecting at intake.

End-to-end integration tests that actually hit GitHub are out of scope. The plugin doesn't have them today and adding them would require fixture repos, dummy issues, and credentials handling — meaningful infrastructure for marginal value over the structural tests plus the manual smoke.

## File-level scope summary

| File | Status | Estimated lines |
|---|---|---|
| `skills/ticket-adapter/SKILL.md` | modified | 460 → ~750 |
| `skills/ticket-intake/SKILL.md` | modified | 114 → ~160 |
| `skills/writing-plans/SKILL.md` | modified | 233 → ~260 |
| `skills/autonomous-finishing/SKILL.md` | modified | 105 → ~115 |
| `skills/pr-final-review/SKILL.md` | modified | 191 → ~225 |
| `skills/ci-watchdog/SKILL.md` | modified | 176 → ~190 |
| `skills/executing-plan/SKILL.md` | modified | 378 → ~390 |
| `skills/using-bugfix/SKILL.md` | modified | 84 → ~110 |
| `skills/run-ticket/SKILL.md` | modified | 133 → ~165 |
| `skills/resume-run/SKILL.md` | modified | 105 → ~115 |
| `hooks/hooks.json` | modified | small |
| `hooks/post-tool-use/check-stage-handoff.sh` | NEW | ~40 |
| `tests/unit/test-ticket-adapter-skill.sh` | modified | heavy |
| `tests/unit/test-ticket-intake-skill.sh` | modified | moderate |
| `tests/unit/test-writing-plans-skill.sh` | modified | moderate |
| `tests/unit/test-pr-final-review-skill.sh` | modified | small |
| `tests/unit/test-hooks-json.sh` | modified | small |
| `tests/unit/test-{stage}-skill.sh` (six files) | modified | +3 each |
| `tests/unit/test-post-tool-use-hook.sh` | NEW | ~50 |
| `tests/unit/test-adapter-backend-selection.sh` | NEW | ~30 |
| `README.md` | modified | small |

**Schema, primitives, agents, and vendored skills — unchanged:**

- `schemas/*.json` — no schema changes.
- `lib/lock-acquire.sh`, `lib/lock-release.sh`, `lib/events-append.sh` — unchanged.
- `skills/test-driven-development/`, `skills/systematic-debugging/`, `skills/verification-before-completion/`, `skills/dispatching-parallel-agents/`, `skills/requesting-code-review/`, `skills/receiving-code-review/`, `skills/using-git-worktrees/` — vendored from superpowers, unchanged.
- `agents/code-reviewer.md` — unchanged.
- `skills/block-and-comment/SKILL.md` — unchanged.

Total diff estimate: roughly 700–900 lines added or changed across ~20 files. The bulk is prose in skill bodies; the hook script and adapter MCP paths are the only code additions.

## Risks and open questions

**Risk: MCP server name and op name divergence.** The design references `mcp__github__get_issue`, `mcp__github__add_issue_comment`, etc. as canonical GitHub MCP operations. Different MCP server implementations may use different op names. The adapter's MCP path uses the canonical anthropic GitHub MCP server's names; alternative servers would need an adapter fork. Mitigation: document the assumed server name in the adapter preamble.

**Risk: `ci_watch` polling overhead.** A 60-minute CI run polled every 30s makes 120 requests. Acceptable for normal use; could be tuned via config later if it becomes a problem.

**Risk: hook script portability.** The hook is a bash script. Plugin install on Windows would require WSL or a `.cmd` variant. The plugin already has a `hooks/run-hook.cmd` shim suggesting this concern is anticipated; the new script should integrate with that shim.

**Open question (deferred to implementation):** the precise MCP operation names used by the host's MCP server. The implementation will probe and may need to map across name variations.

## Out of scope (explicitly)

- Recovery of the failed run on `multiroute/platform#282`. Manual: open the PR by hand or discard the branch.
- A `--force` override flag for non-actionable tickets. Operators reclassify or close.
- Per-stage subagent isolation (Q3 Level 3). Existing single-session loop is preserved.
- Adapter-replaceability for non-GitHub trackers. The existing GitHub-only assumption is preserved.
