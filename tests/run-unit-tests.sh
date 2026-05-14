#!/usr/bin/env bash
# Runs every test in tests/unit/. Exits non-zero on first failure.
set -euo pipefail

PLUGIN_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
UNIT_DIR="$PLUGIN_ROOT/tests/unit"

failed=0
for t in "$UNIT_DIR"/test-*.sh; do
  echo "==> $(basename "$t")"
  if ! "$t"; then
    echo "FAILED: $t"
    failed=$((failed+1))
  fi
done

if [[ "$failed" -gt 0 ]]; then
  echo "$failed test file(s) failed."
  exit 1
fi
echo "ALL PASS"
