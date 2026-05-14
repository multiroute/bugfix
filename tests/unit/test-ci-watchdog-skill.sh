#!/usr/bin/env bash
set -euo pipefail
PLUGIN_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SKILL="$PLUGIN_ROOT/skills/ci-watchdog/SKILL.md"

"$PLUGIN_ROOT/tests/unit/validate-skill.sh" "skills/ci-watchdog/SKILL.md"
grep -q "^name: ci-watchdog$" "$SKILL" || { echo "FAIL frontmatter name wrong"; exit 1; }
echo "OK  frontmatter name correct"

for section in \
  "## State-file-first context" \
  "## Polling loop" \
  "## On failure: fix sub-agent" \
  "## Retry policy" \
  "## State writes" \
  "## Events" \
  "## Block-and-comment exits" \
  "## Next stage"
do
  grep -q "^$section$" "$SKILL" || { echo "FAIL missing section: $section"; exit 1; }
done
echo "OK  all required sections present"

grep -qF "ticket-adapter:ci_status" "$SKILL" || { echo "FAIL missing ticket-adapter:ci_status"; exit 1; }
grep -qF "ticket-adapter:ci_watch" "$SKILL" || { echo "FAIL missing ticket-adapter:ci_watch"; exit 1; }
grep -qF "ticket-adapter:push" "$SKILL" || { echo "FAIL missing ticket-adapter:push"; exit 1; }
echo "OK  required ticket-adapter ops referenced (ci_status, ci_watch, push)"

grep -qF "implementer-prompt.md" "$SKILL" || { echo "FAIL missing implementer-prompt.md reference"; exit 1; }
echo "OK  fix sub-agent template referenced"

# Skill must instruct the agent to invoke ci_watch via run_in_background so it's
# notified on completion (replaces the prior in-session sleep polling loop).
grep -qF "run_in_background" "$SKILL" || { echo "FAIL ci_watch must be invoked via run_in_background"; exit 1; }
echo "OK  ci_watch invoked via run_in_background"

# Hard ceiling for ci_watch in minutes (replaces the 30-poll cap from the sleep-loop design).
grep -qE "120 minutes|2 hours|timeout_minutes" "$SKILL" || { echo "FAIL ci_watch timeout (120 min / 2h) not documented"; exit 1; }
echo "OK  ci_watch timeout ceiling documented"

# Deprecated polling-loop primitives must be gone.
# The earlier algorithm used `sleep sleep_seconds` inside a `while poll_n < 30:`
# counter-bounded loop. Both are forbidden now — ci_watch replaces them.
if grep -qE "while poll_n < [0-9]+:" "$SKILL"; then
  echo "FAIL ci-watchdog still contains the deprecated poll-counter loop"
  exit 1
fi
if grep -qE "^[[:space:]]*sleep sleep_seconds" "$SKILL"; then
  echo "FAIL ci-watchdog still contains 'sleep sleep_seconds' from the deprecated polling loop"
  exit 1
fi
if grep -qE "min\(sleep_seconds \* 2," "$SKILL"; then
  echo "FAIL ci-watchdog still contains the deprecated exponential-backoff calculation"
  exit 1
fi
echo "OK  deprecated polling loop removed"

grep -qF "config.retry_budgets.ci" "$SKILL" || { echo "FAIL config.retry_budgets.ci reference missing"; exit 1; }
echo "OK  retry budget referenced"

for evt in ci_failed ci_fix_attempted ci_green; do
  grep -qF "$evt" "$SKILL" || { echo "FAIL missing event $evt"; exit 1; }
done
echo "OK  events documented"

grep -qF "state.retries" "$SKILL" || { echo "FAIL retries counter missing"; exit 1; }
grep -qF 'current_stage = "pr-reviewing"' "$SKILL" || grep -qF 'current_stage: "pr-reviewing"' "$SKILL" \
  || { echo "FAIL must advance current_stage to pr-reviewing"; exit 1; }
echo "OK  state writes documented"

grep -qF "block-and-comment" "$SKILL" || { echo "FAIL block-and-comment exit missing"; exit 1; }
echo "OK  block-and-comment exits documented"

# ci-watchdog controller is mechanical enough for Haiku (informal recommendation
# for cost-tuning when the single-session driver runs); the fix sub-agent it
# dispatches is NOT Haiku — it does real implementation work.
grep -qiF "Recommended model: Haiku" "$SKILL" || { echo "FAIL ci-watchdog must recommend Haiku class for the controller"; exit 1; }
grep -qiE "fix sub-agent.*implementer|implementer.*fix sub-agent" "$SKILL" \
  || { echo "FAIL ci-watchdog must clarify that the fix sub-agent runs at implementer tier (NOT haiku)"; exit 1; }
echo "OK  Haiku recommendation for controller + implementer tier for fix sub-agent documented"

# Lock infrastructure was removed.
if grep -qiE "lock-acquire|lock-release|\.lock\b" "$SKILL"; then
  echo "FAIL ci-watchdog still references lock infrastructure"
  exit 1
fi
echo "OK  no lock-infrastructure references"

echo "PASS"
