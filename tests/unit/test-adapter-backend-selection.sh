#!/usr/bin/env bash
set -euo pipefail
PLUGIN_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SKILL="$PLUGIN_ROOT/skills/ticket-adapter/SKILL.md"

grep -q "^## Backend selection$" "$SKILL" \
  || { echo "FAIL missing '## Backend selection' section"; exit 1; }
echo "OK  Backend selection section present"

# Probe order must be MCP-first, gh fallback.
grep -qF "MCP first" "$SKILL" \
  || { echo "FAIL Backend selection must say 'MCP first'"; exit 1; }
echo "OK  documents MCP-first probe"

grep -qF "gh fallback" "$SKILL" \
  || { echo "FAIL Backend selection must say 'gh fallback'"; exit 1; }
echo "OK  documents gh fallback"

# Caching via state.artifacts.adapter_backend.
grep -qF "state.artifacts.adapter_backend" "$SKILL" \
  || { echo "FAIL Backend selection must cache via state.artifacts.adapter_backend"; exit 1; }
echo "OK  documents adapter_backend caching"

# Neither-available error path.
grep -qF "neither MCP GitHub nor gh" "$SKILL" \
  || { echo "FAIL must document 'neither MCP GitHub nor gh' error"; exit 1; }
echo "OK  documents neither-available error"

# MCP probe references mcp__github__ tools.
grep -qF "mcp__github__" "$SKILL" \
  || { echo "FAIL must reference mcp__github__ tools"; exit 1; }
echo "OK  references mcp__github__ tools"

echo "ALL test-adapter-backend-selection tests passed"
