#!/usr/bin/env bash
# tests/watcher.test.sh - every FSM transition in scripts/watcher.sh.
#
# FSM: PENDING -> SPAWNING -> RUNNING -> DONE | BLOCKED | FAILED
#
# Drives the watcher against hand-built manifests rather than live workers, so
# each transition is exercised deterministically with no timing dependence.
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/fixture.sh"

REPO="$(fixture_new_repo)"
fixture_orchestrator_in "$REPO"
fixture_use_repo "$REPO"
. "$REPO/scripts/common.sh"

# mk_worker <id> <status> [output-body]
mk_worker() {
  local id="$1" status="$2" body="${3:-}"
  local d="$CREW_DIR/$id"
  mkdir -p "$d"
  cat > "$d/manifest.json" <<JSON
{
  "id": "$id",
  "task_type": "ship",
  "status": "$status",
  "adapter": "fake",
  "tmux_session": "$FIXTURE_TMUX_PREFIX-$id",
  "output": "$d/output.md",
  "worktree": "$WORKTREES_DIR/$id",
  "created_at": "2026-01-01T00:00:00Z"
}
JSON
  printf '# Worker %s\n\n%s\n' "$id" "$body" > "$d/output.md"
}

status_of() { # <id>
  grep -o '"status"[[:space:]]*:[[:space:]]*"[A-Z]*"' "$CREW_DIR/$1/manifest.json" \
    | head -1 | sed 's/.*"\([A-Z]*\)"$/\1/'
}

run_watcher() { ( cd "$REPO" && ./scripts/watcher.sh --once >/dev/null 2>&1 ); }

echo "== terminal transitions driven by the output marker =="

mk_worker w-done    RUNNING '## Result: ok

<!-- STATUS: DONE -->'
mk_worker w-blocked RUNNING '## Blocked: needs input

<!-- STATUS: BLOCKED -->'
mk_worker w-failed  RUNNING '## Failed: bad

<!-- STATUS: FAILED -->'
run_watcher
assert_eq DONE    "$(status_of w-done)"    "RUNNING -> DONE on marker"
assert_eq BLOCKED "$(status_of w-blocked)" "RUNNING -> BLOCKED on marker"
assert_eq FAILED  "$(status_of w-failed)"  "RUNNING -> FAILED on marker"

echo "== PENDING/SPAWNING also honour a terminal marker =="

mk_worker w-pending  PENDING  '<!-- STATUS: DONE -->'
mk_worker w-spawning SPAWNING '<!-- STATUS: DONE -->'
run_watcher
assert_eq DONE "$(status_of w-pending)"  "PENDING -> DONE on marker"
assert_eq DONE "$(status_of w-spawning)" "SPAWNING -> DONE on marker"

echo "== no marker, no session: dead worker becomes FAILED =="

mk_worker w-dead RUNNING 'still going, no marker'
run_watcher
assert_eq FAILED "$(status_of w-dead)" "RUNNING + dead session + no marker -> FAILED"

echo "== SPAWNING with a dead session and no output file -> FAILED =="

mk_worker w-nofile SPAWNING ''
rm -f "$CREW_DIR/w-nofile/output.md"
run_watcher
assert_eq FAILED "$(status_of w-nofile)" "SPAWNING + dead session + no output.md -> FAILED"

echo "== terminal states are sticky =="

for s in DONE BLOCKED FAILED; do
  id="w-sticky-$s"
  mk_worker "$id" "$s" 'no marker at all'
  run_watcher
  assert_eq "$s" "$(status_of $id)" "$s is terminal, watcher leaves it alone"
done

echo "== D001: a brief documenting the marker must not complete a worker =="

mk_worker w-brief RUNNING 'When finished, append `<!-- STATUS: DONE -->` to output.md.

## Still working'
run_watcher
# Session is dead, so FAILED is correct here; the point is it must not be DONE.
[ "$(status_of w-brief)" != "DONE" ] \
  && ok "prose mentioning the marker did not complete the worker" \
  || bad "prose mentioning the marker completed the worker"

fixture_summary
