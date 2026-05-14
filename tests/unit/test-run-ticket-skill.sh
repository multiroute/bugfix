#!/usr/bin/env bash
set -euo pipefail
PLUGIN_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SKILL="$PLUGIN_ROOT/skills/run-ticket/SKILL.md"

# Generic validator first (frontmatter + no superpowers: leaks).
"$PLUGIN_ROOT/tests/unit/validate-skill.sh" "skills/run-ticket/SKILL.md"

# Frontmatter must declare the right name.
grep -q "^name: run-ticket$" "$SKILL" || { echo "FAIL frontmatter name wrong"; exit 1; }
echo "OK  frontmatter name correct"

# Description must include all three trigger phrases and call out GitHub issue URL.
desc_line="$(grep -m1 "^description:" "$SKILL")"
for phrase in "fix bug" "fix issue" "resolve issue" "GitHub issue URL"; do
  echo "$desc_line" | grep -q -- "$phrase" || { echo "FAIL description missing '$phrase'"; exit 1; }
done
echo "OK  description carries all triggers"

# Body must reference the URL regex prefix.
grep -q "https://github.com/" "$SKILL" || { echo "FAIL body missing github.com URL reference"; exit 1; }
echo "OK  URL pattern present in body"

# R3-I3: regex must be fully anchored and charset-validated (no path traversal smuggling).
grep -qF "^https://github" "$SKILL" || { echo "FAIL URL regex must be ^-anchored"; exit 1; }
grep -qF '/?$' "$SKILL" || { echo "FAIL URL regex must have trailing-slash anchor"; exit 1; }
grep -qF "[A-Za-z0-9._-]+" "$SKILL" || { echo "FAIL owner/repo charset constraint missing"; exit 1; }
echo "OK  URL regex anchored and charset-validated"

# Body must document URL rejection cases (PR URLs and non-github hosts).
grep -q "/pull/" "$SKILL" || { echo "FAIL body missing PR-URL rejection rule"; exit 1; }
grep -q "non-" "$SKILL" || { echo "FAIL body missing non-github-host rejection rule"; exit 1; }
echo "OK  URL rejection rules documented"

# Body must describe the real driver behavior (Increment 3).
grep -qF "state-file" "$SKILL" || grep -qF "state file" "$SKILL" \
  || { echo "FAIL body missing state-file reference"; exit 1; }
echo "OK  state-file driver behavior described"

# Body must reference state initialization on first invocation.
grep -qF "current_stage" "$SKILL" || { echo "FAIL body missing current_stage init reference"; exit 1; }
grep -qF '"intake"' "$SKILL" || { echo "FAIL body missing initial stage='intake'"; exit 1; }
echo "OK  state initialization documented"

# Body must reference resume-run loop.
grep -qF "resume-run" "$SKILL" || { echo "FAIL body missing resume-run reference"; exit 1; }
echo "OK  resume-run loop referenced"

# Body must reference terminal-state exit.
grep -qiF "terminal" "$SKILL" || { echo "FAIL body missing terminal-state exit reference"; exit 1; }
echo "OK  terminal-state exit documented"

# run-ticket must use the .bugfix/ runtime tree, not docs/superpowers/.
# Bug-fix runs are operational data; specs and plans for bugs live in
# .bugfix/{specs,plans}/, not docs/superpowers/{specs,plans}/ (which is for
# feature work).
if grep -qE "docs/superpowers/(specs|plans)/" "$SKILL"; then
  echo "FAIL body references docs/superpowers/{specs,plans}/ — bugfix runs use .bugfix/{specs,plans}/"
  exit 1
fi
echo "OK  body uses .bugfix/ runtime tree (no docs/superpowers/ refs)"

grep -qF ".bugfix/runs/" "$SKILL" || { echo "FAIL body must reference .bugfix/runs/ state path"; exit 1; }
echo "OK  body references .bugfix/runs/ state path"

# Pin the EXACT description string so a future increment rewrite doesn't
# silently break the user-facing trigger contract. The skill's own
# Forward-compatibility note tells the next implementer: frontmatter
# (especially description) MUST stay stable. This test enforces it.
expected_description='description: Use when the user asks to fix a bug or resolve an issue referenced by a GitHub issue URL (e.g., "fix bug https://github.com/owner/repo/issues/N", "fix issue <url>", "resolve issue <url>"). Front-door entry point for the autonomous bug-fix loop.'
actual_description="$(grep -m1 "^description:" "$SKILL")"
if [[ "$actual_description" != "$expected_description" ]]; then
  echo "FAIL run-ticket description string drifted"
  echo "expected: $expected_description"
  echo "actual:   $actual_description"
  exit 1
fi
echo "OK  description string pinned exactly"

echo "PASS"
