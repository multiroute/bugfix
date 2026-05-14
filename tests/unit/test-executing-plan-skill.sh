#!/usr/bin/env bash
set -euo pipefail
PLUGIN_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SKILL="$PLUGIN_ROOT/skills/executing-plan/SKILL.md"

"$PLUGIN_ROOT/tests/unit/validate-skill.sh" "skills/executing-plan/SKILL.md"
grep -q "^name: executing-plan$" "$SKILL" || { echo "FAIL frontmatter name wrong"; exit 1; }
echo "OK  frontmatter name correct"

# Vendored upstream content (subagent-driven-development sentinel).
grep -qF "Fresh subagent per task" "$SKILL" || { echo "FAIL upstream content missing"; exit 1; }
echo "OK  upstream content vendored"

# Modification A: state-file-first context.
grep -qF "State-file-first context" "$SKILL" || { echo "FAIL state-file-first missing"; exit 1; }
echo "OK  modification A (state-file-first) present"

# Modification B: fresh-implementer-on-retry.
grep -qF "Fresh-implementer-on-retry" "$SKILL" || { echo "FAIL fresh-implementer rule missing"; exit 1; }
grep -qF "implementer-retry-prompt.md" "$SKILL" || { echo "FAIL retry prompt template reference missing"; exit 1; }
grep -qF "model_hints" "$SKILL" || { echo "FAIL model-hint reference missing"; exit 1; }
echo "OK  modification B (fresh-implementer-on-retry) present"

# Modification C: state-file-first per-task counters.
grep -qF "retries.executing.task" "$SKILL" || { echo "FAIL per-task retry counter reference missing"; exit 1; }
echo "OK  modification C (per-task counters) present"

# Modification D: state advance on completion.
grep -qF 'current_stage = "finishing"' "$SKILL" || grep -qF 'current_stage: "finishing"' "$SKILL" \
  || { echo "FAIL must advance current_stage to finishing"; exit 1; }
echo "OK  modification D (advances to finishing) present"

# Sub-agent prompt template references.
for tmpl in implementer-prompt.md spec-reviewer-prompt.md code-quality-reviewer-prompt.md implementer-retry-prompt.md; do
  grep -qF "$tmpl" "$SKILL" || { echo "FAIL missing reference to $tmpl"; exit 1; }
done
echo "OK  all 4 sub-agent prompt templates referenced"

# Retry budget references.
grep -qF "config.retry_budgets" "$SKILL" || { echo "FAIL config.retry_budgets reference missing"; exit 1; }
echo "OK  retry budgets referenced"

# Code reviewer agent referenced.
grep -qF "bugfix:code-reviewer" "$SKILL" || { echo "FAIL bugfix:code-reviewer agent reference missing"; exit 1; }
echo "OK  bugfix:code-reviewer agent referenced"

# Block-and-comment escalation.
grep -qF "block-and-comment" "$SKILL" || { echo "FAIL block-and-comment escalation missing"; exit 1; }
echo "OK  block-and-comment escalation documented"

# No superpowers: leaks.
if grep -q "superpowers:" "$SKILL"; then
  echo "FAIL leftover superpowers: references"
  grep -n "superpowers:" "$SKILL"
  exit 1
fi
echo "OK  no superpowers: leaks"

# R2-I3: required ## State writes and ## Events sections must exist.
grep -qF "## State writes" "$SKILL" || { echo "FAIL ## State writes section missing"; exit 1; }
grep -qF "## Events" "$SKILL" || { echo "FAIL ## Events section missing"; exit 1; }
echo "OK  ## State writes / ## Events sections present"

# R2-I4: retry counter is per-mode, not any-mode.
grep -qiF "per-mode" "$SKILL" || { echo "FAIL retry counter must be documented as per-mode"; exit 1; }
grep -qiF "same mode" "$SKILL" || { echo "FAIL Action escalation must be per-same-mode, not any-mode"; exit 1; }
echo "OK  per-mode retry counter semantics documented"

# R2-I7: regression-test path is read from explicit plan declaration, not git diff heuristic.
grep -qF "**Regression test file:**" "$SKILL" || { echo "FAIL must read regression-test path from explicit plan declaration"; exit 1; }
if grep -qF "git diff --name-only HEAD~1..HEAD" "$SKILL"; then
  echo "FAIL deprecated git-diff heuristic for regression_test_path still present"
  exit 1
fi
echo "OK  regression_test_path read from explicit plan declaration (not git diff)"

# No stale Increment N references (R2-I8 sweep).
if grep -qE "Increment [0-9]+" "$SKILL"; then
  echo "FAIL executing-plan still contains 'Increment N' reference"
  grep -nE "Increment [0-9]+" "$SKILL"
  exit 1
fi
echo "OK  no stale Increment N references"

# Lock infrastructure was removed (single-session driver — no concurrency races).
if grep -qiE "lock-acquire|lock-release|\.lock\b" "$SKILL"; then
  echo "FAIL executing-plan still references lock infrastructure"
  exit 1
fi
echo "OK  no lock-infrastructure references"

# STAGE COMPLETE footer must be present and contain the STOP HERE directive.
grep -qF "## STAGE COMPLETE — STOP HERE" "$SKILL" \
  || { echo "FAIL missing STAGE COMPLETE footer header"; exit 1; }
echo "OK  STAGE COMPLETE footer header present"

grep -qF "you violate the loop contract" "$SKILL" \
  || { echo "FAIL STAGE COMPLETE footer missing 'violate the loop contract' directive"; exit 1; }
echo "OK  STAGE COMPLETE footer contains loop-contract directive"

# Classification-aware Task 1 marker handling.
grep -qF "intake_classification" "$SKILL" \
  || { echo "FAIL executing-plan must branch on intake_classification for Task 1 marker"; exit 1; }
echo "OK  executing-plan branches on intake_classification"

# Bug-class still requires the marker (existing behavior).
grep -qF "Regression test file" "$SKILL" \
  || { echo "FAIL executing-plan must still document Regression test file marker for bugs"; exit 1; }
echo "OK  Regression test file marker documented (bug class)"

# Improvement-class tolerates absence.
grep -qiF "regression_test_path = null" "$SKILL" \
  || grep -qiF "regression_test_path = None" "$SKILL" \
  || { echo "FAIL executing-plan must tolerate absent marker for improvement class"; exit 1; }
echo "OK  improvement-class tolerates absent regression-test marker"

# Task progress must be persisted to state for crash-resume.
grep -qiF "tasks_done" "$SKILL" \
  || { echo "FAIL executing-plan must persist task progress to state.artifacts.executing.tasks_done"; exit 1; }
echo "OK  executing-plan persists task progress for crash-resume"

# Resume logic must be documented.
grep -qiF "resuming mid-execution" "$SKILL" \
  || grep -qiF "skip the implementer dispatch" "$SKILL" \
  || grep -qiF "already in the array" "$SKILL" \
  || { echo "FAIL executing-plan must document resume-from-tasks_done logic"; exit 1; }
echo "OK  executing-plan documents resume-from-tasks_done"

echo "PASS"
