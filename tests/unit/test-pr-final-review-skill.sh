#!/usr/bin/env bash
set -euo pipefail
PLUGIN_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SKILL="$PLUGIN_ROOT/skills/pr-final-review/SKILL.md"

"$PLUGIN_ROOT/tests/unit/validate-skill.sh" "skills/pr-final-review/SKILL.md"
grep -q "^name: pr-final-review$" "$SKILL" || { echo "FAIL frontmatter name wrong"; exit 1; }
echo "OK  frontmatter name correct"

for section in \
  "## State-file-first context" \
  "## Step 1: Rebase" \
  "## Step 2: Gather inputs for the reviewer" \
  "## Step 3: Dispatch the reviewer" \
  "## Step 4: Apply decision rule" \
  "## Step 5: Apply terminal action" \
  "## Configuration knobs" \
  "## State writes" \
  "## Events" \
  "## Block-and-comment exits" \
  "## Next stage"
do
  grep -q "^$section$" "$SKILL" || { echo "FAIL missing section: $section"; exit 1; }
done
echo "OK  all required sections present"

for op in "ticket-adapter:rebase_pr" "ticket-adapter:pr_close" "ticket-adapter:pr_comment" "ticket-adapter:ticket_comment" "ticket-adapter:set_status" "ticket-adapter:ci_status"; do
  grep -qF "$op" "$SKILL" || { echo "FAIL missing $op"; exit 1; }
done
echo "OK  all required ticket-adapter ops referenced"

grep -qF "pr-final-reviewer-prompt.md" "$SKILL" || { echo "FAIL missing reference to pr-final-reviewer-prompt.md"; exit 1; }
echo "OK  reviewer prompt template referenced"

# Old prompt names and the parallel-dispatch helper must be gone.
for forbidden in "pr-final-reviewer-advocate-prompt.md" "pr-final-reviewer-adversary-prompt.md" "dispatching-parallel-agents" "advocate" "adversary"; do
  if grep -qiF "$forbidden" "$SKILL"; then
    echo "FAIL SKILL still references '$forbidden'"
    grep -niF "$forbidden" "$SKILL"
    exit 1
  fi
done
echo "OK  no advocate/adversary/parallel-dispatch references remain"

grep -qF "merge-ready" "$SKILL" || { echo "FAIL missing merge-ready outcome"; exit 1; }
grep -qF "pr-closed" "$SKILL" || { echo "FAIL missing pr-closed outcome"; exit 1; }
grep -qF "block-and-comment" "$SKILL" || { echo "FAIL missing block-and-comment outcome"; exit 1; }
echo "OK  all required decision-rule outcomes documented"

for knob in "important_findings_block" "reviewer_must_run_regression_test"; do
  grep -qF "$knob" "$SKILL" || { echo "FAIL missing config knob $knob"; exit 1; }
done
echo "OK  config knobs documented"

# Old knobs must be gone.
for old_knob in "adversary_enabled" "advocate_must_run_regression_test"; do
  if grep -qF "$old_knob" "$SKILL"; then
    echo "FAIL SKILL still references removed knob $old_knob"
    exit 1
  fi
done
echo "OK  removed knobs no longer referenced"

for evt in pr_rebased pr_review_started pr_merge_ready pr_closed; do
  grep -qF "$evt" "$SKILL" || { echo "FAIL missing event $evt"; exit 1; }
done
echo "OK  events documented"

if grep -qF "pr_review_blocked" "$SKILL"; then
  echo "FAIL SKILL still references removed event pr_review_blocked"
  exit 1
fi
echo "OK  pr_review_blocked event no longer referenced"

grep -qF 'state.terminal = "merge-ready"' "$SKILL" || grep -qF 'terminal: "merge-ready"' "$SKILL" \
  || { echo "FAIL must set terminal to merge-ready"; exit 1; }
grep -qF 'state.terminal = "pr-closed"' "$SKILL" || grep -qF 'terminal: "pr-closed"' "$SKILL" \
  || { echo "FAIL must set terminal to pr-closed"; exit 1; }
echo "OK  terminal values documented"

grep -qF "review_verdict" "$SKILL" || { echo "FAIL missing review_verdict artifact"; exit 1; }
echo "OK  verdict artifact documented"

if ! grep -qiE "no auto-retry|never auto-retry|never retry|do not retry|no retry" "$SKILL"; then
  echo "FAIL must document no-auto-retry policy"
  exit 1
fi
echo "OK  no-auto-retry rule documented"

grep -qF "ready-for-merge" "$SKILL" || { echo "FAIL missing ready-for-merge status reference"; exit 1; }
echo "OK  ready-for-merge status documented"

# Lock infrastructure was removed in a prior cycle and must stay removed.
if grep -qiE "lock-acquire|lock-release|\.lock\b" "$SKILL"; then
  echo "FAIL pr-final-review still references lock infrastructure"
  exit 1
fi
echo "OK  no lock-infrastructure references"

# Reviewer prompt must branch on classification.
grep -qF "intake_classification" "$SKILL" \
  || { echo "FAIL pr-final-review must reference intake_classification"; exit 1; }
echo "OK  reviewer prompt branches on classification"

# Bug-class reviewer check (carried over from prior adversary content).
grep -qiF "is the regression test real" "$SKILL" \
  || { echo "FAIL reviewer prompt missing 'is the regression test real' (bug class)"; exit 1; }
echo "OK  bug-class reviewer check documented"

# Improvement-class reviewer check.
grep -qiF "free of regressions" "$SKILL" \
  || { echo "FAIL reviewer prompt missing 'free of regressions' (improvement class)"; exit 1; }
echo "OK  improvement-class reviewer check documented"

# Empirical regression-test base-vs-tip check is the unique signal that
# justifies dropping the advocate; the SKILL must describe it.
grep -qiF "git checkout" "$SKILL" \
  || { echo "FAIL SKILL must describe the empirical base-vs-tip regression-test check"; exit 1; }
echo "OK  empirical regression-test check documented"

# Backend-routed diff retrieval.
grep -qF "adapter_backend" "$SKILL" \
  || { echo "FAIL pr-final-review must reference adapter_backend for diff retrieval"; exit 1; }
echo "OK  diff retrieval routes on adapter_backend"

# STAGE COMPLETE footer.
grep -qF "## STAGE COMPLETE — STOP HERE" "$SKILL" \
  || { echo "FAIL missing STAGE COMPLETE footer header"; exit 1; }
echo "OK  STAGE COMPLETE footer header present"

grep -qF "you violate the loop contract" "$SKILL" \
  || { echo "FAIL STAGE COMPLETE footer missing 'violate the loop contract' directive"; exit 1; }
echo "OK  STAGE COMPLETE footer contains loop-contract directive"

# Merge-ready PR/ticket comments must remain conditional on regression_test_path.
grep -qiF "regression_test_path" "$SKILL" \
  || { echo "FAIL pr-final-review must reference regression_test_path for comment branching"; exit 1; }
echo "OK  pr-final-review references regression_test_path"

grep -qiF "omit the paragraph" "$SKILL" \
  || grep -qiF "when regression_test_path is null" "$SKILL" \
  || grep -qiF "rendered ONLY when" "$SKILL" \
  || { echo "FAIL pr-final-review must document null-handling for regression_test_path"; exit 1; }
echo "OK  pr-final-review documents conditional comment handling"

echo "PASS"
