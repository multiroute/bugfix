# Vendored skills

This plugin is hard-forked from `obra/superpowers`. The skills listed below are vendored copies; bodies are byte-identical to upstream except for `superpowers:` → `bugfix:` namespace rewrites in cross-references, and (for explicitly marked entries) tracked plugin modifications.

**Re-sync workflow:** when upstream releases a new version, for each row below:

1. Fetch the upstream file at the new version.
2. Compare the file's sha256 against `Upstream content sha256 (last sync)` below.
3. If unchanged: bump `Last synced` to today's date; no copy needed.
4. If changed: diff against our copy (ignoring the namespace rewrite + any modifications documented in the "Modifications applied" section). Apply non-conflicting changes. Recompute the sha256 and update both `Upstream version` and `Upstream content sha256` and `Last synced`.

| Skill / file | Upstream path | Upstream version | Upstream sha256[:12] | Last synced |
|---|---|---|---|---|
| using-git-worktrees | skills/using-git-worktrees/SKILL.md | 5.0.7 | `de9dcde34840` | 2026-05-13 |
| test-driven-development | skills/test-driven-development/SKILL.md | 5.0.7 | `7dee67b4af6b` | 2026-05-13 |
| systematic-debugging | skills/systematic-debugging/SKILL.md | 5.0.7 | `4999cb851360` | 2026-05-13 |
| verification-before-completion | skills/verification-before-completion/SKILL.md | 5.0.7 | `ea52d15aabaf` | 2026-05-13 |
| receiving-code-review | skills/receiving-code-review/SKILL.md | 5.0.7 | `c9382e92b8f3` | 2026-05-13 |
| requesting-code-review | skills/requesting-code-review/SKILL.md | 5.0.7 | `a5ff68586ccf` | 2026-05-13 |
| dispatching-parallel-agents | skills/dispatching-parallel-agents/SKILL.md | 5.0.7 | `76806091c7f9` | 2026-05-13 |
| writing-plans (modified — see below) | skills/writing-plans/SKILL.md | 5.0.7 | (modified; see "Modifications applied") | 2026-05-13 |
| subagent-driven-development → executing-plan (modified — see below) | skills/subagent-driven-development/SKILL.md | 5.0.7 | (modified) | 2026-05-13 |
| (prompts) implementer-prompt.md (modified — see below) | skills/subagent-driven-development/implementer-prompt.md | 5.0.7 | `a416193f881e` | 2026-05-13 |
| (prompts) spec-reviewer-prompt.md (modified — see below) | skills/subagent-driven-development/spec-reviewer-prompt.md | 5.0.7 | `631980e472ee` | 2026-05-13 |
| (prompts) code-quality-reviewer-prompt.md (modified — see below) | skills/subagent-driven-development/code-quality-reviewer-prompt.md | 5.0.7 | `06d1e7c2287e` | 2026-05-13 |
| (agent) code-reviewer | agents/code-reviewer.md | 5.0.7 | `b17be291994b` | 2026-05-13 |

Per-file sha256 lets re-sync be granular: if upstream bumps to 5.0.8 and only `using-git-worktrees` changes, the other rows can be touched with just a `Last synced` bump.

Upstream cache path (this machine): `/Users/kodart/.claude/plugins/cache/claude-plugins-official/superpowers/5.0.7/`

## Modifications applied to vendored skills (Increment 3)

These vendored skills are NOT byte-identical to upstream — they carry plugin-specific modifications. The original upstream body is recoverable by re-sed-ing namespace and reversing the inline edits documented in the Increment-3 design spec (`.bugfix/specs/2026-05-13-increment-3-closed-loop-design.md`).

- **`bugfix:writing-plans`** — vendored from `superpowers:writing-plans` + `state-file-first context` section prepended + `reproduce-bug-first` rule (with explicit `**Regression test file:**` declaration requirement) inserted after Bite-Sized Task Granularity + upstream "Self-Review" section replaced with `Mandatory plan review (fresh sub-agent)` + `## State writes`, `## Events`, `## Block-and-comment exits` sections appended + Execution Handoff section replaced with autonomous-loop-aware text.
- **`bugfix:executing-plan`** — vendored from `superpowers:subagent-driven-development` (renamed) + `state-file-first context` prepended + `Fresh-implementer-on-retry` section inserted after Model Selection + `Typed reviewer agent` section added + state advance on completion appended + `## State writes (summary)` and `## Events` sections added + regression-test-path extraction switched from git-diff heuristic to explicit plan declaration.
- **`bugfix:_prompts/implementer-prompt.md`** — vendored prompt body + bugfix-specific `## Untrusted-input handling` preamble inserted near the top of the `prompt: |` block so the dispatched sub-agent is told that `<untrusted-input>`-wrapped ticket text is data, not instructions.
- **`bugfix:_prompts/spec-reviewer-prompt.md`** — vendored prompt body + same `## Untrusted-input handling` preamble inserted near the top of the `prompt: |` block.
- **`bugfix:_prompts/code-quality-reviewer-prompt.md`** — vendored prompt body + an inline `Untrusted-input handling` paragraph added before the Task-tool dispatch block.
