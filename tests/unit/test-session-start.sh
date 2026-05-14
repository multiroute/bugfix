#!/usr/bin/env bash
set -euo pipefail
PLUGIN_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$PLUGIN_ROOT/hooks/session-start"

[[ -x "$SCRIPT" ]] || { echo "FAIL session-start not executable"; exit 1; }

# Need a using-bugfix skill file present for the hook to read.
mkdir -p "$PLUGIN_ROOT/skills/using-bugfix"
if [[ ! -f "$PLUGIN_ROOT/skills/using-bugfix/SKILL.md" ]]; then
  cat > "$PLUGIN_ROOT/skills/using-bugfix/SKILL.md" <<'STUB'
---
name: using-bugfix
description: stub for hook test
---
test body
STUB
fi

# Run the hook and capture stdout.
output="$("$SCRIPT" 2>&1)"
PLUGIN_ROOT="$PLUGIN_ROOT" echo "$output" | python3 -c "
import json, os, sys
doc = json.loads(sys.stdin.read())
# Claude Code shape: hookSpecificOutput.additionalContext
ctx = doc.get('hookSpecificOutput', {}).get('additionalContext', '')
assert 'EXTREMELY_IMPORTANT' in ctx, 'additionalContext missing tag'
# Assert the actual SKILL.md body (whatever it is — stub or real F1 content)
# is embedded. Both versions have 'name: using-bugfix' in their frontmatter,
# so this marker works whether D3 runs before or after F1.
assert 'name: using-bugfix' in ctx, 'additionalContext missing skill body marker'
" || { echo "FAIL hook output shape wrong: $output"; exit 1; }
echo "OK  happy-path JSON output"

# Failure path: missing SKILL.md should exit non-zero, NOT emit a banner
# wrapping an error body. We exercise this by running the hook from a
# temp PLUGIN_ROOT where the skill file is absent.
TMPHOOKS="$(mktemp -d)"
trap 'rm -rf "$TMPHOOKS"' EXIT
cp "$SCRIPT" "$TMPHOOKS/session-start"
chmod +x "$TMPHOOKS/session-start"
mkdir -p "$TMPHOOKS/../skills"  # parent dir exists; using-bugfix/ does not
set +e
out="$("$TMPHOOKS/session-start" 2>&1)"
rc=$?
set -e
[[ "$rc" -ne 0 ]] || { echo "FAIL missing SKILL.md should exit non-zero (got $rc)"; exit 1; }
echo "$out" | grep -qi "not found\|missing" || { echo "FAIL error message uninformative: $out"; exit 1; }
echo "OK  missing SKILL.md fails fast with informative stderr"

# R4-C3 regression test: a SKILL.md body containing $(...) or backticks
# must NOT be evaluated as shell. The prior heredoc-based envelope assembly
# would have executed any such payload at every SessionStart.
TMPINJECT="$(mktemp -d)"
mkdir -p "$TMPINJECT/bugfix/hooks" "$TMPINJECT/bugfix/skills/using-bugfix"
cp "$SCRIPT" "$TMPINJECT/bugfix/hooks/session-start"
chmod +x "$TMPINJECT/bugfix/hooks/session-start"
cat > "$TMPINJECT/bugfix/skills/using-bugfix/SKILL.md" <<EOF
---
name: using-bugfix
description: shell-injection regression test stub
---

Body with shell metacharacters: \$(touch $TMPINJECT/PWNED_DOLLAR) and \`touch $TMPINJECT/PWNED_BACKTICK\` and \$\$ and \${HOME}.
EOF
"$TMPINJECT/bugfix/hooks/session-start" >/dev/null 2>&1 || true
if [[ -e "$TMPINJECT/PWNED_DOLLAR" || -e "$TMPINJECT/PWNED_BACKTICK" ]]; then
  echo "FAIL hook evaluated shell-metacharacters in SKILL.md body — injection vector"
  rm -rf "$TMPINJECT"
  exit 1
fi
rm -rf "$TMPINJECT"
echo "OK  hook does not eval shell-metacharacters in SKILL.md body"

echo "PASS"
