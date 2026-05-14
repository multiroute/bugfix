---
name: using-bugfix
description: Use when starting any conversation in a project that has the bugfix plugin installed - establishes how to find and use bugfix skills, particularly when running an autonomous bug-fix loop
---

<SUBAGENT-STOP>
If you were dispatched as a subagent to execute a specific task, skip this skill.
</SUBAGENT-STOP>

# Using the bugfix plugin

The bugfix plugin runs an autonomous bug-fix loop: ticket -> spec -> plan -> implementation -> PR -> CI -> final review -> merge-ready. Every stage is a skill you invoke via the `Skill` tool.

**Status: Production (Increments 1-7).** The full autonomous loop runs end-to-end: `fix bug <github-url>` -> ticket-intake -> planning -> executing -> autonomous-finishing -> CI watching (with auto-fix on failure) -> final review (advocate + adversary in parallel) -> terminal `merge-ready` (human merges manually) or `pr-closed` or human-resolves-block. Production-ready in design; real-world tuning of adversary calibration comes after observing actual runs.

**Routing rule:** when the user's message matches `bugfix:run-ticket`'s description, invoke `bugfix:run-ticket` via the `Skill` tool. Do NOT pre-empt it by reporting "not yet implemented" yourself — `run-ticket` owns that disclosure and handles URL parsing, ticket-id derivation, and the structured status response. Pre-empting it bypasses the trigger contract and confuses operators.

## Loop discipline

The loop has exactly one dispatcher: `bugfix:resume-run`. Stage skills (`ticket-intake`, `writing-plans`, `executing-plan`, `autonomous-finishing`, `ci-watchdog`, `pr-final-review`) are invoked BY resume-run, never by the agent directly.

You MUST NOT invoke a stage skill via the `Skill` tool yourself. You MUST NOT inline a stage's work (writing files, running tests, pushing branches) outside the dispatcher loop. Doing either violates the loop contract.

If you have data in context and feel the urge to skip the dispatcher and "just finish the work," STOP. That instinct is the failure mode the loop is designed to prevent. The PostToolUse hook will emit a reminder after each orchestration-skill invocation, pointing you back at resume-run. Honor it.

## Instruction priority

User instructions always take precedence over skills. If CLAUDE.md / AGENTS.md says "don't use X" and a bugfix skill says "always use X," follow the user.

1. User instructions (CLAUDE.md, direct request) - highest
2. bugfix skills
3. Default system prompt - lowest

## Front-door driver

- `bugfix:run-ticket` - Recognizes "fix bug/issue <github-url>" requests, parses the URL, initializes run state under `.bugfix/runs/<ticket-id>.json`, acquires the per-ticket lock, and loops `bugfix:resume-run` until the ticket reaches a terminal state or blocks for human input.

## Stage skills

The autonomous loop progresses through these stage skills in order. You generally don't invoke them directly — `bugfix:run-ticket` and `bugfix:resume-run` dispatch them.

- `bugfix:ticket-intake` - Reads the ticket via ticket-adapter, classifies it, writes a spec file.
- `bugfix:writing-plans` - Creates a per-ticket worktree and writes an implementation plan. Bug-fix plans require a failing regression test as Task 1.
- `bugfix:executing-plan` - Executes the plan task-by-task with two-stage review (spec compliance, then code quality). Fresh implementer on retry.
- `bugfix:autonomous-finishing` - Verifies tests pass, pushes the branch, opens a PR, comments the ticket.
- `bugfix:ci-watchdog` - Polls CI on the opened PR. On failure: dispatches a fix sub-agent (bounded retries). On success: advances to PR-level final review.
- `bugfix:pr-final-review` - Terminal stage. Rebases the PR, dispatches advocate + adversary reviewers in parallel, applies decision rule. Outcomes: `merge-ready` (human merges manually), `pr-closed`, or block-for-human-resolution.
- `bugfix:resume-run` - Dispatches the next stage when invoked from a fresh session (or from `run-ticket`'s in-process loop).

## Quality discipline + primitives

Use these any time the situation matches their description (the quality skills are vendored from `obra/superpowers` and apply to manual work just as much as autonomous loop runs):

- `bugfix:test-driven-development` - RED-GREEN-REFACTOR. Use when implementing any feature or bugfix, before writing implementation code.
- `bugfix:systematic-debugging` - Four-phase debugging process. Use when encountering any bug, test failure, or unexpected behavior, before proposing fixes.
- `bugfix:verification-before-completion` - Use when about to claim work is complete, fixed, or passing.
- `bugfix:receiving-code-review` - Use when receiving code review feedback, before implementing suggestions.
- `bugfix:requesting-code-review` - Use when completing tasks or before merging.
- `bugfix:dispatching-parallel-agents` - Use when facing 2+ independent tasks that can be worked on without shared state.
- `bugfix:using-git-worktrees` - Use when starting feature work that needs isolation from current workspace.

Primitives (called by stage skills; you usually invoke these only when explicitly building the loop):

- `bugfix:ticket-adapter` - The single place in the plugin that runs `gh` commands or hits GitHub's API. Use when a stage skill needs to read a ticket, comment, set status, push a branch, open/close a PR, poll CI, or rebase. Ships with the GitHub reference implementation.
- `bugfix:block-and-comment` - The single pause point in the autonomous loop. Posts a structured ticket comment, sets status, persists state, exits cleanly. Use when an autonomous stage needs human input.

Typed agent (dispatched via the Task tool, not as a skill):

- `bugfix:code-reviewer` - Senior code-reviewer agent. Dispatched by `executing-plan` as the per-task code-quality reviewer and by the final-review pass after all plan tasks complete.

## How to invoke a skill

Use the `Skill` tool with the skill's namespaced name. Example:

```
Skill: bugfix:systematic-debugging
```

Do NOT use the `Read` tool to read a skill file directly. The `Skill` tool loads it correctly and the host tracks invocation.

## Red flags - STOP if you think any of these

| Thought | Reality |
|---|---|
| "This is just a simple question" | Questions are tasks. Check for skills. |
| "I'll just do this one thing first" | Check BEFORE doing anything. |
| "This doesn't need a formal skill" | If a skill exists, use it. |
| "I remember this skill" | Skills evolve. Read current version via the Skill tool. |

## Terminal verdicts

`run-ticket` exits and reports back when the loop reaches a terminal state (`state.terminal` set to `merge-ready` or `pr-closed`) or a blocked state (human input required on the ticket). The agent should never claim a stage is "not yet implemented" at runtime — every stage in the loop has a shipped skill file. If a stage looks missing, it's an install issue; verify with `ls bugfix/skills/<stage>/` rather than parroting historical increment notes.
