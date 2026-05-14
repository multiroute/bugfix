#!/usr/bin/env bash
set -euo pipefail
PLUGIN_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SKILL="$PLUGIN_ROOT/skills/autonomous-finishing/SKILL.md"

"$PLUGIN_ROOT/tests/unit/validate-skill.sh" "skills/autonomous-finishing/SKILL.md"
grep -q "^name: autonomous-finishing$" "$SKILL" || { echo "FAIL frontmatter name wrong"; exit 1; }
echo "OK  frontmatter name correct"

for section in \
  "## State-file-first context" \
  "## Local test verification" \
  "## Operations called" \
  "## PR body template" \
  "## State writes" \
  "## Events" \
  "## Block-and-comment exits" \
  "## Next stage"
do
  grep -q "^$section$" "$SKILL" || { echo "FAIL missing section: $section"; exit 1; }
done
echo "OK  all required sections present"

for op in "ticket-adapter:push" "ticket-adapter:open_pr" "ticket-adapter:ticket_comment"; do
  grep -qF "$op" "$SKILL" || { echo "FAIL missing $op"; exit 1; }
done
echo "OK  required ticket-adapter ops referenced"

for evt in pr_pushed pr_opened; do
  grep -qF "$evt" "$SKILL" || { echo "FAIL missing event $evt"; exit 1; }
done
echo "OK  events documented"

grep -qF "pr_number" "$SKILL" || { echo "FAIL missing pr_number state write"; exit 1; }
echo "OK  pr_number state write documented"

grep -qF 'current_stage = "ci-watching"' "$SKILL" || grep -qF 'current_stage: "ci-watching"' "$SKILL" \
  || { echo "FAIL must advance current_stage to ci-watching"; exit 1; }
echo "OK  advances to ci-watching"

grep -qiF "refuses to proceed" "$SKILL" || grep -qiF "refuse to proceed" "$SKILL" \
  || { echo "FAIL must document refusal on failing tests"; exit 1; }
echo "OK  test-failure refusal documented"

# Lock infrastructure was removed.
if grep -qiE "lock-acquire|lock-release|\.lock\b" "$SKILL"; then
  echo "FAIL autonomous-finishing still references lock infrastructure"
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

# PR title prefix branches on classification.
grep -qF "intake_classification" "$SKILL" \
  || { echo "FAIL autonomous-finishing must reference intake_classification for PR title"; exit 1; }
echo "OK  PR title branches on classification"

grep -qF "Fix:" "$SKILL" \
  || { echo "FAIL autonomous-finishing must document 'Fix:' prefix"; exit 1; }
echo "OK  'Fix:' prefix documented"

grep -qF "Improve:" "$SKILL" \
  || { echo "FAIL autonomous-finishing must document 'Improve:' prefix"; exit 1; }
echo "OK  'Improve:' prefix documented"

# PR body regression-test paragraph must be conditional on regression_test_path.
grep -qiF "regression_test_path" "$SKILL" \
  || { echo "FAIL autonomous-finishing must reference regression_test_path for PR body branching"; exit 1; }
echo "OK  PR body regression-test paragraph is conditional"

echo "PASS"
