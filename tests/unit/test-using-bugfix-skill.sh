#!/usr/bin/env bash
set -euo pipefail
PLUGIN_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SKILL="$PLUGIN_ROOT/skills/using-bugfix/SKILL.md"

# Generic validator first.
"$PLUGIN_ROOT/tests/unit/validate-skill.sh" "skills/using-bugfix/SKILL.md"

# Must mention each catalog skill so agents can discover them.
for s in \
  "run-ticket" \
  "ticket-intake" \
  "writing-plans" \
  "executing-plan" \
  "autonomous-finishing" \
  "ci-watchdog" \
  "pr-final-review" \
  "ticket-adapter" \
  "block-and-comment" \
  "using-git-worktrees" \
  "test-driven-development" \
  "systematic-debugging" \
  "verification-before-completion" \
  "receiving-code-review" \
  "requesting-code-review" \
  "dispatching-parallel-agents"
do
  grep -q "bugfix:$s" "$SKILL" || { echo "FAIL using-bugfix doesn't reference bugfix:$s"; exit 1; }
done
echo "OK  catalog references present"

# resume-run was folded into run-ticket; using-bugfix must not reference the deleted skill.
if grep -qF "bugfix:resume-run" "$SKILL"; then
  echo "FAIL using-bugfix still references the deleted bugfix:resume-run skill"
  exit 1
fi
echo "OK  no references to deleted bugfix:resume-run"

# Must declare frontmatter name=using-bugfix.
grep -q "^name: using-bugfix$" "$SKILL" || { echo "FAIL frontmatter name wrong"; exit 1; }

# Must instruct the agent to route matching requests to bugfix:run-ticket
# rather than pre-empting with a "not yet implemented" reply.
grep -q "Routing rule" "$SKILL" || { echo "FAIL missing 'Routing rule' header"; exit 1; }
grep -q "invoke \`bugfix:run-ticket\`" "$SKILL" || { echo "FAIL missing routing instruction"; exit 1; }
echo "OK  routing rule pinned"

# Must NOT claim bugfix:run-ticket is unimplemented (it ships as a stub today).
if grep -E "run-ticket[^a-zA-Z\`]*(is not implemented|NOT yet implemented|not yet implemented)" "$SKILL"; then
  echo "FAIL using-bugfix still claims run-ticket is unimplemented"
  exit 1
fi

# Also: body must NOT advertise run-ticket as a "stub" anymore (Increment 3 replaced the stub).
if grep -qF "Increment 1 stub" "$SKILL"; then
  echo "FAIL using-bugfix still calls run-ticket an 'Increment 1 stub'"
  exit 1
fi
echo "OK  run-ticket no longer marked as Increment 1 stub"

echo "OK  run-ticket is not falsely marked unimplemented"

grep -qF "## Loop discipline" "$SKILL" \
  || { echo "FAIL using-bugfix missing 'Loop discipline' section"; exit 1; }
echo "OK  Loop discipline section present"

grep -qF "exactly one dispatcher" "$SKILL" \
  || { echo "FAIL using-bugfix Loop discipline section must say 'exactly one dispatcher'"; exit 1; }
echo "OK  Loop discipline pins 'exactly one dispatcher'"

grep -qF "violates the loop contract" "$SKILL" \
  || { echo "FAIL using-bugfix Loop discipline section must include 'violates the loop contract' directive"; exit 1; }
echo "OK  Loop discipline includes 'violates the loop contract'"

echo "PASS"
