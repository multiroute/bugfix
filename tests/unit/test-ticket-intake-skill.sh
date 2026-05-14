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

# Stage is mechanical enough for Haiku — informal recommendation stays as guidance
# for the single-session driver to consider its costs.
grep -qiF "Recommended model: Haiku" "$SKILL" || { echo "FAIL ticket-intake must recommend Haiku class"; exit 1; }
echo "OK  Haiku recommendation documented"

# Lock infrastructure was removed (single-session driver — no concurrency races).
if grep -qiE "lock-acquire|lock-release|\.lock" "$SKILL"; then
  echo "FAIL ticket-intake still references lock infrastructure after locks were removed"
  exit 1
fi
echo "OK  no lock-infrastructure references"

echo "PASS"
