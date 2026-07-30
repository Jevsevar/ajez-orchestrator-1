#!/usr/bin/env bash
# scripts/collect-output.sh - Gathers results from completed workers
# Usage:
#   ./scripts/collect-output.sh --all
#   ./scripts/collect-output.sh --worker <id>
#   ./scripts/collect-output.sh --status DONE --format markdown
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

MODE="summary"
WORKER_ID=""
FILTER_STATUS=""
FORMAT="text"
OUTPUT_FILE=""
MERGE_BRANCHES="false"

usage() {
  cat <<'USAGE'
collect-output.sh - Gather results from workers

Usage:
  ./scripts/collect-output.sh --all
  ./scripts/collect-output.sh --worker <worker-id>
  ./scripts/collect-output.sh --status DONE
  ./scripts/collect-output.sh --report          # generate .orchestrator/report.md
  ./scripts/collect-output.sh --list

Options:
  --all               Collect all completed (DONE|BLOCKED|FAILED) workers
  --worker ID         Collect specific worker
  --status STATUS     Filter by status (DONE, BLOCKED, FAILED, RUNNING, etc)
  --format FORMAT     Output format: text, markdown, json (default: text)
  --report            Generate combined report at .orchestrator/report.md
  --list              List workers table
  --merge-branches    Show git commands to merge ship branches (for --all or --report)
  -o, --output FILE   Write to file instead of stdout
  -h, --help          Help

Examples:
  ./scripts/collect-output.sh --list
  ./scripts/collect-output.sh --all --format markdown
  ./scripts/collect-output.sh --worker worker-1234567890-1234-0000
  ./scripts/collect-output.sh --report --merge-branches

Task type handling:
  - scout: output is investigation report (markdown)
  - ship: output includes code changes; check worktree diff

USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --all) MODE="all"; shift;;
    --worker) MODE="single"; WORKER_ID="$2"; shift 2;;
    --status) MODE="filter"; FILTER_STATUS="$2"; shift 2;;
    --format) FORMAT="$2"; shift 2;;
    --report) MODE="report"; shift;;
    --list) MODE="list"; shift;;
    --merge-branches) MERGE_BRANCHES="true"; shift;;
    -o|--output) OUTPUT_FILE="$2"; shift 2;;
    -h|--help) usage; exit 0;;
    *) echo "Unknown arg: $1" >&2; usage; exit 1;;
  esac
done

ensure_orch_dirs

# Helper to get output path for manifest
get_output_abs_path() {
  local manifest="$1"
  local dir
  dir="$(dirname "$manifest")"
  local rel
  rel="$(get_json_field "$manifest" "output_path" 2>/dev/null || echo "$dir/output.md")"
  local abs
  if [[ "$rel" == /* ]]; then
    abs="$rel"
  elif [[ -f "$ROOT_DIR/$rel" ]]; then
    abs="$ROOT_DIR/$rel"
  elif [[ -f "$dir/output.md" ]]; then
    abs="$dir/output.md"
  else
    abs="$ROOT_DIR/$rel"
  fi
  echo "$abs"
}

print_worker_output() {
  local manifest="$1"
  local worker_id task_type task_desc status created worktree branch output_path
  worker_id="$(get_json_field "$manifest" "id" 2>/dev/null || basename "$(dirname "$manifest")")"
  task_type="$(get_json_field "$manifest" "task_type" 2>/dev/null || echo "unknown")"
  task_desc="$(get_json_field "$manifest" "task" 2>/dev/null || echo "")"
  status="$(get_json_field "$manifest" "status" 2>/dev/null || echo "UNKNOWN")"
  created="$(get_json_field "$manifest" "created_at" 2>/dev/null || echo "")"
  worktree="$(get_json_field "$manifest" "worktree_path" 2>/dev/null || echo "")"
  branch="$(get_json_field "$manifest" "branch" 2>/dev/null || echo "")"
  output_path="$(get_output_abs_path "$manifest")"

  local out_content=""
  if [[ -f "$output_path" ]]; then
    out_content="$(cat "$output_path" 2>/dev/null || echo "(failed to read)")"
  else
    out_content="(output not found: $output_path)"
  fi

  if [[ "$FORMAT" == "json" ]]; then
    # JSON per worker
    local esc_out esc_task
    esc_out="$(json_escape "$out_content")"
    esc_task="$(json_escape "$task_desc")"
    cat <<JSON
{
  "id": "$(json_escape "$worker_id")",
  "task_type": "$(json_escape "$task_type")",
  "task": "$esc_task",
  "status": "$(json_escape "$status")",
  "created_at": "$(json_escape "$created")",
  "worktree_path": "$(json_escape "$worktree")",
  "branch": "$(json_escape "$branch")",
  "output": "$esc_out"
}
JSON
  elif [[ "$FORMAT" == "markdown" ]]; then
    cat <<MD
## Worker: $worker_id
- **Type:** $task_type
- **Status:** $status
- **Task:** $task_desc
- **Created:** $created
- **Branch:** $branch
- **Worktree:** $worktree

### Output

$out_content

---
MD
  else
    # text
    cat <<TEXT
================================================================================
Worker: $worker_id
  Type: $task_type
  Status: $status
  Task: $task_desc
  Branch: $branch
  Worktree: $worktree
  Manifest: $manifest
  Output: $output_path
================================================================================
$output_path content:
--------------------------------------------------------------------------------
$out_content
--------------------------------------------------------------------------------

TEXT
  fi
}

list_workers_table() {
  printf "%-36s %-6s %-8s %-12s %s\n" "WORKER ID" "TYPE" "STATUS" "BRANCH" "TASK (truncated)"
  printf "%-36s %-6s %-8s %-12s %s\n" "------------------------------------" "------" "--------" "------------" "----------------"
  local m
  for m in $(list_manifests 2>/dev/null); do
    [[ -z "$m" ]] && continue
    local id type status branch task
    id="$(get_json_field "$m" "id" 2>/dev/null || basename "$(dirname "$m")")"
    type="$(get_json_field "$m" "task_type" 2>/dev/null || echo "?")"
    status="$(get_json_field "$m" "status" 2>/dev/null || echo "?")"
    branch="$(get_json_field "$m" "branch" 2>/dev/null || echo "?")"
    task="$(get_json_field "$m" "task" 2>/dev/null || echo "")"
    # truncate task to 60 chars
    local short_task="${task:0:60}"
    if [[ ${#task} -gt 60 ]]; then short_task="${short_task}..."
    fi
    printf "%-36s %-6s %-8s %-12s %s\n" "$id" "$type" "$status" "$(basename "$branch")" "$short_task"
  done
}

collect_matching() {
  local filter_status="$1"  # may be empty for all terminal
  local count=0
  for manifest in $(list_manifests); do
    [[ -z "$manifest" ]] && continue
    local status
    status="$(get_json_field "$manifest" "status" 2>/dev/null || echo "UNKNOWN")"
    if [[ -n "$filter_status" ]]; then
      if [[ "$status" != "$filter_status" ]]; then
        continue
      fi
    else
      # default: terminal states if MODE=all, else all?
      if [[ "$MODE" == "all" ]]; then
        if [[ "$status" != "DONE" && "$status" != "BLOCKED" && "$status" != "FAILED" ]]; then
          continue
        fi
      fi
    fi
    print_worker_output "$manifest"
    count=$((count+1))
    if [[ "$FORMAT" == "json" && "$count" -gt 0 ]]; then
      # JSON array handling will be done outside? For --all we need commas
      # We'll cheat: json format for --all outputs newline separated JSON objects; for real array use --report json?
      true
    fi
  done
  if [[ $count -eq 0 ]]; then
    echo "(no matching workers found)" >&2
  fi
  log_event "COLLECT" "-" "collected $count workers mode=$MODE filter=$filter_status format=$FORMAT"
}

generate_report() {
  local report_path="$ORCH_DIR/report.md"
  if [[ -n "$OUTPUT_FILE" ]]; then
    report_path="$OUTPUT_FILE"
  fi

  echo "[collect] Generating report at $report_path"
  {
    echo "# Crew Report"
    echo ""
    echo "Generated: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "Root: $ROOT_DIR"
    echo ""
    echo "## Summary"
    echo ""
    echo "| Worker ID | Type | Status | Branch | Task |"
    echo "|---|---|---|---|---|"
    for m in $(list_manifests); do
      [[ -z "$m" ]] && continue
      local id type status branch task
      id="$(get_json_field "$m" "id" 2>/dev/null || basename "$(dirname "$m")")"
      type="$(get_json_field "$m" "task_type" 2>/dev/null || "?")"
      status="$(get_json_field "$m" "status" 2>/dev/null || "?")"
      branch="$(get_json_field "$m" "branch" 2>/dev/null || "?")"
      task="$(get_json_field "$m" "task" 2>/dev/null || "")"
      # escape pipe
      task="${task//|/\\|}"
      task="${task:0:80}"
      echo "| $id | $type | $status | $branch | $task |"
    done
    echo ""
    echo "## Worker Details"
    echo ""
    for m in $(list_manifests); do
      [[ -z "$m" ]] && continue
      local m_status
      m_status="$(get_json_field "$m" "status" 2>/dev/null || echo "")"
      # Only include terminal for report unless list all requested?
      # For now include all
      local id type status task_desc worktree branch out_path
      id="$(get_json_field "$m" "id" 2>/dev/null || basename "$(dirname "$m")")"
      type="$(get_json_field "$m" "task_type" 2>/dev/null || "")"
      status="$(get_json_field "$m" "status" 2>/dev/null || "")"
      task_desc="$(get_json_field "$m" "task" 2>/dev/null || "")"
      worktree="$(get_json_field "$m" "worktree_path" 2>/dev/null || "")"
      branch="$(get_json_field "$m" "branch" 2>/dev/null || "")"
      out_path="$(get_output_abs_path "$m")"
      echo "### $id ($status)"
      echo ""
      echo "- **Type:** $type"
      echo "- **Task:** $task_desc"
      echo "- **Branch:** \`$branch\`"
      echo "- **Worktree:** \`$worktree\`"
      echo "- **Output:** \`$out_path\`"
      echo ""
      if [[ -f "$out_path" ]]; then
        # Extract result section maybe
        echo "<details>"
        echo "<summary>Output (click to expand)</summary>"
        echo ""
        echo '```markdown'
        cat "$out_path" 2>/dev/null | head -n 500
        echo '```'
        echo "</details>"
        echo ""
      else
        echo "(no output file)"
        echo ""
      fi
      if [[ "$MERGE_BRANCHES" == "true" && "$type" == "ship" && "$status" == "DONE" ]]; then
        echo "**Merge suggestion:**"
        echo '```bash'
        echo "git log --oneline $branch ^main"
        echo "git merge --no-ff $branch   # or cherry-pick / review"
        echo "git worktree remove $worktree # after merge"
        echo '```'
        echo ""
      fi
    done

    if [[ "$MERGE_BRANCHES" == "true" ]]; then
      echo "## Merge Commands for ship workers"
      echo ""
      echo '```bash'
      for m in $(list_manifests); do
        local type status branch
        type="$(get_json_field "$m" "task_type" 2>/dev/null || "")"
        status="$(get_json_field "$m" "status" 2>/dev/null || "")"
        branch="$(get_json_field "$m" "branch" 2>/dev/null || "")"
        if [[ "$type" == "ship" && "$status" == "DONE" ]]; then
          echo "# $branch"
          echo "git show --stat $branch"
          echo "git diff main..$branch"
          echo ""
        fi
      done
      echo '```'
    fi

  } > "$report_path"

  echo "[collect] Report written to $report_path"
  cat "$report_path"
  log_event "COLLECT" "-" "generated report $report_path"
}

# Main dispatch

# If OUTPUT_FILE and not report, redirect
if [[ -n "$OUTPUT_FILE" && "$MODE" != "report" ]]; then
  exec > "$OUTPUT_FILE"
  echo "[collect] Writing to $OUTPUT_FILE"
fi

case "$MODE" in
  list)
    list_workers_table
    ;;
  single)
    FOUND=""
    for m in $(list_manifests); do
      mid="$(get_json_field "$m" "id" 2>/dev/null || basename "$(dirname "$m")")"
      if [[ "$mid" == "$WORKER_ID" ]]; then
        FOUND="$m"
        break
      fi
    done
    if [[ -z "$FOUND" ]]; then
      echo "Error: Worker $WORKER_ID not found" >&2
      echo "Available:" >&2
      list_workers_table >&2
      exit 1
    fi
    print_worker_output "$FOUND"
    ;;
  filter)
    collect_matching "$FILTER_STATUS"
    ;;
  all)
    # Collect DONE,BLOCKED,FAILED
    collect_matching ""
    ;;
  summary|*)
    # Default: list + show summary
    list_workers_table
    echo ""
    echo "To collect outputs:"
    echo "  ./scripts/collect-output.sh --all --format markdown"
    echo "  ./scripts/collect-output.sh --report"
    ;;
esac

if [[ "$MODE" == "report" ]]; then
  generate_report
fi
