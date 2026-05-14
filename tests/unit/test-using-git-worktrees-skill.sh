#!/usr/bin/env bash
set -euo pipefail
PLUGIN_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SKILL="$PLUGIN_ROOT/skills/using-git-worktrees/SKILL.md"

"$PLUGIN_ROOT/tests/unit/validate-skill.sh" "skills/using-git-worktrees/SKILL.md"
grep -q "^name: using-git-worktrees$" "$SKILL" || { echo "FAIL frontmatter name wrong"; exit 1; }
echo "OK  frontmatter name correct"

# The skill is documented to create a NEW branch via `-b`. The trace that
# motivated the no-improvise rule had a calling agent silently drop `-b` and
# reuse an existing branch when worktree creation failed, then re-aliased the
# main checkout as the ticket workspace. Pin the prose that forbids each of
# those fallbacks so future edits can't quietly re-permit them.
grep -qiF "creates a NEW branch" "$SKILL" \
  || { echo "FAIL using-git-worktrees must state it creates a NEW branch (not reuses existing)"; exit 1; }
echo "OK  new-branch-only contract documented"

grep -qiF "surface that error to the caller" "$SKILL" \
  || { echo "FAIL using-git-worktrees must require surfacing worktree-add failures to the caller"; exit 1; }
echo "OK  surface-failure-to-caller rule documented"

grep -qiF "Do NOT improvise" "$SKILL" \
  || { echo "FAIL using-git-worktrees must forbid improvising around worktree-add failures"; exit 1; }
echo "OK  no-improvise rule documented"

grep -qiF "Dropping the \`-b\` flag" "$SKILL" \
  || { echo "FAIL using-git-worktrees must explicitly forbid dropping -b to reuse existing branch"; exit 1; }
echo "OK  -b-drop fallback explicitly forbidden"

grep -qiF 'use the current checkout as the workspace' "$SKILL" \
  || { echo "FAIL using-git-worktrees must explicitly forbid main-checkout fallback"; exit 1; }
echo "OK  main-checkout fallback explicitly forbidden"

# The Red Flags / "Never" section must carry a matching bullet so a reader
# scanning that section gets the same prohibition without having to read the
# Creation Steps section.
awk '/^\*\*Never:\*\*/,/^\*\*Always:\*\*/' "$SKILL" | grep -qiF "Improvise around a \`git worktree add\` failure" \
  || { echo "FAIL Never-list must include 'Improvise around a git worktree add failure' bullet"; exit 1; }
echo "OK  Never-list includes worktree-add improvisation prohibition"

echo "PASS"
