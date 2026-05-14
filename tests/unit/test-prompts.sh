#!/usr/bin/env bash
set -euo pipefail
PLUGIN_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PROMPTS="$PLUGIN_ROOT/skills/_prompts"

for f in \
  implementer-prompt.md \
  spec-reviewer-prompt.md \
  code-quality-reviewer-prompt.md \
  implementer-retry-prompt.md \
  plan-document-reviewer-prompt.md \
  pr-final-reviewer-prompt.md
do
  [[ -f "$PROMPTS/$f" ]] || { echo "FAIL prompt missing: $f"; exit 1; }
done
echo "OK  all 6 prompt files exist"

grep -q "^# Implementer Subagent Prompt Template$" "$PROMPTS/implementer-prompt.md" \
  || { echo "FAIL implementer-prompt.md missing upstream header"; exit 1; }
grep -q "^# Spec Compliance Reviewer Prompt Template$" "$PROMPTS/spec-reviewer-prompt.md" \
  || { echo "FAIL spec-reviewer-prompt.md missing upstream header"; exit 1; }
grep -q "^# Code Quality Reviewer Prompt Template$" "$PROMPTS/code-quality-reviewer-prompt.md" \
  || { echo "FAIL code-quality-reviewer-prompt.md missing upstream header"; exit 1; }
echo "OK  vendored prompts have correct headers"

for f in implementer-prompt.md spec-reviewer-prompt.md code-quality-reviewer-prompt.md; do
  if grep -q "superpowers:" "$PROMPTS/$f"; then
    echo "FAIL $f leaks 'superpowers:' reference"
    grep -n "superpowers:" "$PROMPTS/$f"
    exit 1
  fi
done
echo "OK  no superpowers: leaks in vendored prompts"

grep -q "^# Implementer Subagent (Retry) Prompt Template$" "$PROMPTS/implementer-retry-prompt.md" \
  || { echo "FAIL implementer-retry-prompt.md missing header"; exit 1; }
grep -qF "<<<INSERT_VERDICT_HERE>>>" "$PROMPTS/implementer-retry-prompt.md" \
  || { echo "FAIL implementer-retry-prompt.md missing verdict placeholder"; exit 1; }
grep -qF "model_hints.implementer" "$PROMPTS/implementer-retry-prompt.md" \
  || { echo "FAIL implementer-retry-prompt.md missing model-hint reference"; exit 1; }
echo "OK  implementer-retry-prompt.md correct"

grep -q "^# Plan Document Reviewer Subagent Prompt Template$" "$PROMPTS/plan-document-reviewer-prompt.md" \
  || { echo "FAIL plan-document-reviewer-prompt.md missing header"; exit 1; }
grep -qF "<<<SPEC_PATH>>>" "$PROMPTS/plan-document-reviewer-prompt.md" \
  || { echo "FAIL plan-document-reviewer-prompt.md missing SPEC_PATH placeholder"; exit 1; }
grep -qF "<<<PLAN_PATH>>>" "$PROMPTS/plan-document-reviewer-prompt.md" \
  || { echo "FAIL plan-document-reviewer-prompt.md missing PLAN_PATH placeholder"; exit 1; }
grep -qF "Plan compliant" "$PROMPTS/plan-document-reviewer-prompt.md" \
  || { echo "FAIL plan-document-reviewer-prompt.md missing 'Plan compliant' verdict"; exit 1; }
echo "OK  plan-document-reviewer-prompt.md correct"


grep -q "^# PR Final Review Prompt Template$" "$PROMPTS/pr-final-reviewer-prompt.md" \
  || { echo "FAIL pr-final-reviewer-prompt.md missing header"; exit 1; }
for placeholder in "<<<TICKET_BODY>>>" "<<<SPEC_CONTENTS>>>" "<<<PLAN_CONTENTS>>>" "<<<DIFF>>>" "<<<REGRESSION_TEST_PATH>>>" "<<<BASE_SHA>>>" "<<<PR_BRANCH>>>" "<<<CI_SUMMARY>>>"; do
  grep -qF "$placeholder" "$PROMPTS/pr-final-reviewer-prompt.md" \
    || { echo "FAIL pr-final-reviewer-prompt.md missing placeholder $placeholder"; exit 1; }
done
grep -qF "Critical findings:" "$PROMPTS/pr-final-reviewer-prompt.md" \
  || { echo "FAIL pr-final-reviewer-prompt.md missing 'Critical findings:' output"; exit 1; }
grep -qF "Important findings:" "$PROMPTS/pr-final-reviewer-prompt.md" \
  || { echo "FAIL pr-final-reviewer-prompt.md missing 'Important findings:' output"; exit 1; }
for kw in "Scope creep" "Weak regression test" "Missing adjacent regression coverage" "doesn't address symptom" "Unrelated changes" "Security" "Performance" "Commit hygiene" "Untrusted-input handling"; do
  grep -qF "$kw" "$PROMPTS/pr-final-reviewer-prompt.md" \
    || { echo "FAIL pr-final-reviewer-prompt.md missing failure-mode '$kw'"; exit 1; }
done
echo "OK  pr-final-reviewer-prompt.md correct"

# R2-I1: every implementer/reviewer prompt must include the untrusted-input preamble.
# A ticket-derived spec/plan/comment flows transitively into these prompts; without
# an explicit rule the sub-agent can be prompt-injected via the ticket body.
for f in \
  implementer-prompt.md \
  spec-reviewer-prompt.md \
  code-quality-reviewer-prompt.md \
  implementer-retry-prompt.md \
  plan-document-reviewer-prompt.md \
  pr-final-reviewer-prompt.md
do
  if ! grep -qiE "untrusted-input|<untrusted-input>" "$PROMPTS/$f"; then
    echo "FAIL $f missing untrusted-input preamble"
    exit 1
  fi
done
echo "OK  all 6 implementer/reviewer prompts include untrusted-input preamble"

echo "PASS"
