#!/usr/bin/env bash
# tests/lib/fixture.sh - shared test fixture. Sourced by every *.test.sh.
#
# Guarantees:
#   - a throwaway git repo per test file, in $TMPDIR
#   - ORCH_ROOT / ORCH_HOME redirected there, so no test can touch the real
#     .orchestrator/ (sourcing common.sh creates directories - an unredirected
#     test writes into the repo under test)
#   - teardown on EXIT, including on failure and on interrupt: tmux sessions,
#     worktrees, branches, temp dirs
#
# Bash 3.2 compatible (macOS ships 3.2): no declare -A, no ${var^^}.

set -uo pipefail

TESTS_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TESTS_LIB_DIR/../.." && pwd)"

# Every session this fixture creates is prefixed so teardown can find them even
# if a test aborts before registering one.
FIXTURE_TMUX_PREFIX="orchtest-$$"

_FIXTURE_PASS=0
_FIXTURE_FAIL=0
_FIXTURE_DIRS=""

ok()   { echo "  [PASS] $1"; _FIXTURE_PASS=$((_FIXTURE_PASS + 1)); }
bad()  { echo "  [FAIL] $1"; _FIXTURE_FAIL=$((_FIXTURE_FAIL + 1)); }
note() { echo "  [....] $1"; }

assert_eq() { # <expected> <actual> <label>
  if [ "$1" = "$2" ]; then ok "$3"; else bad "$3 (expected '$1', got '$2')"; fi
}

assert_status() { # <expected> <output.md> <label>
  assert_eq "$1" "$(detect_output_status "$2")" "$3"
}

# fixture_new_repo -> prints path to a fresh throwaway git repo with one commit
fixture_new_repo() {
  local d
  d="$(mktemp -d "${TMPDIR:-/tmp}/orchtest.XXXXXX")"
  _FIXTURE_DIRS="$_FIXTURE_DIRS $d"
  git -C "$d" init -q
  git -C "$d" config user.email "test@example.invalid"
  git -C "$d" config user.name  "Orchestrator Test"
  git -C "$d" config commit.gpgsign false
  printf 'seed\n' > "$d/seed.txt"
  git -C "$d" add -A
  git -C "$d" commit -qm "seed"
  printf '%s' "$d"
}

# fixture_use_repo <repo> - point the orchestrator at <repo> for this test file.
# Must be called before sourcing scripts/common.sh.
fixture_use_repo() {
  ORCH_ROOT="$1"
  ORCH_HOME="$1/.orchestrator"
  export ORCH_ROOT ORCH_HOME
}

# fixture_orchestrator_in <repo> - copy the scripts under test into the throwaway
# repo, so spawn-worker.sh resolves its own paths inside the fixture rather than
# reaching back into the real checkout.
fixture_orchestrator_in() {
  local d="$1"
  mkdir -p "$d/scripts" "$d/adapters" "$d/tests/lib"
  cp "$REPO_ROOT"/scripts/*.sh   "$d/scripts/"
  cp "$REPO_ROOT"/adapters/*.sh  "$d/adapters/"
  cp "$TESTS_LIB_DIR"/*.sh       "$d/tests/lib/"
  # available to spawn-worker.sh as --adapter fake
  cp "$TESTS_LIB_DIR/fake-adapter.sh" "$d/adapters/fake.sh"
  chmod +x "$d"/scripts/*.sh "$d"/adapters/*.sh "$d"/tests/lib/*.sh 2>/dev/null || true
  # Sourcing common.sh creates .orchestrator/ - untracked state would make the
  # fixture repo permanently dirty and spawn-worker.sh refuses a dirty tree.
  printf '.orchestrator/\n' > "$d/.gitignore"
  git -C "$d" add -A >/dev/null 2>&1
  git -C "$d" commit -qm "orchestrator under test" >/dev/null 2>&1
}

# fixture_wait_for <timeout_secs> <command...> - poll until the command succeeds.
# Never "sleep and hope": tests that depend on wall-clock timing are flaky by
# construction, so every wait in the suite goes through here.
fixture_wait_for() {
  local timeout="$1"; shift
  local waited=0
  while [ "$waited" -lt "$timeout" ]; do
    if "$@" >/dev/null 2>&1; then return 0; fi
    sleep 1
    waited=$((waited + 1))
  done
  return 1
}

fixture_teardown() {
  local rc=$?
  # tmux sessions this run created
  if command -v tmux >/dev/null 2>&1; then
    # matches both bare fixture sessions and spawn-worker's crew-<id> naming,
    # since fixture worker ids embed the prefix
    tmux ls 2>/dev/null | cut -d: -f1 | grep "$FIXTURE_TMUX_PREFIX" 2>/dev/null | while read -r s; do
      tmux kill-session -t "$s" 2>/dev/null || true
    done
  fi
  local d
  for d in $_FIXTURE_DIRS; do
    [ -d "$d" ] || continue
    # worktrees first: rm -rf on a repo with live worktrees leaves admin files
    if git -C "$d" rev-parse --git-dir >/dev/null 2>&1; then
      git -C "$d" worktree list --porcelain 2>/dev/null | awk '/^worktree /{print $2}' | while read -r w; do
        [ "$w" = "$d" ] && continue
        git -C "$d" worktree remove --force "$w" 2>/dev/null || rm -rf "$w"
      done
      git -C "$d" worktree prune 2>/dev/null || true
    fi
    rm -rf "$d"
  done
  return $rc
}

fixture_summary() {
  echo
  echo "RESULT total=$((_FIXTURE_PASS + _FIXTURE_FAIL)) passed=$_FIXTURE_PASS failed=$_FIXTURE_FAIL"
  [ "$_FIXTURE_FAIL" -eq 0 ]
}

trap fixture_teardown EXIT INT TERM
