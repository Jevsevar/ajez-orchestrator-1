#!/usr/bin/env bash
# tests/run.sh - run every tests/*.test.sh.
#
# Exits non-zero if any file fails. Emits a machine-readable summary line so CI
# and the lead agent can parse the result without scraping prose:
#
#   RESULT total=<n> passed=<n> failed=<n>
#
# Usage: tests/run.sh [name-substring ...]
set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$TESTS_DIR/.."

FILTER="$*"
TOTAL=0; PASSED=0; FAILED=0
FAILED_FILES=""

for f in "$TESTS_DIR"/*.test.sh; do
  [ -e "$f" ] || continue
  name="$(basename "$f")"
  if [ -n "$FILTER" ]; then
    match=0
    for pat in $FILTER; do
      case "$name" in *"$pat"*) match=1 ;; esac
    done
    [ "$match" -eq 1 ] || continue
  fi

  TOTAL=$((TOTAL + 1))
  echo "=== $name ==="
  if bash "$f"; then
    PASSED=$((PASSED + 1))
  else
    FAILED=$((FAILED + 1))
    FAILED_FILES="$FAILED_FILES $name"
  fi
  echo
done

echo "========================================"
if [ "$FAILED" -ne 0 ]; then
  echo "FAILING FILES:$FAILED_FILES"
fi
echo "RESULT total=$TOTAL passed=$PASSED failed=$FAILED"
[ "$FAILED" -eq 0 ]
