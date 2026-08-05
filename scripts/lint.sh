#!/usr/bin/env bash
# scripts/lint.sh - single owner of the lint definition (file set + options).
# CI calls this; any local pre-push hook must call this too. Do not re-spell the
# shellcheck invocation elsewhere, or CI and local checks will drift.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

if ! command -v shellcheck >/dev/null 2>&1; then
  echo "shellcheck not found in PATH." >&2
  echo "  macOS:  brew install shellcheck" >&2
  echo "  Ubuntu: apt install shellcheck" >&2
  exit 127
fi

echo "shellcheck $(shellcheck --version | awk '/^version:/{print $2}')"

FILES="$(find scripts adapters tests setup.sh -name '*.sh' -type f 2>/dev/null | sort)"
[ -n "$FILES" ] || { echo "no shell files found" >&2; exit 1; }

# -x follows sourced files. SC1091 is disabled because sourced paths are resolved
# at runtime from computed directories, which shellcheck cannot follow statically.
# shellcheck disable=SC2086
shellcheck --external-sources --exclude=SC1091 --severity=warning $FILES
rc=$?
[ $rc -eq 0 ] && echo "lint clean: $(echo "$FILES" | wc -l | tr -d ' ') files"
exit $rc
