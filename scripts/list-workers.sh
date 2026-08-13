#!/usr/bin/env bash
# scripts/list-workers.sh - List all workers in a table
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

# Shows tmux status and actual worker process status

echo "Crew workers in $CREW_DIR"
echo ""

printf "%-32s %-5s %-9s %-7s %-8s %-6s %s\n" "ID" "TYPE" "STATUS" "TMUX" "PROC" "PID" "TASK"
printf "%-32s %-5s %-9s %-7s %-8s %-6s %s\n" "--------------------------------" "-----" "---------" "-------" "--------" "------" "----"

for m in $(list_manifests); do
  [[ -z "$m" ]] && continue
  id="$(get_json_field "$m" "id" 2>/dev/null || basename "$(dirname "$m")")"
  type="$(get_json_field "$m" "task_type" 2>/dev/null || "?")"
  status="$(get_json_field "$m" "status" 2>/dev/null || "?")"
  tmux_sess="$(get_json_field "$m" "tmux_session" 2>/dev/null || "")"
  pid="$(get_json_field "$m" "pid" 2>/dev/null || "-")"
  task="$(get_json_field "$m" "task" 2>/dev/null || "")"
  tmux_state="?"
  proc_state="?"
  if [[ -n "$tmux_sess" ]]; then
    if is_tmux_alive "$tmux_sess"; then
      tmux_state="alive"
      # Get richer process status
      proc_state="$(get_worker_process_status "$id" 2>/dev/null || echo "unknown")"
    else
      tmux_state="dead"
      proc_state="tmux_dead"
    fi
  else
    tmux_state="none"
    proc_state="none"
  fi
  short_task="${task:0:48}"
  printf "%-32s %-5s %-9s %-7s %-8s %-6s %s\n" "${id:0:32}" "$type" "$status" "$tmux_state" "$proc_state" "$pid" "$short_task"
done
echo ""
echo "PROC status: alive=zombie check passed, zombie=tmux alive but no agent, tmux_dead=session dead"
echo "Total: $(list_manifests | wc -l | xargs) workers"
