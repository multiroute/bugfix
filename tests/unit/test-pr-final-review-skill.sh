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
  "## Step 2: Gather inputs for reviewers" \
  "## Step 3: Dispatch advocate + adversary in parallel" \
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

for tmpl in pr-final-reviewer-advocate-prompt.md pr-final-reviewer-adversary-prompt.md; do
  grep -qF "$tmpl" "$SKILL" || { echo "FAIL missing reference to $tmpl"; exit 1; }
done
echo "OK  reviewer prompt templates referenced"

grep -qF "dispatching-parallel-agents" "$SKILL" || { echo "FAIL missing dispatching-parallel-agents reference"; exit 1; }
echo "OK  parallel dispatch helper referenced"

grep -qF "merge-ready" "$SKILL" || { echo "FAIL missing merge-ready outcome"; exit 1; }
grep -qF "pr-closed" "$SKILL" || { echo "FAIL missing pr-closed outcome"; exit 1; }
grep -qF "block-and-comment" "$SKILL" || { echo "FAIL missing block-and-comment outcome"; exit 1; }
echo "OK  all three decision-rule outcomes documented"

for knob in "adversary_enabled" "important_findings_block" "advocate_must_run_regression_test"; do
  grep -qF "$knob" "$SKILL" || { echo "FAIL missing config knob $knob"; exit 1; }
done
echo "OK  config knobs documented"

for evt in pr_rebased pr_review_started pr_review_blocked pr_merge_ready pr_closed; do
  grep -qF "$evt" "$SKILL" || { echo "FAIL missing event $evt"; exit 1; }
done
echo "OK  events documented"

grep -qF 'state.terminal = "merge-ready"' "$SKILL" || grep -qF 'terminal: "merge-ready"' "$SKILL" \
  || { echo "FAIL must set terminal to merge-ready"; exit 1; }
grep -qF 'state.terminal = "pr-closed"' "$SKILL" || grep -qF 'terminal: "pr-closed"' "$SKILL" \
  || { echo "FAIL must set terminal to pr-closed"; exit 1; }
echo "OK  terminal values documented"

grep -qF "advocate_verdict" "$SKILL" || { echo "FAIL missing advocate_verdict artifact"; exit 1; }
grep -qF "adversary_verdict" "$SKILL" || { echo "FAIL missing adversary_verdict artifact"; exit 1; }
echo "OK  verdict artifacts documented"

if ! grep -qiE "no auto-retry|never auto-retry|never retry|do not retry|no retry" "$SKILL"; then
  echo "FAIL must document no-auto-retry policy"
  exit 1
fi
echo "OK  no-auto-retry rule documented"

grep -qF "ready-for-merge" "$SKILL" || { echo "FAIL missing ready-for-merge status reference"; exit 1; }
echo "OK  ready-for-merge status documented"

# C5: silence-is-consent must be flipped. Under parallel dispatch the advocate
# writes its verdict without seeing the adversary's, so silence is uninformative
# — auto-close requires explicit advocate-side confirmation.
if grep -qiF "silence is consent" "$SKILL"; then
  echo "FAIL silence-is-consent rule still present; must be flipped to silence-routes-to-needs-info"
  exit 1
fi
grep -qiE "silence is NOT consent|silence on those findings is NOT" "$SKILL" || {
  echo "FAIL must explicitly document that silence is NOT consent"
  exit 1
}
grep -qiF "explicitly counters" "$SKILL" || {
  echo "FAIL adversary-critical auto-close must require advocate to explicitly counter (not just be silent)"
  exit 1
}
echo "OK  silence-is-consent flipped (silence routes to needs-info, auto-close requires explicit counter)"

# Verify row 4 (auto-close) is conditioned on "explicitly counters" and row 5
# (block needs-info) catches "disputes or silent".
grep -qF "advocate **explicitly counters**" "$SKILL" || { echo "FAIL row 4 must require explicit counter"; exit 1; }
grep -qF "advocate **disputes or silent**"  "$SKILL" || { echo "FAIL row 5 must catch disputes-or-silent"; exit 1; }
echo "OK  decision-rule rows 4 and 5 distinguish explicit-counter vs disputes-or-silent"

echo "PASS"
