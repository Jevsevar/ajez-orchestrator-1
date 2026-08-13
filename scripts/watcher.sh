#!/usr/bin/env bash
# scripts/watcher.sh - Polls worker status (alive? done? blocked?) and logs events
# Usage:
#   ./scripts/watcher.sh --once     # single pass
#   ./scripts/watcher.sh --watch    # continuous loop
#   --interval SEC  (default 5)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

MODE="once"
INTERVAL=5

usage() {
  cat <<'USAGE'
watcher.sh - Poll worker health and state

Usage:
  ./scripts/watcher.sh --once
  ./scripts/watcher.sh --watch [--interval 5]

Options:
  --once          Single pass over all workers
  --watch         Continuous loop
  --interval SEC  Poll interval in seconds (default 5)
  -h, --help      Help

What it does:
  - Checks tmux session alive
  - Parses output.md for STATUS markers (DONE, BLOCKED, FAILED)
  - Updates manifest.json if filesystem indicates new state
  - Detects crashed / orphaned workers -> FAILED
  - Logs all transitions to .orchestrator/logs/

Protocol for workers to signal:
  Append to output.md:
    <!-- STATUS: DONE -->
    <!-- STATUS: BLOCKED -->
    <!-- STATUS: FAILED -->

Or worker may directly update its own manifest.json status.

Lifecycle:
  PENDING -> SPAWNING -> RUNNING -> DONE | BLOCKED | FAILED

USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --once) MODE="once"; shift;;
    --watch) MODE="watch"; shift;;
    --interval) INTERVAL="$2"; shift 2;;
    -h|--help) usage; exit 0;;
    *) echo "Unknown arg: $1" >&2; usage; exit 1;;
  esac
done

ensure_orch_dirs

watcher_log="$LOGS_DIR/watcher.log"
touch "$watcher_log" 2>/dev/null || true

# ---- Helpers ----

check_output_status() {
  # check_output_status <output.md>
  # returns DONE|BLOCKED|FAILED|NEEDS_REVIEW|RUNNING
  local out="$1"
  if [[ ! -f "$out" ]]; then
    echo "RUNNING"
    return
  fi
  # Check last 20 lines for markers (to avoid matching documentation in PROMPT.md)
  # Status markers should be at the end of the file when worker completes
  local tail_content
  tail_content="$(tail -n 20 "$out" 2>/dev/null || cat "$out")"
  if echo "$tail_content" | grep -q "<!--[[:space:]]*STATUS:[[:space:]]*DONE"; then
    echo "DONE"
  elif echo "$tail_content" | grep -q "<!--[[:space:]]*STATUS:[[:space:]]*BLOCKED"; then
    echo "BLOCKED"
  elif echo "$tail_content" | grep -q "<!--[[:space:]]*STATUS:[[:space:]]*FAILED"; then
    echo "FAILED"
  elif echo "$tail_content" | grep -q "<!--[[:space:]]*STATUS:[[:space:]]*NEEDS_REVIEW"; then
    echo "NEEDS_REVIEW"
  else
    echo "RUNNING"
  fi
}

poll_once() {
  local manifest
  local count_total=0
  local count_running=0
  local count_done=0
  local count_blocked=0
  local count_failed=0
  local count_review=0
  local count_pending=0

  local manifests
  manifests="$(list_manifests || true)"

  if [[ -z "$manifests" ]]; then
    echo "[watcher] No workers found in $CREW_DIR"
    return 0
  fi

  while IFS= read -r manifest; do
    [[ -z "$manifest" ]] && continue
    count_total=$((count_total+1))

    local worker_id status tmux_sess worktree output_path pid
    worker_id="$(get_json_field "$manifest" "id" || basename "$(dirname "$manifest")")"
    status="$(get_json_field "$manifest" "status" 2>/dev/null || echo "UNKNOWN")"
    tmux_sess="$(get_json_field "$manifest" "tmux_session" 2>/dev/null || echo "")"
    worktree="$(get_json_field "$manifest" "worktree_path" 2>/dev/null || echo "")"
    output_path="$(get_json_field "$manifest" "output_path" 2>/dev/null || echo "")"
    pid="$(get_json_field "$manifest" "pid" 2>/dev/null || echo "")"

    # Resolve output path absolute
    local abs_output=""
    if [[ -n "$output_path" ]]; then
      if [[ "$output_path" == /* ]]; then
        abs_output="$output_path"
      else
        # Try relative to ROOT_DIR first, then relative to manifest dir
        if [[ -f "$ROOT_DIR/$output_path" ]]; then
          abs_output="$ROOT_DIR/$output_path"
        elif [[ -f "$(dirname "$manifest")/output.md" ]]; then
          abs_output="$(dirname "$manifest")/output.md"
        else
          abs_output="$ROOT_DIR/$output_path"
        fi
      fi
    else
      abs_output="$(dirname "$manifest")/output.md"
    fi

    # Normalize: if output_path field was relative, use crew dir file
    if [[ ! -f "$abs_output" && -f "$(dirname "$manifest")/output.md" ]]; then
      abs_output="$(dirname "$manifest")/output.md"
    fi

    local file_status
    file_status="$(check_output_status "$abs_output")"

    local tmux_alive="unknown"
    if [[ -n "$tmux_sess" ]]; then
      if is_tmux_alive "$tmux_sess"; then
        tmux_alive="alive"
      else
        tmux_alive="dead"
      fi
    fi

    local action="none"
    local new_status="$status"

    case "$status" in
      PENDING|SPAWNING)
        # If output shows DONE etc, we should transition anyway
        if [[ "$file_status" == "DONE" ]]; then
          new_status="DONE"
          action="output->DONE"
        elif [[ "$file_status" == "BLOCKED" ]]; then
          new_status="BLOCKED"
          action="output->BLOCKED"
        elif [[ "$file_status" == "FAILED" ]]; then
          new_status="FAILED"
          action="output->FAILED"
        elif [[ "$file_status" == "NEEDS_REVIEW" ]]; then
          new_status="NEEDS_REVIEW"
          action="output->NEEDS_REVIEW"
        elif [[ "$status" == "PENDING" ]]; then
          # pending should have moved to spawning after a while? watcher doesn't auto spawn.
          new_status="$status"
        fi
        # Check if tmux dead while still spawning -> fail?
        if [[ "$tmux_alive" == "dead" && "$status" == "SPAWNING" ]]; then
          # Give it a little grace? If manifest age > 60s and tmux dead => failed
          # Simple: if output doesn't exist and tmux dead, mark FAILED
          if [[ ! -f "$abs_output" ]]; then
            new_status="FAILED"
            action="tmux dead during SPAWNING"
          fi
        fi
        ;;
      RUNNING)
        # Primary logic: if output says DONE/BLOCKED/FAILED/NEEDS_REVIEW, that wins
        if [[ "$file_status" == "DONE" ]]; then
          # Validate completion for DONE status
          if validate_completion "$manifest" 2>/dev/null; then
            new_status="DONE"
            action="completed"
          else
            new_status="NEEDS_REVIEW"
            action="DONE but validation failed"
          fi
        elif [[ "$file_status" == "BLOCKED" ]]; then
          new_status="BLOCKED"
          action="blocked via output"
        elif [[ "$file_status" == "FAILED" ]]; then
          new_status="FAILED"
          action="failed via output"
        elif [[ "$file_status" == "NEEDS_REVIEW" ]]; then
          new_status="NEEDS_REVIEW"
          action="needs review via output"
        else
          # No marker, check tmux and worker process
          if [[ "$tmux_alive" == "dead" ]]; then
            # tmux dead without explicit marker = FAILED (no more auto-DONE)
            new_status="FAILED"
            action="tmux dead without marker -> FAILED"
          elif [[ -n "$tmux_sess" ]]; then
            # Tmux is alive, but is the actual worker process alive?
            if ! is_worker_alive "$tmux_sess" "$worker_id" 2>/dev/null; then
              new_status="FAILED"
              action="worker process dead -> FAILED"
            else
              # Worker process is alive, check for staleness
              if [[ -f "$abs_output" ]]; then
                local output_mtime
                output_mtime="$(stat -f %m "$abs_output" 2>/dev/null || stat -c %Y "$abs_output" 2>/dev/null || echo "0")"
                local current_time
                current_time="$(date +%s)"
                local age=$((current_time - output_mtime))
                
                if [[ "$age" -gt 240 ]]; then
                  new_status="BLOCKED"
                  action="output stale ${age}s -> BLOCKED"
                fi
              fi
            fi
          fi
        fi
        ;;
      DONE|BLOCKED|FAILED|NEEDS_REVIEW)
        # Terminal, no change
        ;;
      *)
        new_status="$status"
        ;;
    esac

    # Count
    case "$status" in
      RUNNING) count_running=$((count_running+1));;
      DONE) count_done=$((count_done+1));;
      BLOCKED) count_blocked=$((count_blocked+1));;
      FAILED) count_failed=$((count_failed+1));;
      NEEDS_REVIEW) count_review=$((count_review+1));;
      PENDING|SPAWNING) count_pending=$((count_pending+1));;
    esac

    # Log state
    printf "[watcher] %-30s status=%-8s tmux=%-6s file=%-7s -> %-8s (%s)\n" "$worker_id" "$status" "$tmux_alive" "$file_status" "$new_status" "$action"

    if [[ "$new_status" != "$status" ]]; then
      echo "[watcher] Transition $worker_id: $status -> $new_status ($action)"
      log_event "WATCHER" "$worker_id" "transition $status -> $new_status reason=$action tmux=$tmux_alive file_status=$file_status"
      # Update manifest
      if [[ "$new_status" == "FAILED" ]]; then
        # Try to preserve exit code if already set, else 1
        existing_ec="$(get_json_field "$manifest" "exit_code" 2>/dev/null || echo "")"
        if [[ -z "$existing_ec" || "$existing_ec" == "null" ]]; then
          existing_ec=1
        fi
        update_manifest_status "$manifest" "$new_status" "$existing_ec" || true
      else
        update_manifest_status "$manifest" "$new_status" || true
      fi
      # Adjust counts for reporting? We'll recount next loop, but log now.
    else
      # Even without transition, log heartbeat for RUNNING every time? Only if debug?
      if [[ "$status" == "RUNNING" ]]; then
        log_event "WATCHER" "$worker_id" "heartbeat RUNNING tmux=$tmux_alive file_status=$file_status"
      fi
    fi

  done <<< "$manifests"

  echo "--- Summary: total=$count_total running=$count_running pending=$count_pending done=$count_done blocked=$count_blocked failed=$count_failed needs_review=$count_review ---"
  log_event "WATCHER" "-" "summary total=$count_total running=$count_running pending=$count_pending done=$count_done blocked=$count_blocked failed=$count_failed needs_review=$count_review"

  # Auto-dequeue: if there's room and queued tasks, spawn next
  QUEUE_FILE="$ORCH_DIR/queue.txt"
  if [[ -f "$QUEUE_FILE" && -s "$QUEUE_FILE" ]]; then
    MAX_CONCURRENT_WORKERS="${MAX_CONCURRENT_WORKERS:-5}"
    if [[ "$count_running" -lt "$MAX_CONCURRENT_WORKERS" ]]; then
      # Read first queued task
      QUEUED_LINE=$(head -n1 "$QUEUE_FILE")
      if [[ -n "$QUEUED_LINE" ]]; then
        log_event "WATCHER" "-" "auto-dequeue: found queued task, spawning (running=$count_running < max=$MAX_CONCURRENT_WORKERS)"
        echo "[watcher] Auto-dequeue: spawning next queued task"
        
        # Parse the JSON line (simple extraction)
        # This is a basic parser - for production use jq
        TASK_TYPE=$(echo "$QUEUED_LINE" | sed -E 's/.*"task_type":"([^"]+)".*/\1/')
        TASK_DESC=$(echo "$QUEUED_LINE" | sed -E 's/.*"task":"((\\.|[^"\\])*)".*/\1/' | sed 's/\\n/\n/g; s/\\"/"/g; s/\\\\/\\/g')
        ADAPTER=$(echo "$QUEUED_LINE" | sed -E 's/.*"adapter":"([^"]+)".*/\1/')
        BASE_BRANCH=$(echo "$QUEUED_LINE" | sed -E 's/.*"base_branch":"([^"]*)".*/\1/')
        
        # Remove the queued line
        tail -n +2 "$QUEUE_FILE" > "$QUEUE_FILE.tmp" 2>/dev/null && mv "$QUEUE_FILE.tmp" "$QUEUE_FILE" || true
        
        # Spawn the worker (in background to not block watcher)
        SPAWN_CMD="$SCRIPT_DIR/spawn-worker.sh --task-type \"$TASK_TYPE\" --task \"$TASK_DESC\" --adapter \"$ADAPTER\""
        if [[ -n "$BASE_BRANCH" ]]; then
          SPAWN_CMD="$SPAWN_CMD --base-branch \"$BASE_BRANCH\""
        fi
        
        # Run spawn in background, log output
        log_event "WATCHER" "-" "auto-dequeue: executing $SPAWN_CMD"
        bash -c "$SPAWN_CMD" >> "$LOGS_DIR/watcher.log" 2>&1 &
        
        echo "[watcher] Auto-dequeue: spawned worker for queued task"
      fi
    fi
  fi
}

# Main
echo "[watcher] Mode: $MODE interval: ${INTERVAL}s crew_dir: $CREW_DIR"
log_event "WATCHER" "-" "watcher started mode=$MODE interval=$INTERVAL"

if [[ "$MODE" == "once" ]]; then
  poll_once
else
  # watch loop
  trap 'echo ""; echo "[watcher] Stopping..."; log_event "WATCHER" "-" "watcher stopped"; exit 0' INT TERM
  while true; do
    echo ""
    echo "=== $(date -u +%Y-%m-%dT%H:%M:%SZ) ==="
    poll_once
    echo ""
    echo "[watcher] Sleeping ${INTERVAL}s (Ctrl-C to stop)..."
    sleep "$INTERVAL"
  done
fi
