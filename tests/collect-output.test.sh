#!/usr/bin/env bash
# tests/collect-output.test.sh - collect-output.sh in all four output modes.
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/fixture.sh"

REPO="$(fixture_new_repo)"
fixture_orchestrator_in "$REPO"
fixture_use_repo "$REPO"
. "$REPO/scripts/common.sh"

collect() { ( cd "$REPO" && ./scripts/collect-output.sh "$@" 2>&1 ); }

mk() { # <id> <status> <type>
  local id="$1" status="$2" type="${3:-ship}"
  local d="$CREW_DIR/$id"
  mkdir -p "$d"
  cat > "$d/manifest.json" <<JSON
{
  "id": "$id",
  "task_type": "$type",
  "status": "$status",
  "adapter": "fake",
  "task": "task text for $id",
  "output": "$d/output.md",
  "worktree": "$WORKTREES_DIR/$id",
  "branch": "crew/$id",
  "created_at": "2026-01-01T00:00:00Z"
}
JSON
  printf '# Worker %s\n\n## Result: body-of-%s\n\n<!-- STATUS: %s -->\n' "$id" "$id" "$status" > "$d/output.md"
}

mk c-done    DONE
mk c-blocked BLOCKED
mk c-failed  FAILED
mk c-running RUNNING
mk c-scout   DONE scout

echo "== --list =="
out="$(collect --list)"
for id in c-done c-blocked c-failed c-running; do
  case "$out" in *"$id"*) ok "--list shows $id" ;; *) bad "--list missing $id" ;; esac
done

echo "== --worker =="
out="$(collect --worker c-done --format markdown)"
case "$out" in *body-of-c-done*) ok "--worker emits that worker's body" ;; *) bad "--worker body missing" ;; esac
case "$out" in *body-of-c-blocked*) bad "--worker leaked another worker" ;; *) ok "--worker is scoped to one worker" ;; esac

echo "== --all covers terminal workers only =="
out="$(collect --all --format markdown)"
for id in c-done c-blocked c-failed; do
  case "$out" in *"body-of-$id"*) ok "--all includes terminal worker $id" ;; *) bad "--all missing $id" ;; esac
done
case "$out" in
  *body-of-c-running*) bad "--all included a RUNNING worker" ;;
  *)                   ok "--all excludes the RUNNING worker" ;;
esac

echo "== --status filter =="
out="$(collect --status BLOCKED --format markdown)"
case "$out" in *body-of-c-blocked*) ok "--status BLOCKED matches" ;; *) bad "--status BLOCKED missed its worker" ;; esac
case "$out" in *body-of-c-done*) bad "--status BLOCKED leaked a DONE worker" ;; *) ok "--status filters others out" ;; esac

echo "== formats =="
out="$(collect --all --format json)"
if command -v jq >/dev/null 2>&1; then
  printf '%s' "$out" | jq -e . >/dev/null 2>&1 \
    && ok "--format json emits valid JSON" || bad "--format json is not valid JSON"
else
  case "$out" in *'{'*) ok "--format json emits JSON-ish (jq unavailable)" ;; *) bad "--format json produced no JSON" ;; esac
fi

out="$(collect --all --format text)"
[ -n "$out" ] && ok "--format text produces output" || bad "--format text empty"

echo "== --report writes report.md =="
rm -f "$ORCH_DIR/report.md"
collect --report >/dev/null 2>&1
[ -f "$ORCH_DIR/report.md" ] && ok "--report creates .orchestrator/report.md" || bad "--report wrote no report.md"
if [ -f "$ORCH_DIR/report.md" ]; then
  grep -q "body-of-c-done" "$ORCH_DIR/report.md" \
    && ok "report contains worker bodies" || bad "report missing worker bodies"
fi

echo "== --merge-branches surfaces merge commands for ship workers =="
out="$(collect --report --merge-branches 2>&1; cat "$ORCH_DIR/report.md" 2>/dev/null)"
case "$out" in
  *"crew/c-done"*) ok "--merge-branches names the ship branch" ;;
  *)               bad "--merge-branches did not surface crew/c-done" ;;
esac

echo "== empty fleet is not an error =="
EMPTY="$(fixture_new_repo)"
fixture_orchestrator_in "$EMPTY"
out="$( cd "$EMPTY" && ORCH_ROOT="$EMPTY" ORCH_HOME="$EMPTY/.orchestrator" ./scripts/collect-output.sh --list 2>&1 )"; rc=$?
[ $rc -eq 0 ] && ok "--list on an empty fleet exits 0" || bad "--list on empty fleet exited $rc"

fixture_summary
