#!/usr/bin/env bash
set -euo pipefail
PLUGIN_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SKILL="$PLUGIN_ROOT/skills/ticket-adapter/SKILL.md"

# Generic validator first (frontmatter + no superpowers: leaks).
"$PLUGIN_ROOT/tests/unit/validate-skill.sh" "skills/ticket-adapter/SKILL.md"

# Frontmatter must declare the right name.
grep -q "^name: ticket-adapter$" "$SKILL" || { echo "FAIL frontmatter name wrong"; exit 1; }
echo "OK  frontmatter name correct"

# Description must mention gh and GitHub (to make the trigger discoverable).
desc_line="$(grep -m1 "^description:" "$SKILL")"
echo "$desc_line" | grep -qE '`gh`|MCP' || { echo "FAIL description must mention gh or MCP"; exit 1; }
echo "OK  description mentions gh or MCP"
echo "$desc_line" | grep -qi "github" || { echo "FAIL description must mention GitHub"; exit 1; }
echo "OK  description names GitHub"

# Required top-level sections.
for section in \
  "## Backend selection" \
  "## Argument validation" \
  "## Untrusted-input rule" \
  "## Bot-author detection" \
  "## Operations" \
  "## Errors"
do
  grep -q "^$section$" "$SKILL" || { echo "FAIL missing section: $section"; exit 1; }
done
echo "OK  all required sections present"

# C7: argument validation must require integer-typed placeholders.
grep -qE 'issue_number.*=~.*\^\[0-9\]\+\$' "$SKILL" || { echo "FAIL missing issue_number integer validation"; exit 1; }
grep -qE 'pr_number.*=~.*\^\[0-9\]\+\$'    "$SKILL" || { echo "FAIL missing pr_number integer validation"; exit 1; }
grep -qE 'run_id.*=~.*\^\[0-9\]\+\$'       "$SKILL" || { echo "FAIL missing run_id integer validation"; exit 1; }
grep -qF '"$branch" != -*' "$SKILL" || { echo "FAIL missing branch leading-dash rejection"; exit 1; }
echo "OK  argument validation rules documented (integers + git refs)"

# C8: untrusted-input wrap must include closing-tag balance check and length cap.
grep -qiF "closing-tag balance" "$SKILL" || { echo "FAIL missing closing-tag balance rule"; exit 1; }
grep -qF "32768" "$SKILL" || { echo "FAIL missing length cap"; exit 1; }
grep -qF "author_login" "$SKILL" || { echo "FAIL author_login not wrapped"; exit 1; }
echo "OK  closing-tag balance + length cap + author_login wrap documented"

# C9: bot detection must cover all three rules (suffix, authorAssociation, allowlist).
grep -qF "bot_author_allowlist" "$SKILL" || { echo "FAIL missing config.bot_author_allowlist reference"; exit 1; }
grep -qF "case-sensitive" "$SKILL" || { echo "FAIL missing authorAssociation case-sensitivity note"; exit 1; }
echo "OK  bot detection covers suffix + authorAssociation + allowlist"

# C9: resume token must be first-word, not substring.
grep -qF "first non-whitespace" "$SKILL" || { echo "FAIL resume token rule missing first-non-whitespace requirement"; exit 1; }
echo "OK  resume token defined as first-word match"

# New section after Fix 1: identifier/repo-targeting contract.
grep -q "^## Issue/PR identifiers and repo targeting$" "$SKILL" || { echo "FAIL missing 'Issue/PR identifiers and repo targeting' section"; exit 1; }
echo "OK  identifier section present"

# Preflight references both required commands.
grep -q "command -v gh" "$SKILL" || { echo "FAIL preflight missing 'command -v gh'"; exit 1; }
grep -q "gh auth status" "$SKILL" || { echo "FAIL preflight missing 'gh auth status'"; exit 1; }
echo "OK  preflight commands documented"

# Each of the 11 operations has its own ### subsection.
for op in read ticket_comment set_status list_ready push open_pr pr_comment pr_close ci_status ci_watch rebase_pr; do
  grep -q "^### $op$" "$SKILL" || { echo "FAIL missing operation section: ### $op"; exit 1; }
done
echo "OK  all 11 operation sections present"

# Each gh-based operation references its gh verb (push is the only non-gh op).
for verb in "gh issue view" "gh issue comment" "gh issue edit" "gh issue list" "gh pr create" "gh pr comment" "gh pr close" "gh pr checks" "gh pr checkout"; do
  grep -qF "$verb" "$SKILL" || { echo "FAIL operation missing '$verb' command"; exit 1; }
done
echo "OK  all gh command verbs documented"

# ci_watch must invoke gh pr checks with --watch and --fail-fast.
grep -qF "gh pr checks" "$SKILL" || { echo "FAIL ci_watch missing 'gh pr checks'"; exit 1; }
grep -qF -- "--watch" "$SKILL" || { echo "FAIL ci_watch missing '--watch' flag"; exit 1; }
grep -qF -- "--fail-fast" "$SKILL" || { echo "FAIL ci_watch missing '--fail-fast' flag"; exit 1; }
echo "OK  ci_watch uses gh pr checks --watch --fail-fast"

# ci_watch documents the run_in_background invocation pattern (so callers get notified).
grep -qF "run_in_background" "$SKILL" || { echo "FAIL ci_watch must document run_in_background invocation"; exit 1; }
echo "OK  ci_watch documents run_in_background invocation pattern"

# Push op uses git, not gh (it's the documented exception).
grep -qF "git push -u origin" "$SKILL" || { echo "FAIL push operation must use 'git push -u origin'"; exit 1; }
echo "OK  push uses git, not gh"

# Untrusted-input wrapping applied at least twice (title/body of read, plus comments).
ui_count="$(grep -c "untrusted-input" "$SKILL" || true)"
[[ "$ui_count" -ge 2 ]] || { echo "FAIL untrusted-input mentioned $ui_count times, expected >= 2"; exit 1; }
echo "OK  untrusted-input wrapping pinned ($ui_count occurrences)"

# Bot-author detection covers both conditions: [bot] suffix AND authorAssociation == BOT.
grep -qF "[bot]" "$SKILL" || { echo "FAIL bot detection missing '[bot]' suffix rule"; exit 1; }
grep -qF "BOT" "$SKILL" || { echo "FAIL bot detection missing 'BOT' authorAssociation rule"; exit 1; }
echo "OK  bot-author detection covers both conditions"

# Universal error pattern: structured {error: ...} returns.
grep -qF "error:" "$SKILL" || { echo "FAIL missing 'error:' return pattern"; exit 1; }
echo "OK  structured error pattern documented"

# Set-status labels are documented (all four plugin-owned label names).
for label in "bugfix-status:in-progress" "bugfix-status:needs-info" "bugfix-status:rejected" "bugfix-status:ready-for-merge"; do
  grep -qF "$label" "$SKILL" || { echo "FAIL set_status missing label: $label"; exit 1; }
done
echo "OK  all 4 set_status labels documented"

# C10: set_status must auto-create labels to prevent the block-and-comment recursion
# where block-and-comment calls set_status -> set_status fails -> block-and-comment
# fails -> recursion. The fix is idempotent auto-create.
grep -qiF "auto-create labels" "$SKILL" || { echo "FAIL set_status missing auto-create-labels semantics"; exit 1; }
grep -qF "ensure_label" "$SKILL" || { echo "FAIL set_status missing ensure_label helper"; exit 1; }
grep -qF "gh label create" "$SKILL" || { echo "FAIL set_status missing 'gh label create' verb"; exit 1; }
echo "OK  set_status auto-creates labels (block-and-comment recursion safe)"

# C10: set_status must remove all 3 non-target labels (the complete set, not a subset).
# Extract from "### set_status" to next "### " section header (3-letter set_status doesn't match because of the boundary).
remove_count="$(awk '/^### set_status$/{p=1; next} /^### list_ready$/{p=0} p' "$SKILL" | grep -cE '^[[:space:]]*--remove-label "bugfix-status:' || true)"
[[ "$remove_count" -ge 3 ]] || { echo "FAIL set_status only removes $remove_count of 3 sibling labels"; exit 1; }
echo "OK  set_status removes all 3 sibling labels ($remove_count occurrences)"

# R3-I1: ci_watch return shape must be exit-code-derived only (no runs[]/failed_logs in this op).
ci_watch_section="$(awk '/^### ci_watch$/{p=1} /^### rebase_pr$/{p=0} p' "$SKILL")"
if echo "$ci_watch_section" | grep -qE '"runs":\s*\[\.\.\.\]|"failed_logs":\s*"\.\.\."'; then
  echo "FAIL ci_watch return shape still claims runs[]/failed_logs — must be exit-code-derived only"
  exit 1
fi
echo "$ci_watch_section" | grep -qiF "two-call pattern" || { echo "FAIL ci_watch missing two-call pattern documentation"; exit 1; }
echo "OK  ci_watch return shape honest (exit-code-derived + two-call pattern documented)"

# R3-I2: ci_status must classify cancelled/timed_out/action_required as failure (not pending).
for c in cancelled timed_out action_required; do
  grep -qF "$c" "$SKILL" || { echo "FAIL ci_status doesn't mention conclusion '$c'"; exit 1; }
done
grep -qiF "failure-equivalent" "$SKILL" || { echo "FAIL ci_status missing failure-equivalent bucket"; exit 1; }
echo "OK  ci_status classifies cancelled/timed_out/action_required as failure"

# Forward-compatibility note: contract is stable across replacements.
grep -qi "stable\|drop-in replacement" "$SKILL" || { echo "FAIL missing forward-compat note about stable contract"; exit 1; }
echo "OK  forward-compatibility note present"

echo "PASS"
