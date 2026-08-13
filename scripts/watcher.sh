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
MAX_CONCURRENT_WORKERS="${MAX_CONCURRENT_WORKERS:-5}"
QUEUE_FILE="$ORCH_DIR/queue.txt"

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
  # Check last 100 lines for markers (cheap)
  local tail_content
  tail_content="$(tail -n 200 "$out" 2>/dev/null || cat "$out")"
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

process_queue() {
  # Process queued tasks if slots available
  if [[ ! -f "$QUEUE_FILE" || ! -s "$QUEUE_FILE" ]]; then
    return 0
  fi
  
  local running
  running="$(count_running_workers)"
  
  if [[ "$running" -ge "$MAX_CONCURRENT_WORKERS" ]]; then
    return 0
  fi
  
  local queue_size
  queue_size="$(wc -l < "$QUEUE_FILE" | tr -d ' ')"
  
  log_event "WATCHER" "queue" "Processing queue: $running/$MAX_CONCURRENT_WORKERS running, $queue_size queued"
  
  # Process up to available slots
  local slots_available
  slots_available=$((MAX_CONCURRENT_WORKERS - running))
  
  while [[ $slots_available -gt 0 && -s "$QUEUE_FILE" ]]; do
    # Read first line
    local line
    line="$(head -n1 "$QUEUE_FILE" 2>/dev/null || true)"
    
    [[ -z "$line" ]] && break
    
    # Remove first line atomically
    local tmp_queue
    tmp_queue="$(mktemp)"
    tail -n +2 "$QUEUE_FILE" > "$tmp_queue" 2>/dev/null || true
    mv "$tmp_queue" "$QUEUE_FILE" 2>/dev/null || rm -f "$tmp_queue"
    
    # Parse
    IFS='|' read -r timestamp task_type task_desc adapter custom_id base_branch <<< "$line"
    task_desc="${task_desc//\\|/|}"
    
    log_event "WATCHER" "queue" "Dequeuing: $task_type - ${task_desc:0:50}"
    
    # Build command
    local spawn_script="$SCRIPT_DIR/spawn-worker.sh"
    local cmd=("$spawn_script" "--task-type" "$task_type" "--task" "$task_desc" "--adapter" "$adapter")
    [[ -n "$custom_id" ]] && cmd+=("--id" "$custom_id")
    [[ -n "$base_branch" ]] && cmd+=("--base-branch" "$base_branch")
    
    # Spawn in background
    "${cmd[@]}" &
    
    slots_available=$((slots_available - 1))
    
    # Small delay between dequeues to avoid thundering herd
    sleep 1
  done
}

count_running_workers() {
  # Count workers in RUNNING or SPAWNING state
  local count=0
  local manifests
  manifests="$(list_manifests 2>/dev/null || true)"
  
  while IFS= read -r manifest; do
    [[ -z "$manifest" ]] && continue
    local status
    status="$(get_json_field "$manifest" "status" 2>/dev/null || echo "")"
    if [[ "$status" == "RUNNING" || "$status" == "SPAWNING" ]]; then
      count=$((count + 1))
    fi
  done <<< "$manifests"
  
  echo "$count"
}

poll_once() {
  local manifest
  local count_total=0
  local count_running=0
  local count_done=0
  local count_blocked=0
  local count_failed=0
  local count_pending=0
  local count_needs_review=0

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
    local proc_status="unknown"
    if [[ -n "$tmux_sess" ]]; then
      if is_tmux_alive "$tmux_sess"; then
        tmux_alive="alive"
        # Check if actual worker process is alive
        proc_status="$(get_worker_process_status "$worker_id" 2>/dev/null || echo "unknown")"
      else
        tmux_alive="dead"
        proc_status="tmux_dead"
      fi
    fi

    local action="none"
    local new_status="$status"

    case "$status" in
      PENDING|SPAWNING)
        # If output shows DONE etc, we should transition anyway
        if [[ "$file_status" == "DONE" ]]; then
          # Validate completion before marking DONE
          if validate_completion "$manifest" "$abs_output" "$worktree" 2>/dev/null; then
            new_status="DONE"
            action="output->DONE (validated)"
          else
            local val_msg
            val_msg="$(validate_completion "$manifest" "$abs_output" "$worktree" 2>&1 || true)"
            new_status="NEEDS_REVIEW"
            action="output->DONE but validation failed: $val_msg"
          fi
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
          # Validate completion before accepting DONE
          if validate_completion "$manifest" "$abs_output" "$worktree" 2>/dev/null; then
            new_status="DONE"
            action="completed (validated)"
          else
            local val_msg
            val_msg="$(validate_completion "$manifest" "$abs_output" "$worktree" 2>&1 || true)"
            new_status="NEEDS_REVIEW"
            action="completed but validation failed: $val_msg"
            log_event "WATCHER" "$worker_id" "validation failed: $val_msg"
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
          # No marker yet, check process liveness and output staleness
          if [[ "$tmux_alive" == "dead" ]]; then
            # tmux dead but no final marker -> FAILED
            # Do NOT auto-mark as DONE - that's the false-DONE problem
            new_status="FAILED"
            action="tmux dead with no STATUS marker -> FAILED"
          elif [[ "$proc_status" == "zombie" ]]; then
            # tmux alive but no actual worker process (zombie)
            new_status="FAILED"
            action="worker process dead (zombie) -> FAILED"
          elif [[ "$proc_status" == "alive" ]]; then
            # Worker is alive, check if output is stale (no updates in 240s)
            if [[ -f "$abs_output" ]]; then
              local output_mtime
              output_mtime="$(stat -f %m "$abs_output" 2>/dev/null || stat -c %Y "$abs_output" 2>/dev/null || echo "0")"
              local now
              now="$(date +%s)"
              local age
              age=$((now - output_mtime))
              if [[ $age -gt 240 ]]; then
                new_status="BLOCKED"
                action="output stale (${age}s) -> BLOCKED"
                log_event "WATCHER" "$worker_id" "output stale for ${age}s, escalating to BLOCKED"
              fi
            fi
          fi
        fi
        ;;
      DONE|BLOCKED|FAILED|NEEDS_REVIEW)
        # Terminal states, but re-validate DONE if needed
        if [[ "$status" == "DONE" && "$file_status" == "DONE" ]]; then
          if ! validate_completion "$manifest" "$abs_output" "$worktree" 2>/dev/null; then
            local val_msg
            val_msg="$(validate_completion "$manifest" "$abs_output" "$worktree" 2>&1 || true)"
            new_status="NEEDS_REVIEW"
            action="DONE but validation failed on re-check: $val_msg"
            log_event "WATCHER" "$worker_id" "re-validation failed: $val_msg"
          fi
        fi
        # Otherwise no change
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
      NEEDS_REVIEW) count_needs_review=$((count_needs_review+1));;
      PENDING|SPAWNING) count_pending=$((count_pending+1));;
    esac

    # Log state
    printf "[watcher] %-30s status=%-8s tmux=%-6s proc=%-8s file=%-7s -> %-8s (%s)\n" "$worker_id" "$status" "$tmux_alive" "$proc_status" "$file_status" "$new_status" "$action"

    if [[ "$new_status" != "$status" ]]; then
      echo "[watcher] Transition $worker_id: $status -> $new_status ($action)"
      log_event "WATCHER" "$worker_id" "transition $status -> $new_status reason=$action tmux=$tmux_alive proc=$proc_status file_status=$file_status"
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

  echo "--- Summary: total=$count_total running=$count_running pending=$count_pending done=$count_done blocked=$count_blocked failed=$count_failed needs_review=$count_needs_review ---"
  log_event "WATCHER" "-" "summary total=$count_total running=$count_running pending=$count_pending done=$count_done blocked=$count_blocked failed=$count_failed needs_review=$count_needs_review"
  
  # Process queue if slots available
  process_queue
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
