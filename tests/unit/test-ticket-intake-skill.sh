#!/usr/bin/env bash
set -euo pipefail
PLUGIN_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SKILL="$PLUGIN_ROOT/skills/ticket-intake/SKILL.md"

"$PLUGIN_ROOT/tests/unit/validate-skill.sh" "skills/ticket-intake/SKILL.md"
grep -q "^name: ticket-intake$" "$SKILL" || { echo "FAIL frontmatter name wrong"; exit 1; }
echo "OK  frontmatter name correct"

for section in \
  "## State-file-first context" \
  "## Operations called" \
  "## Classification rules" \
  "## Spec authoring" \
  "## State writes" \
  "## Events" \
  "## Block-and-comment exits" \
  "## Next stage"
do
  grep -q "^$section$" "$SKILL" || { echo "FAIL missing section: $section"; exit 1; }
done
echo "OK  all required sections present"

grep -qF "ticket-adapter:read" "$SKILL" || { echo "FAIL missing ticket-adapter:read"; exit 1; }
grep -qF "ticket-adapter:set_status" "$SKILL" || { echo "FAIL missing ticket-adapter:set_status"; exit 1; }
echo "OK  ticket-adapter operations referenced"

for cls in bug improvement not-actionable; do
  grep -qF "\`$cls\`" "$SKILL" || { echo "FAIL missing classification: $cls"; exit 1; }
done
echo "OK  classification trichotomy documented"

for evt in intake_started intake_passed intake_blocked; do
  grep -qF "$evt" "$SKILL" || { echo "FAIL missing event: $evt"; exit 1; }
done
echo "OK  events documented"

grep -qF "needs-info" "$SKILL" || { echo "FAIL missing needs-info exit"; exit 1; }
grep -qF "rejected" "$SKILL" || { echo "FAIL missing rejected exit"; exit 1; }
echo "OK  block exit kinds documented"

grep -qF "current_stage = \"planning\"" "$SKILL" || grep -qF 'current_stage: "planning"' "$SKILL" \
  || { echo "FAIL must advance current_stage to planning"; exit 1; }
echo "OK  advances to planning stage"

grep -qF "spec_path" "$SKILL" || { echo "FAIL missing spec_path state write"; exit 1; }
echo "OK  spec_path state write documented"

# Stage is mechanical enough for Haiku — recommendation must be documented
# so external schedulers can route via config.model_hints.stages.intake.
grep -qiF "Recommended model: Haiku" "$SKILL" || { echo "FAIL ticket-intake must recommend Haiku class"; exit 1; }
grep -qF "config.model_hints.stages.intake" "$SKILL" || { echo "FAIL ticket-intake must reference the stage model-hint config key"; exit 1; }
echo "OK  Haiku recommendation + model-hint config key documented"

# Improvement classification must route to spec writing, not block-and-comment.
grep -qF "classification == \"improvement\"" "$SKILL" \
  || { echo "FAIL intake must reference improvement classification"; exit 1; }
echo "OK  intake handles improvement classification"

# Improvement spec template must be documented.
grep -qF "## Desired outcome" "$SKILL" \
  || { echo "FAIL intake missing improvement-spec template '## Desired outcome' section"; exit 1; }
echo "OK  improvement spec template documented"

grep -qF "## Rationale" "$SKILL" \
  || { echo "FAIL intake missing improvement-spec template '## Rationale' section"; exit 1; }
echo "OK  improvement Rationale section documented"

# Classification line must appear in both templates.
grep -qF "**Classification:**" "$SKILL" \
  || { echo "FAIL intake spec templates must include Classification frontmatter line"; exit 1; }
echo "OK  Classification line documented"

# Block-and-comment table must no longer say improvement -> rejected.
block_table_section="$(awk '/^## Block-and-comment exits$/,/^## /' "$SKILL")"
if echo "$block_table_section" | grep -iF "classification = \`improvement\`" >/dev/null; then
  echo "FAIL block-and-comment table still mentions improvement classification"
  exit 1
fi
echo "OK  block-and-comment table no longer routes improvements"

# STAGE COMPLETE footer must be present and contain the STOP HERE directive.
grep -qF "## STAGE COMPLETE — STOP HERE" "$SKILL" \
  || { echo "FAIL missing STAGE COMPLETE footer header"; exit 1; }
echo "OK  STAGE COMPLETE footer header present"

grep -qF "you violate the loop contract" "$SKILL" \
  || { echo "FAIL STAGE COMPLETE footer missing 'violate the loop contract' directive"; exit 1; }
echo "OK  STAGE COMPLETE footer contains loop-contract directive"

echo "PASS"
