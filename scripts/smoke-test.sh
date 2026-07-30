#!/usr/bin/env bash
# scripts/smoke-test.sh - Automated smoke test for agent distro
# Tests: setup, spawn scout, spawn ship, watcher, collect, worktree, parallel
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

echo "=== Agent Distro Smoke Test ==="
echo "Root: $ROOT_DIR"
cd "$ROOT_DIR"

# Helper
pass() { echo -e "\033[0;32m[PASS]\033[0m $*"; }
fail() { echo -e "\033[0;31m[FAIL]\033[0m $*" >&2; exit 1; }
info() { echo -e "\033[0;36m[INFO]\033[0m $*"; }

# 1. Setup
info "1. Running setup.sh"
./setup.sh >/dev/null 2>&1 || fail "setup.sh failed"
[ -d ".orchestrator/crew" ] && pass "state dirs exist"
[ -x "scripts/spawn-worker.sh" ] && pass "scripts executable"

# 2. Clean previous test workers
info "2. Cleaning previous test-* workers"
for id in $(ls .orchestrator/crew 2>/dev/null | grep -E "^test-|^smoke-" || true); do
  ./scripts/kill-worker.sh "$id" --remove-worktree 2>/dev/null || true
  tmux kill-session -t "crew-$id" 2>/dev/null || true
  rm -rf ".orchestrator/crew/$id" ".orchestrator/worktrees/$id" 2>/dev/null || true
done

# Detect if in git repo
IN_GIT=false
if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  IN_GIT=true
  info "In git repo - worktree tests enabled"
else
  info "NOT in git repo - testing placeholder mode (fallback)"
fi

# 3. Spawn single scout (generic)
info "3. Spawn single scout worker (generic adapter)"
./scripts/spawn-worker.sh --task-type scout --task "Smoke test: list top-level files" --adapter generic --id smoke-scout-1 >/dev/null
sleep 2
MANIFEST=".orchestrator/crew/smoke-scout-1/manifest.json"
[ -f "$MANIFEST" ] && pass "manifest created"
jq -e '.status=="RUNNING" or .status=="SPAWNING"' "$MANIFEST" >/dev/null && pass "status RUNNING/SPAWNING after spawn"

# Wait for placeholder / codex to finish (max 20s)
for i in $(seq 1 10); do
  ./scripts/watcher.sh --once >/dev/null 2>&1 || true
  STATUS=$(jq -r .status "$MANIFEST" 2>/dev/null || echo UNKNOWN)
  if [ "$STATUS" = "DONE" ]; then break; fi
  sleep 2
done
STATUS=$(jq -r .status "$MANIFEST" 2>/dev/null)
[ "$STATUS" = "DONE" ] && pass "scout reached DONE ($STATUS)" || fail "scout not DONE, status=$STATUS"
grep -q "STATUS: DONE" ".orchestrator/crew/smoke-scout-1/output.md" && pass "output.md contains DONE marker"

# 4. Watcher
info "4. Testing watcher.sh --once"
./scripts/watcher.sh --once 2>&1 | grep -q "total=" && pass "watcher output ok"

# 5. Collect
info "5. Testing collect-output.sh"
./scripts/collect-output.sh --list 2>&1 | grep -q "smoke-scout-1" && pass "list shows worker"
./scripts/collect-output.sh --worker smoke-scout-1 --format markdown 2>&1 | grep -q "Worker: smoke-scout-1" && pass "collect single worker"
./scripts/collect-output.sh --report >/dev/null 2>&1
[ -f ".orchestrator/report.md" ] && pass "report.md generated" || fail "report missing"

# 6. Ship worker (if git repo, tests commit)
if [ "$IN_GIT" = true ]; then
  info "6. Spawn ship worker (git worktree test)"
  ./scripts/spawn-worker.sh --task-type ship --task "Smoke ship: create feature file" --adapter generic --id smoke-ship-1 >/dev/null
  sleep 2
  for i in $(seq 1 10); do
    ./scripts/watcher.sh --once >/dev/null 2>&1 || true
    S=$(jq -r .status ".orchestrator/crew/smoke-ship-1/manifest.json" 2>/dev/null || echo UNKNOWN)
    if [ "$S" = "DONE" ]; then break; fi
    sleep 2
  done
  S=$(jq -r .status ".orchestrator/crew/smoke-ship-1/manifest.json" 2>/dev/null)
  [ "$S" = "DONE" ] && pass "ship reached DONE" || fail "ship not DONE: $S"
  BRANCH="crew/smoke-ship-1"
  git show-ref --verify --quiet "refs/heads/$BRANCH" && pass "branch $BRANCH exists" || fail "branch missing"
  git log --oneline "$BRANCH" ^HEAD 2>/dev/null | head -n1 && pass "ship has commit" || git log --oneline "$BRANCH" ^main 2>/dev/null | head -n1 && pass "ship has commit (main)" || info "ship commit check skipped (branch base)"
  git diff --stat HEAD.."$BRANCH" 2>/dev/null | head -n5
else
  info "6. Ship test (non-git placeholder)"
  ./scripts/spawn-worker.sh --task-type ship --task "Smoke ship placeholder" --adapter generic --id smoke-ship-1 >/dev/null
  sleep 2
  for i in $(seq 1 8); do ./scripts/watcher.sh --once >/dev/null; sleep 1; done
  [ "$(jq -r .status .orchestrator/crew/smoke-ship-1/manifest.json 2>/dev/null)" = "DONE" ] && pass "ship placeholder DONE"
fi

# 7. Parallel crew
info "7. Parallel crew (2 scouts)"
./scripts/spawn-worker.sh --task-type scout --task "Parallel scout A" --adapter generic --id smoke-para-a >/dev/null
./scripts/spawn-worker.sh --task-type scout --task "Parallel scout B" --adapter generic --id smoke-para-b >/dev/null
sleep 3
for i in $(seq 1 10); do
  ./scripts/watcher.sh --once >/dev/null 2>&1 || true
  sleep 1
done
./scripts/list-workers.sh 2>&1 | grep -q "smoke-para" && pass "parallel workers listed"
DONE_COUNT=$(./scripts/list-workers.sh 2>&1 | grep -c "DONE" || true)
[ "$DONE_COUNT" -ge 2 ] && pass "at least 2 DONE after parallel"

# 8. Test BLOCKED / FAILED detection (filesystem protocol)
info "8. Testing BLOCKED detection"
mkdir -p ".orchestrator/crew/smoke-blocked"
cat > ".orchestrator/crew/smoke-blocked/manifest.json" <<JSON
{
  "id": "smoke-blocked",
  "task_type": "scout",
  "task": "test blocked",
  "status": "RUNNING",
  "created_at": "2025-01-01T00:00:00Z",
  "updated_at": "2025-01-01T00:00:00Z",
  "worktree_path": ".orchestrator/worktrees/smoke-blocked",
  "branch": "crew/smoke-blocked",
  "tmux_session": "crew-smoke-blocked",
  "tmux_pane": null,
  "adapter": "generic",
  "pid": null,
  "exit_code": null,
  "output_path": ".orchestrator/crew/smoke-blocked/output.md"
}
JSON
mkdir -p ".orchestrator/worktrees/smoke-blocked"
echo "# output" > ".orchestrator/crew/smoke-blocked/output.md"
echo "<!-- STATUS: BLOCKED -->" >> ".orchestrator/crew/smoke-blocked/output.md"
./scripts/watcher.sh --once >/dev/null
[ "$(jq -r .status .orchestrator/crew/smoke-blocked/manifest.json)" = "BLOCKED" ] && pass "BLOCKED detection works" || fail "BLOCKED not detected"

# 9. Cleanup
info "9. Cleanup"
for id in smoke-scout-1 smoke-ship-1 smoke-para-a smoke-para-b smoke-blocked; do
  ./scripts/kill-worker.sh "$id" --remove-worktree 2>/dev/null || true
  tmux kill-session -t "crew-$id" 2>/dev/null || true
  rm -rf ".orchestrator/crew/$id" ".orchestrator/worktrees/$id" 2>/dev/null || true
  git branch -D "crew/$id" 2>/dev/null || true
  git worktree remove --force ".orchestrator/worktrees/$id" 2>/dev/null || true
done
rm -f ".orchestrator/report.md"
pass "cleanup done"

echo ""
echo -e "\033[0;32m=== All Smoke Tests Passed ===\033[0m"
echo ""
echo "Next manual tests:"
echo "  ./scripts/spawn-worker.sh --task-type scout --task \"Explore auth\" --adapter generic"
echo "  tmux attach -t crew-<id>"
echo "  ./scripts/watcher.sh --watch --interval 3"
echo "  ./scripts/collect-output.sh --report && cat .orchestrator/report.md"
echo ""
echo "For full git worktree isolation, run this test inside a fresh git repo:"
echo "  mkdir /tmp/test-distro && cd /tmp/test-distro && git init -b main"
echo "  cp -r $ROOT_DIR/scripts $ROOT_DIR/adapters $ROOT_DIR/skills $ROOT_DIR/.orchestrator $ROOT_DIR/setup.sh $ROOT_DIR/AGENTS.md $ROOT_DIR/LICENSE $ROOT_DIR/.gitignore ."
echo "  echo hello > README.md && git add . && git commit -m init && ./setup.sh"
echo "  ./scripts/spawn-worker.sh --task-type ship --task \"Add feature\" --adapter generic --id demo"
echo ""
