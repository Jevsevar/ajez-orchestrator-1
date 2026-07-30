#!/usr/bin/env bash
# scripts/kill-worker.sh - Terminate a worker and optionally clean worktree
# Usage: ./scripts/kill-worker.sh <worker-id> [--remove-worktree] [--force-failed]
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

WORKER_ID="${1:-}"
REMOVE_WT="false"
FORCE_FAILED="false"

for arg in "$@"; do
  case "$arg" in
    --remove-worktree) REMOVE_WT="true";;
    --force-failed) FORCE_FAILED="true";;
    --help|-h)
      echo "Usage: $0 <worker-id> [--remove-worktree] [--force-failed]"
      exit 0
      ;;
  esac
done

if [[ -z "$WORKER_ID" ]]; then
  echo "Error: worker-id required" >&2
  echo "Available workers:" >&2
  "$SCRIPT_DIR/list-workers.sh" >&2
  exit 1
fi

M_PATH="$(manifest_path "$WORKER_ID")"
if [[ ! -f "$M_PATH" ]]; then
  # try to find by substring?
  FOUND="$(find "$CREW_DIR" -type d -name "*$WORKER_ID*" 2>/dev/null | head -n1 || true)"
  if [[ -n "$FOUND" ]]; then
    echo "Exact manifest not found, using $FOUND" >&2
    M_PATH="$FOUND/manifest.json"
    WORKER_ID="$(basename "$FOUND")"
  else
    echo "Error: manifest not found for $WORKER_ID ($M_PATH)" >&2
    exit 1
  fi
fi

SESSION="$(get_json_field "$M_PATH" "tmux_session" 2>/dev/null || echo "crew-$WORKER_ID")"
WT_PATH="$(get_json_field "$M_PATH" "worktree_path" 2>/dev/null || echo "$WORKTREES_DIR/$WORKER_ID")"
BRANCH="$(get_json_field "$M_PATH" "branch" 2>/dev/null || echo "crew/$WORKER_ID")"

echo "[kill] Worker: $WORKER_ID"
echo "[kill] Session: $SESSION"
echo "[kill] Worktree: $WT_PATH"
echo "[kill] Branch: $BRANCH"

if is_tmux_alive "$SESSION"; then
  echo "[kill] Killing tmux session $SESSION..."
  tmux kill-session -t "$SESSION" 2>/dev/null || true
  log_event "KILL" "$WORKER_ID" "killed tmux $SESSION"
else
  echo "[kill] Tmux session $SESSION not alive"
fi

if [[ "$FORCE_FAILED" == "true" ]]; then
  update_manifest_status "$M_PATH" "FAILED" 130 || true
  echo "[kill] Marked FAILED"
fi

if [[ "$REMOVE_WT" == "true" ]]; then
  echo "[kill] Removing worktree $WT_PATH..."
  if git -C "$ROOT_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    git -C "$ROOT_DIR" worktree remove --force "$WT_PATH" 2>/dev/null || rm -rf "$WT_PATH"
    git -C "$ROOT_DIR" branch -D "$BRANCH" 2>/dev/null || true
  else
    rm -rf "$WT_PATH"
  fi
  log_event "KILL" "$WORKER_ID" "removed worktree $WT_PATH"
  echo "[kill] Worktree removed"
fi

echo "[kill] Done"

