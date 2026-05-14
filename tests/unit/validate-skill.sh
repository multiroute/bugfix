#!/usr/bin/env bash
# Usage: validate-skill.sh <skill-path-relative-to-plugin-root>
# Checks: file exists, has YAML frontmatter with name + description,
# contains no leftover `superpowers:` references.
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "usage: validate-skill.sh <skill-path>" >&2
  exit 2
fi

PLUGIN_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
skill="$PLUGIN_ROOT/$1"

[[ -f "$skill" ]] || { echo "FAIL $1: file missing"; exit 1; }

# Frontmatter checks via Python.
python3 -c "
import sys, re
content = open('$skill').read()
m = re.match(r'^---\n(.*?)\n---\n', content, re.DOTALL)
assert m, 'no frontmatter delimited by ---'
fm = m.group(1)
assert re.search(r'(?m)^name:\s*\S', fm), 'frontmatter missing name'
assert re.search(r'(?m)^description:\s*\S', fm), 'frontmatter missing description'
" || { echo "FAIL $1: frontmatter check failed"; exit 1; }

# No upstream namespace leaks.
if grep -q "superpowers:" "$skill"; then
  echo "FAIL $1: leftover 'superpowers:' references"
  grep -n "superpowers:" "$skill" >&2
  exit 1
fi

echo "OK  $1"
