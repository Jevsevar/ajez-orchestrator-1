#!/usr/bin/env bash
# scripts/list-workers.sh - List all workers in a table
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

# Shows detailed worker status including process health and output staleness

echo "Crew workers in $CREW_DIR"
echo ""

printf "%-28s %-5s %-11s %-6s %-8s %-8s %s\n" "ID" "TYPE" "STATUS" "TMUX" "WORKER" "OUTPUT" "TASK"
printf "%-28s %-5s %-11s %-6s %-8s %-8s %s\n" "----------------------------" "-----" "-----------" "------" "--------" "--------" "----"

for m in $(list_manifests); do
  [[ -z "$m" ]] && continue
  id="$(get_json_field "$m" "id" 2>/dev/null || basename "$(dirname "$m")")"
  type="$(get_json_field "$m" "task_type" 2>/dev/null || "?")"
  status="$(get_json_field "$m" "status" 2>/dev/null || "?")"
  tmux_sess="$(get_json_field "$m" "tmux_session" 2>/dev/null || "")"
  pid="$(get_json_field "$m" "pid" 2>/dev/null || "-")"
  task="$(get_json_field "$m" "task" 2>/dev/null || "")"
  output_path="$(get_json_field "$m" "output_path" 2>/dev/null || "")"
  
  # Resolve output path
  abs_output=""
  if [[ -n "$output_path" ]]; then
    if [[ "$output_path" == /* ]]; then
      abs_output="$output_path"
    else
      abs_output="$ROOT_DIR/$output_path"
    fi
  fi
  if [[ ! -f "$abs_output" ]]; then
    abs_output="$(dirname "$m")/output.md"
  fi
  
  # Check tmux status
  tmux_state="?"
  if [[ -n "$tmux_sess" ]]; then
    if tmux has-session -t "$tmux_sess" 2>/dev/null; then
      tmux_state="alive"
    else
      tmux_state="dead"
    fi
  else
    tmux_state="none"
  fi
  
  # Check worker process status (only for RUNNING workers)
  worker_state="?"
  if [[ "$status" == "RUNNING" && "$tmux_state" == "alive" && -n "$tmux_sess" ]]; then
    if is_worker_alive "$tmux_sess" "$id" 2>/dev/null; then
      worker_state="alive"
    else
      worker_state="dead"
    fi
  elif [[ "$status" != "RUNNING" ]]; then
    worker_state="n/a"
  else
    worker_state="?"
  fi
  
  # Check output staleness
  output_state="?"
  if [[ -f "$abs_output" ]]; then
    output_mtime="$(stat -f %m "$abs_output" 2>/dev/null || stat -c %Y "$abs_output" 2>/dev/null || echo "0")"
    current_time="$(date +%s)"
    age=$((current_time - output_mtime))
    if [[ "$age" -lt 60 ]]; then
      output_state="fresh"
    elif [[ "$age" -lt 240 ]]; then
      output_state="${age}s"
    else
      output_state="STALE"
    fi
  else
    output_state="none"
  fi
  
  short_task="${task:0:40}"
  printf "%-28s %-5s %-11s %-6s %-8s %-8s %s\n" "${id:0:28}" "$type" "$status" "$tmux_state" "$worker_state" "$output_state" "$short_task"
done
echo ""
echo "Total: $(list_manifests | wc -l | xargs) workers"
echo ""
echo "Legend:"
echo "  TMUX: tmux session alive/dead"
echo "  WORKER: agent process alive/dead (for RUNNING workers)"
echo "  OUTPUT: fresh (<60s), age in seconds, or STALE (>240s)"
