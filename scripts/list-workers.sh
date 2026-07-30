#!/usr/bin/env bash
# scripts/list-workers.sh - List all workers in a table
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

# Simple wrapper around collect-output --list but also shows tmux status

echo "Crew workers in $CREW_DIR"
echo ""

printf "%-32s %-5s %-9s %-7s %-6s %s\n" "ID" "TYPE" "STATUS" "TMUX" "PID" "TASK"
printf "%-32s %-5s %-9s %-7s %-6s %s\n" "--------------------------------" "-----" "---------" "-------" "------" "----"

for m in $(list_manifests); do
  [[ -z "$m" ]] && continue
  id="$(get_json_field "$m" "id" 2>/dev/null || basename "$(dirname "$m")")"
  type="$(get_json_field "$m" "task_type" 2>/dev/null || "?")"
  status="$(get_json_field "$m" "status" 2>/dev/null || "?")"
  tmux_sess="$(get_json_field "$m" "tmux_session" 2>/dev/null || "")"
  pid="$(get_json_field "$m" "pid" 2>/dev/null || "-")"
  task="$(get_json_field "$m" "task" 2>/dev/null || "")"
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
  short_task="${task:0:50}"
  printf "%-32s %-5s %-9s %-7s %-6s %s\n" "${id:0:32}" "$type" "$status" "$tmux_state" "$pid" "$short_task"
done
echo ""
echo "Total: $(list_manifests | wc -l | xargs) workers"
