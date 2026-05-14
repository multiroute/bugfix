#!/usr/bin/env bash
set -euo pipefail
PLUGIN_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SKILL="$PLUGIN_ROOT/skills/block-and-comment/SKILL.md"

# Generic validator first.
"$PLUGIN_ROOT/tests/unit/validate-skill.sh" "skills/block-and-comment/SKILL.md"

# Must declare contract: Inputs, Effects, Caller obligation, Comment template.
for section in "## Contract" "## Comment template" "Inputs" "Effects" "Caller obligation"; do
  grep -q "$section" "$SKILL" || { echo "FAIL missing section: $section"; exit 1; }
done
echo "OK  contract sections present"

# Must reference the three exit_kind values.
for k in "needs-info" "rejected" "tech-failure"; do
  grep -q "\"$k\"" "$SKILL" || { echo "FAIL missing exit_kind: $k"; exit 1; }
done
echo "OK  exit_kind values present"

# Must mention the adapter ops it will call.
grep -q "ticket-adapter:ticket_comment" "$SKILL" || { echo "FAIL missing ticket-adapter:ticket_comment reference"; exit 1; }
grep -q "ticket-adapter:set_status" "$SKILL" || { echo "FAIL missing ticket-adapter:set_status reference"; exit 1; }
echo "OK  adapter operation references present"

# Must mention the lock-release step (required by spec §6.1 effects list).
grep -qi "release.*lock\|lock-release" "$SKILL" || { echo "FAIL missing lock release instruction"; exit 1; }
echo "OK  lock release mentioned"

# R3-I4: idempotency must include a concrete dedupe mechanism, not just the word.
grep -qiF "Idempotency check" "$SKILL" || { echo "FAIL missing concrete idempotency check"; exit 1; }
grep -qF "last_block_comment_id" "$SKILL" || { echo "FAIL missing dedupe key (last_block_comment_id)"; exit 1; }
echo "OK  idempotency dedupe via state.artifacts.last_block_comment_id documented"

echo "PASS"
