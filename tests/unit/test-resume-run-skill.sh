#!/usr/bin/env bash
set -euo pipefail
PLUGIN_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SKILL="$PLUGIN_ROOT/skills/resume-run/SKILL.md"

"$PLUGIN_ROOT/tests/unit/validate-skill.sh" "skills/resume-run/SKILL.md"
grep -q "^name: resume-run$" "$SKILL" || { echo "FAIL frontmatter name wrong"; exit 1; }
echo "OK  frontmatter name correct"

for section in \
  "## Contract" \
  "## Stage-to-skill mapping" \
  "## Skill-not-implemented handling" \
  "## Resume-from-blocked detection" \
  "## Operation order"
do
  grep -q "^$section$" "$SKILL" || { echo "FAIL missing section: $section"; exit 1; }
done
echo "OK  all required sections present"

# Stage-to-skill mapping table must contain all 6 stages.
for stage in intake planning executing finishing ci-watching pr-reviewing; do
  grep -qF "\`$stage\`" "$SKILL" || { echo "FAIL stage mapping missing: $stage"; exit 1; }
done
echo "OK  all 6 stages in mapping table"

# Skill-not-implemented terminal state.
grep -qF "stage-not-implemented" "$SKILL" || { echo "FAIL missing 'stage-not-implemented' terminal"; exit 1; }
echo "OK  stage-not-implemented terminal documented"

# Resume-from-blocked checks for non-bot author.
grep -qF "is_bot" "$SKILL" || { echo "FAIL missing is_bot bot-filter rule"; exit 1; }
grep -qiF "resume" "$SKILL" || { echo "FAIL missing 'resume' token rule"; exit 1; }
echo "OK  resume-from-blocked detection documented"

# Lock ops referenced.
grep -qF "lock-acquire.sh" "$SKILL" || { echo "FAIL missing lock-acquire reference"; exit 1; }
grep -qF "lock-release.sh" "$SKILL" || { echo "FAIL missing lock-release reference"; exit 1; }
echo "OK  lock primitives referenced"

# Does NOT loop (single-stage dispatch).
grep -qiF "does not loop" "$SKILL" || grep -qiF "one stage per invocation" "$SKILL" || grep -qiF "exactly one stage" "$SKILL" \
  || { echo "FAIL must document single-stage-per-invocation contract"; exit 1; }
echo "OK  single-stage contract documented"

# External schedulers must know how to pick model per stage.
grep -qF "Per-stage model hints" "$SKILL" || { echo "FAIL must document per-stage model-hint contract for external schedulers"; exit 1; }
grep -qF "config.model_hints.stages" "$SKILL" || { echo "FAIL must reference config.model_hints.stages"; exit 1; }
echo "OK  per-stage model-hint contract documented"

grep -qF "dispatches exactly one stage skill" "$SKILL" \
  || { echo "FAIL resume-run missing single-dispatcher framing"; exit 1; }
echo "OK  single-dispatcher framing present"

echo "PASS"
