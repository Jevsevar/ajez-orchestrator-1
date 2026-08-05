#!/usr/bin/env bash
# tests/spawn-worker.test.sh - spawn failure paths and the D002 evidence gate.
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/fixture.sh"

REPO="$(fixture_new_repo)"
fixture_orchestrator_in "$REPO"
fixture_use_repo "$REPO"
. "$REPO/scripts/common.sh"

P="$FIXTURE_TMUX_PREFIX"

spawn() { ( cd "$REPO" && ./scripts/spawn-worker.sh "$@" 2>&1 ); }

status_of() {
  grep -o '"status"[[:space:]]*:[[:space:]]*"[A-Z]*"' "$CREW_DIR/$1/manifest.json" \
    | head -1 | sed 's/.*"\([A-Z]*\)"$/\1/'
}
# The watcher is what reconciles a manifest against reality - that is its whole
# job - so completion is observed the way the lead observes it, by polling the
# watcher, not by trusting the worker to update its own manifest.
worker_done() {
  ( cd "$REPO" && ./scripts/watcher.sh --once >/dev/null 2>&1 )
  local s; s="$(status_of "$1" 2>/dev/null)"
  case "$s" in DONE|BLOCKED|FAILED) return 0 ;; *) return 1 ;; esac
}

echo "== argument validation =="

out="$(spawn --task-type ship 2>&1)"; rc=$?
[ $rc -ne 0 ] && ok "missing --task rejected" || bad "missing --task accepted"

out="$(spawn --task "no type here please" 2>&1)"; rc=$?
[ $rc -ne 0 ] && ok "missing --task-type rejected" || bad "missing --task-type accepted"

out="$(spawn --task-type ship --task "abc" 2>&1)"; rc=$?
[ $rc -ne 0 ] && ok "too-short task rejected" || bad "too-short task accepted"

out="$(spawn --task-type banana --task "a valid length task" 2>&1)"; rc=$?
[ $rc -ne 0 ] && ok "invalid task type rejected" || bad "invalid task type accepted"

echo "== unknown adapter =="

out="$(spawn --task-type ship --task "a valid length task" --adapter nope-not-real --id "$P-adp" 2>&1)"; rc=$?
[ $rc -ne 0 ] && ok "unknown adapter rejected" || bad "unknown adapter accepted"

echo "== dirty tree is refused unless --allow-dirty =="

printf 'dirty\n' > "$REPO/dirty.txt"
out="$(spawn --task-type ship --task "a valid length task" --adapter fake --id "$P-dirty" 2>&1)"; rc=$?
[ $rc -ne 0 ] && ok "dirty tree refused by default" || bad "dirty tree accepted"
case "$out" in
  *allow-dirty*) ok "refusal names the bypass flag" ;;
  *)             bad "refusal does not mention --allow-dirty" ;;
esac
rm -f "$REPO/dirty.txt"

echo "== existing branch collides =="

git -C "$REPO" branch "crew/$P-taken" >/dev/null 2>&1
out="$(spawn --task-type ship --task "a valid length task" --adapter fake --id "$P-taken" 2>&1)"; rc=$?
[ $rc -ne 0 ] && ok "existing crew/<id> branch refused" || bad "existing branch accepted"
git -C "$REPO" branch -D "crew/$P-taken" >/dev/null 2>&1

echo "== dry run touches nothing =="

out="$(spawn --task-type ship --task "a valid length task" --adapter fake --id "$P-dry" --dry-run 2>&1)"
[ ! -d "$CREW_DIR/$P-dry" ] && ok "--dry-run creates no crew dir" || bad "--dry-run created state"
git -C "$REPO" show-ref --verify --quiet "refs/heads/crew/$P-dry" \
  && bad "--dry-run created a branch" || ok "--dry-run creates no branch"

if ! command -v tmux >/dev/null 2>&1; then
  note "tmux unavailable - skipping live spawn tests"
  fixture_summary
  exit $?
fi

echo "== live spawn: a real worker reaches DONE =="

spawn --task-type ship --task "fake worker should succeed here" --adapter fake --id "$P-ok" >/dev/null 2>&1
if fixture_wait_for 30 worker_done "$P-ok"; then
  assert_eq DONE "$(status_of "$P-ok")" "fake adapter drives worker to DONE"
  git -C "$REPO" show-ref --verify --quiet "refs/heads/crew/$P-ok" \
    && ok "crew branch created" || bad "crew branch missing"
  [ -d "$WORKTREES_DIR/$P-ok" ] && ok "worktree created" || bad "worktree missing"
else
  bad "worker $P-ok never reached a terminal state (status=$(status_of "$P-ok" 2>/dev/null))"
fi

echo "== D002: an adapter that exits 0 with no work must FAIL, not complete =="

spawn --task-type ship --task "FAKE:nowork this adapter does nothing" --adapter fake --id "$P-nowork" >/dev/null 2>&1
if fixture_wait_for 30 worker_done "$P-nowork"; then
  assert_eq FAILED "$(status_of "$P-nowork")" "exit 0 with no work -> FAILED"
  grep -q "produced no work" "$CREW_DIR/$P-nowork/output.md" \
    && ok "failure explains why" || bad "no diagnostic in output.md"
else
  bad "nowork worker never reached a terminal state"
fi

echo "== an adapter that works but omits the marker still completes =="

spawn --task-type ship --task "FAKE:silent work but no marker" --adapter fake --id "$P-silent" >/dev/null 2>&1
if fixture_wait_for 30 worker_done "$P-silent"; then
  assert_eq DONE "$(status_of "$P-silent")" "work without marker -> DONE via evidence"
else
  bad "silent worker never reached a terminal state"
fi

echo "== BLOCKED and crash propagate =="

spawn --task-type ship --task "FAKE:blocked needs a decision" --adapter fake --id "$P-blk" >/dev/null 2>&1
fixture_wait_for 30 worker_done "$P-blk" \
  && assert_eq BLOCKED "$(status_of "$P-blk")" "BLOCKED marker propagates" \
  || bad "blocked worker never terminal"

spawn --task-type ship --task "FAKE:crash simulated failure" --adapter fake --id "$P-crash" >/dev/null 2>&1
fixture_wait_for 30 worker_done "$P-crash" \
  && assert_eq FAILED "$(status_of "$P-crash")" "non-zero adapter exit -> FAILED" \
  || bad "crash worker never terminal"

echo "== D001: a brief full of backticks is not executed =="

CANARY_ID="$P-inject"
spawn --task-type scout --adapter fake --id "$CANARY_ID" \
  --task 'Reference `zzz_not_a_real_command_xyz` in the brief.' >/dev/null 2>&1
if [ -f "$CREW_DIR/$CANARY_ID/task-desc.txt" ]; then
  grep -qF 'zzz_not_a_real_command_xyz' "$CREW_DIR/$CANARY_ID/task-desc.txt" \
    && ok "backticked text stored verbatim" || bad "task text was expanded"
  grep -qF 'zzz_not_a_real_command_xyz' "$CREW_DIR/$CANARY_ID/launch.sh" \
    && bad "task text embedded in generated shell" || ok "launch.sh carries no task text"
else
  bad "task-desc.txt not written"
fi

fixture_summary
