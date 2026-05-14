#!/usr/bin/env bash
set -euo pipefail
PLUGIN_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
VALIDATE="$PLUGIN_ROOT/tests/unit/validate-skill.sh"

for s in \
  "skills/using-bugfix/SKILL.md" \
  "skills/run-ticket/SKILL.md" \
  "skills/ticket-intake/SKILL.md" \
  "skills/writing-plans/SKILL.md" \
  "skills/executing-plan/SKILL.md" \
  "skills/autonomous-finishing/SKILL.md" \
  "skills/ci-watchdog/SKILL.md" \
  "skills/pr-final-review/SKILL.md" \
  "skills/resume-run/SKILL.md" \
  "skills/ticket-adapter/SKILL.md" \
  "skills/block-and-comment/SKILL.md" \
  "skills/using-git-worktrees/SKILL.md" \
  "skills/test-driven-development/SKILL.md" \
  "skills/systematic-debugging/SKILL.md" \
  "skills/verification-before-completion/SKILL.md" \
  "skills/receiving-code-review/SKILL.md" \
  "skills/requesting-code-review/SKILL.md" \
  "skills/dispatching-parallel-agents/SKILL.md"
do
  "$VALIDATE" "$s"
done
echo "PASS"
