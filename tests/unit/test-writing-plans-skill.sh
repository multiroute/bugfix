#!/usr/bin/env bash
set -euo pipefail
PLUGIN_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SKILL="$PLUGIN_ROOT/skills/writing-plans/SKILL.md"

"$PLUGIN_ROOT/tests/unit/validate-skill.sh" "skills/writing-plans/SKILL.md"
grep -q "^name: writing-plans$" "$SKILL" || { echo "FAIL frontmatter name wrong"; exit 1; }
echo "OK  frontmatter name correct"

# Vendored upstream content must be present (sentinel from upstream body).
grep -qF "Bite-Sized Task Granularity" "$SKILL" || { echo "FAIL upstream content missing"; exit 1; }
echo "OK  upstream content vendored"

# Modification A: reproduce-bug-first rule.
grep -qF "Bug-fix plans: regression test first" "$SKILL" || { echo "FAIL reproduce-bug-first section missing"; exit 1; }
grep -qF "Task 1 MUST be" "$SKILL" || { echo "FAIL reproduce-bug-first rule wording missing"; exit 1; }
echo "OK  modification A (reproduce-bug-first) present"

# Modification B: mandatory plan review section.
grep -qF "Mandatory plan review (fresh sub-agent)" "$SKILL" || { echo "FAIL mandatory plan review section missing"; exit 1; }
grep -qF "plan-document-reviewer-prompt.md" "$SKILL" || { echo "FAIL plan reviewer template reference missing"; exit 1; }
grep -qF "retries.planning" "$SKILL" || { echo "FAIL planning retry counter missing"; exit 1; }
echo "OK  modification B (mandatory plan review) present"

# Modification C: state-file-first context.
grep -qF "State-file-first context" "$SKILL" || { echo "FAIL state-file-first section missing"; exit 1; }
grep -qF "using-git-worktrees" "$SKILL" || { echo "FAIL using-git-worktrees invocation missing"; exit 1; }
grep -qF "base_sha" "$SKILL" || { echo "FAIL base_sha state field missing"; exit 1; }
grep -qF "worktree_path" "$SKILL" || { echo "FAIL worktree_path state field missing"; exit 1; }
echo "OK  modification C (state-file-first) present"

# State advance.
grep -qF 'current_stage = "executing"' "$SKILL" || grep -qF 'current_stage: "executing"' "$SKILL" \
  || { echo "FAIL must advance current_stage to executing"; exit 1; }
echo "OK  advances to executing stage"

# No superpowers: leaks.
if grep -q "superpowers:" "$SKILL"; then
  echo "FAIL leftover superpowers: references"
  grep -n "superpowers:" "$SKILL"
  exit 1
fi
echo "OK  no superpowers: leaks"

# R2-I3: required state-machine documentation sections must be present.
for section in "## State writes" "## Events" "## Block-and-comment exits"; do
  grep -qF "$section" "$SKILL" || { echo "FAIL missing section: $section"; exit 1; }
done
echo "OK  ## State writes / ## Events / ## Block-and-comment exits sections present"

# R2-I7: Task 1 regression-test path must be declared explicitly, not inferred.
grep -qF "**Regression test file:**" "$SKILL" || { echo "FAIL writing-plans must require Task 1 to declare regression-test file path explicitly"; exit 1; }
echo "OK  Task 1 explicit regression-test file declaration required"

# Lock infrastructure was removed (single-session driver — no concurrency races).
if grep -qiE "lock-acquire|lock-release|\.lock\b" "$SKILL"; then
  echo "FAIL writing-plans still references lock infrastructure"
  exit 1
fi
echo "OK  no lock-infrastructure references"

# C6: must not pause to ask user about execution mode in autonomous loop.
if grep -qiE "Which approach\?|Subagent-Driven \(recommended\)" "$SKILL"; then
  echo "FAIL writing-plans still contains the vestigial 'Which approach?' user prompt"
  exit 1
fi
echo "OK  vestigial 'Which approach?' user prompt removed"

# Already-in-worktree detection: skill must skip worktree creation when cwd
# is already inside an isolated git worktree.
grep -qF "in_worktree" "$SKILL" || { echo "FAIL writing-plans missing in-worktree detection"; exit 1; }
grep -qF "git rev-parse --git-dir" "$SKILL" || { echo "FAIL writing-plans missing git-dir detection probe"; exit 1; }
grep -qF "worktree_reused" "$SKILL" || { echo "FAIL writing-plans missing worktree_reused event"; exit 1; }
echo "OK  already-in-worktree detection documented (no spurious sibling worktree creation)"

# Bugfix plans live in .bugfix/plans/, NOT docs/superpowers/plans/ (which is
# for upstream feature workflows).
grep -qF ".bugfix/plans/<ticket-id>.md" "$SKILL" || { echo "FAIL bugfix plan path missing"; exit 1; }
echo "OK  bugfix plan path is .bugfix/plans/<ticket-id>.md"

echo "PASS"
