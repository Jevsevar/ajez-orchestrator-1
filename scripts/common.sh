#!/usr/bin/env bash
# scripts/common.sh - Shared helpers for orchestrator scripts
# Sourced, not executed directly
# Bash only, no python/node deps

# Resolve root from this file location
_COMMON_SH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$_COMMON_SH_DIR/.." && pwd)"
ORCH_DIR="$ROOT_DIR/.orchestrator"
CREW_DIR="$ORCH_DIR/crew"
LOGS_DIR="$ORCH_DIR/logs"
WORKTREES_DIR="$ORCH_DIR/worktrees"
ORCH_LOG="$LOGS_DIR/orchestrator.log"

mkdir -p "$CREW_DIR" "$LOGS_DIR" "$WORKTREES_DIR" 2>/dev/null || true

# ---- Logging ----

_orch_timestamp() {
  date -u +"%Y-%m-%dT%H:%M:%SZ"
}

log_event() {
  # log_event <level> <worker-id|-> <message>
  local level="${1:-INFO}"
  local worker="${2:- -}"
  local msg="${3:-}"
  local ts
  ts="$(_orch_timestamp)"
  mkdir -p "$LOGS_DIR" 2>/dev/null || true
  printf "[%s] [%s] [%s] %s\n" "$ts" "$level" "$worker" "$msg" >> "$ORCH_LOG" 2>/dev/null || true
  # Also dedicated watcher log if level is WATCHER
  if [[ "$level" == "WATCHER" ]]; then
    printf "[%s] [%s] %s\n" "$ts" "$worker" "$msg" >> "$LOGS_DIR/watcher.log" 2>/dev/null || true
  fi
}

# ---- JSON helpers (bash only, optionally jq) ----

json_escape() {
  # Escape string for JSON double-quoted value
  local str="$1"
  str="${str//\\/\\\\}"
  str="${str//\"/\\\"}"
  str="${str//$'\n'/\\n}"
  str="${str//$'\r'/\\r}"
  str="${str//$'\t'/\\t}"
  printf '%s' "$str"
}

has_jq() {
  command -v jq >/dev/null 2>&1
}

get_json_field() {
  # get_json_field <file> <field>
  # Tries jq if available, else basic grep/sed for top-level string fields
  local file="$1"
  local field="$2"
  if [ ! -f "$file" ]; then
    return 1
  fi
  if has_jq; then
    jq -r --arg f "$field" '.[$f] // empty' "$file" 2>/dev/null
  else
    # Fallback: match "field": "value" or "field": number/null/boolean
    # This is brittle but works for our simple manifests
    local line
    line="$(grep -m1 "\"$field\"" "$file" 2>/dev/null || true)"
    if [ -z "$line" ]; then
      return 1
    fi
    # Extract quoted string
    if echo "$line" | grep -q "\"$field\"[[:space:]]*:[[:space:]]*\""; then
      echo "$line" | sed -E "s/.*\"$field\"[[:space:]]*:[[:space:]]*\"(.*)\".*/\1/" | sed 's/\\"/"/g' | sed 's/\\\\/\\/g'
    else
      # number, null, bool
      echo "$line" | sed -E "s/.*\"$field\"[[:space:]]*:[[:space:]]*([^,}]+).*/\1/" | tr -d '"' | xargs
    fi
  fi
}

update_manifest_status() {
  # update_manifest_status <manifest_path> <new_status> [exit_code]
  local manifest="$1"
  local new_status="$2"
  local exit_code="${3:-}"
  local now
  now="$(_orch_timestamp)"

  if [ ! -f "$manifest" ]; then
    echo "manifest not found: $manifest" >&2
    return 1
  fi

  if has_jq; then
    local tmp
    tmp="$(mktemp)"
    if [ -n "$exit_code" ]; then
      jq --arg s "$new_status" --arg ts "$now" --argjson ec "$exit_code" '.status=$s | .updated_at=$ts | .exit_code=$ec' "$manifest" > "$tmp" 2>/dev/null && mv "$tmp" "$manifest" || rm -f "$tmp"
    else
      jq --arg s "$new_status" --arg ts "$now" '.status=$s | .updated_at=$ts' "$manifest" > "$tmp" 2>/dev/null && mv "$tmp" "$manifest" || rm -f "$tmp"
    fi
  else
    # Sed fallback: replace status and updated_at lines
    # Assumes pretty-printed JSON with one field per line
    local esc_status
    esc_status="$(json_escape "$new_status")"
    local tmp
    tmp="$(mktemp)"
    # Update status
    sed -E "s/(\"status\"[[:space:]]*:[[:space:]]*\")[^\"]*(\")/\1${esc_status}\2/" "$manifest" > "$tmp" 2>/dev/null || cp "$manifest" "$tmp"
    # Update updated_at
    local tmp2
    tmp2="$(mktemp)"
    sed -E "s/(\"updated_at\"[[:space:]]*:[[:space:]]*\")[^\"]*(\")/\1${now}\2/" "$tmp" > "$tmp2" 2>/dev/null && mv "$tmp2" "$tmp" || rm -f "$tmp2"
    if [ -n "$exit_code" ]; then
      local tmp3
      tmp3="$(mktemp)"
      # replace exit_code: handles null or number
      if grep -q "\"exit_code\"" "$tmp"; then
        sed -E "s/(\"exit_code\"[[:space:]]*:[[:space:]]*)[^,}]+/\1${exit_code}/" "$tmp" > "$tmp3" 2>/dev/null && mv "$tmp3" "$tmp" || rm -f "$tmp3"
      else
        # append before closing }
        # not perfect but ok
        head -n -1 "$tmp" > "$tmp3" 2>/dev/null && printf ',\n  "exit_code": %s\n}\n' "$exit_code" >> "$tmp3" 2>/dev/null && mv "$tmp3" "$tmp" || rm -f "$tmp3"
      fi
    fi
    mv "$tmp" "$manifest"
  fi
  log_event "STATE" "$(basename "$(dirname "$manifest")")" "status -> $new_status"
}

generate_worker_id() {
  local prefix="${1:-worker}"
  local rand
  if command -v shuf >/dev/null 2>&1; then
    rand="$(shuf -i 1000-9999 -n 1 2>/dev/null || echo $RANDOM)"
  else
    rand="${RANDOM:-$$}"
  fi
  local ts
  ts="$(date +%s)"
  # Short git hash fragment if in git repo for uniqueness
  local short="0000"
  if git -C "$ROOT_DIR" rev-parse --short HEAD >/dev/null 2>&1; then
    short="$(git -C "$ROOT_DIR" rev-parse --short HEAD 2>/dev/null | cut -c1-4)"
  fi
  echo "${prefix}-${ts}-${rand}-${short}"
}

worker_dir() {
  # worker_dir <worker_id>
  echo "$CREW_DIR/$1"
}

manifest_path() {
  # manifest_path <worker_id>
  echo "$CREW_DIR/$1/manifest.json"
}

worktree_path() {
  # worktree_path <worker_id>
  echo "$WORKTREES_DIR/$1"
}

tmux_session_name() {
  # tmux_session_name <worker_id>
  # tmux session names cannot have . or : etc, sanitize
  local id="$1"
  id="${id//[^a-zA-Z0-9_-]/-}"
  echo "crew-$id"
}

is_tmux_alive() {
  # is_tmux_alive <session_name>
  local sess="$1"
  tmux has-session -t "$sess" 2>/dev/null
}

get_worker_pane_pid() {
  # get_worker_pane_pid <session_name>
  # Returns the pane PID for the worker's tmux session
  local sess="$1"
  tmux list-panes -t "$sess" -F "#{pane_pid}" 2>/dev/null | head -n1
}

is_worker_alive() {
  # is_worker_alive <worker_id> or <session_name>
  # Checks if the actual agent process is alive by walking the process tree
  # Returns 0 if alive, 1 if dead
  # Looks for known agent processes in the descendant tree of the tmux pane
  local worker_id="$1"
  local sess

  # If input looks like a session name (starts with crew-), use as-is, else construct
  if [[ "$worker_id" == crew-* ]]; then
    sess="$worker_id"
  else
    sess="$(tmux_session_name "$worker_id")"
  fi

  # Get the pane PID
  local pane_pid
  pane_pid="$(get_worker_pane_pid "$sess" 2>/dev/null || true)"

  if [[ -z "$pane_pid" ]]; then
    # No pane PID found, tmux session may be dead or not exist
    return 1
  fi

  # Check if pane PID is still alive
  if ! kill -0 "$pane_pid" 2>/dev/null; then
    return 1
  fi

  # Known agent process names to look for (actual workers, not shells)
  # We exclude bash/sh/zsh/fish because those are just the shell - we want the actual agent
  local known_agents="claude|codex|cursor-agent|aider|amp|python|python3|node|sleep"

  # Walk the process tree recursively
  # Get all descendant PIDs of the pane
  local descendants
  descendants="$(pgrep -P "$pane_pid" 2>/dev/null || true)"

  # If no direct children, check if pane itself is a worker
  if [[ -z "$descendants" ]]; then
    local pane_cmd
    pane_cmd="$(ps -p "$pane_pid" -o args= 2>/dev/null || true)"
    local pane_comm
    pane_comm="$(ps -p "$pane_pid" -o comm= 2>/dev/null | tr -d ' ' || true)"
    # Check if pane is running a known agent
    if echo "$pane_comm" | grep -Eq "$known_agents" || echo "$pane_cmd" | grep -Eq "$known_agents"; then
      return 0
    fi
    # If the pane is running bash and has no children, it's idle (zombie or completed)
    # We consider this "not alive" for a RUNNING worker
    if echo "$pane_cmd" | grep -q "bash" && ! echo "$pane_cmd" | grep -q "launch.sh"; then
      return 1
    fi
    # If it's running launch.sh, check if that's still active work
    if echo "$pane_cmd" | grep -q "launch.sh"; then
      # launch.sh is running but has no children - might be waiting or finished
      # Consider it alive for now (launch.sh will exit when done)
      return 0
    fi
    return 1
  fi

  # Recursively collect all descendants
  local all_pids="$descendants"
  local current_level="$descendants"
  local max_depth=10
  local depth=0

  while [[ -n "$current_level" && $depth -lt $max_depth ]]; do
    local next_level=""
    for pid in $current_level; do
      local children
      children="$(pgrep -P "$pid" 2>/dev/null || true)"
      if [[ -n "$children" ]]; then
        next_level="$next_level $children"
        all_pids="$all_pids $children"
      fi
    done
    current_level="$(echo "$next_level" | tr ' ' '\n' | sort -u | tr '\n' ' ' | xargs 2>/dev/null || true)"
    depth=$((depth + 1))
  done

  # Check if any descendant is a known agent process OR launch.sh
  for pid in $all_pids; do
    if kill -0 "$pid" 2>/dev/null; then
      local cmd
      cmd="$(ps -p "$pid" -o comm= 2>/dev/null | tr -d ' ' || true)"
      # Also check full command line for agents that might show as different process names
      local cmdline
      cmdline="$(ps -p "$pid" -o args= 2>/dev/null | head -c 200 || true)"

      if echo "$cmd" | grep -Eq "$known_agents" || \
         echo "$cmdline" | grep -Eq "(claude|codex|cursor-agent|aider|amp|launch\.sh|adapter)" ; then
        return 0
      fi
    fi
  done

  # Check the pane process itself as well (for launch.sh running directly)
  local pane_cmdline
  pane_cmdline="$(ps -p "$pane_pid" -o args= 2>/dev/null || true)"
  if echo "$pane_cmdline" | grep -Eq "launch\.sh" ; then
    return 0
  fi

  # No known agent processes found in the tree - this is a zombie
  return 1
}

get_worker_process_status() {
  # get_worker_process_status <worker_id>
  # Returns a descriptive status string about the worker's process state
  local worker_id="$1"
  local sess
  sess="$(tmux_session_name "$worker_id")"

  if ! is_tmux_alive "$sess"; then
    echo "tmux_dead"
    return
  fi

  local pane_pid
  pane_pid="$(get_worker_pane_pid "$sess" 2>/dev/null || true)"

  if [[ -z "$pane_pid" ]]; then
    echo "no_pane"
    return
  fi

  if ! kill -0 "$pane_pid" 2>/dev/null; then
    echo "pane_dead"
    return
  fi

  if is_worker_alive "$worker_id"; then
    echo "alive"
  else
    echo "zombie"
  fi
}

list_manifests() {
  find "$CREW_DIR" -maxdepth 2 -type f -name "manifest.json" 2>/dev/null | sort
}

ensure_orch_dirs() {
  mkdir -p "$CREW_DIR" "$LOGS_DIR" "$WORKTREES_DIR"
}

shell_quote() {
  # Print a bash-escaped version of the argument suitable for reuse in shell code
  # Uses printf %q which produces $'...' style quoting when needed
  # Usage: quoted=$(shell_quote "$value")
  printf '%q' "$1"
}

validate_completion() {
  # validate_completion <manifest_path> <output_path> <worktree_path>
  # Returns 0 if validation passes, 1 if fails, 2 if needs review
  # For ship tasks: verify at least one commit on the branch
  # For scout tasks: verify output.md is non-empty (>50 bytes)
  local manifest="$1"
  local output_path="$2"
  local worktree_path="$3"

  if [[ ! -f "$manifest" ]]; then
    echo "manifest not found" >&2
    return 1
  fi

  local task_type
  task_type="$(get_json_field "$manifest" "task_type" 2>/dev/null || echo "")"
  local branch
  branch="$(get_json_field "$manifest" "branch" 2>/dev/null || echo "")"

  case "$task_type" in
    ship)
      # For ship tasks, verify there's at least one commit on the crew branch
      # that is not on the base branch
      if [[ -z "$branch" || ! -d "$worktree_path/.git" && ! -f "$worktree_path/.git" ]]; then
        # Not a git worktree or no branch info - can't validate commits
        # Check if there are any files created/modified as fallback
        if [[ -d "$worktree_path" ]]; then
          local file_count
          file_count="$(find "$worktree_path" -type f ! -name ".git" ! -path "*/.git/*" 2>/dev/null | wc -l | tr -d ' ')"
          if [[ "$file_count" -gt 2 ]]; then
            return 0
          else
            echo "ship task: no commits found and minimal files in worktree" >&2
            return 2
          fi
        else
          echo "ship task: worktree not found" >&2
          return 1
        fi
      fi

      # Check for commits on this branch
      if git -C "$ROOT_DIR" rev-parse --verify "$branch" >/dev/null 2>&1; then
        local commit_count
        commit_count="$(git -C "$ROOT_DIR" rev-list --count "$branch" 2>/dev/null || echo "0")"
        # Get base ref to compare
        local base_ref
        base_ref="$(get_json_field "$manifest" "base_ref" 2>/dev/null || echo "HEAD")"
        local base_count
        if git -C "$ROOT_DIR" rev-parse --verify "$base_ref" >/dev/null 2>&1; then
          base_count="$(git -C "$ROOT_DIR" rev-list --count "$base_ref" 2>/dev/null || echo "0")"
        else
          base_count="0"
        fi

        if [[ "$commit_count" -gt "$base_count" ]]; then
          return 0
        else
          echo "ship task: no new commits on branch $branch (commits: $commit_count, base: $base_count)" >&2
          return 2
        fi
      else
        echo "ship task: branch $branch not found" >&2
        return 2
      fi
      ;;
    scout)
      # For scout tasks, verify output.md exists and is non-empty (>50 bytes)
      if [[ -f "$output_path" ]]; then
        local size
        size="$(wc -c < "$output_path" 2>/dev/null || echo "0")"
        size="${size//[[:space:]]/}"
        if [[ "$size" -gt 50 ]]; then
          # Also check it has some actual content beyond the header
          local content_lines
          content_lines="$(grep -v "^#" "$output_path" 2>/dev/null | grep -v "^$" | grep -v "^- \*\*" | wc -l | tr -d ' ')"
          if [[ "$content_lines" -gt 3 ]]; then
            return 0
          else
            echo "scout task: output.md too sparse (only $content_lines content lines)" >&2
            return 2
          fi
        else
          echo "scout task: output.md too small ($size bytes, need >50)" >&2
          return 2
        fi
      else
        echo "scout task: output.md not found at $output_path" >&2
        return 1
      fi
      ;;
    *)
      # Unknown task type - just check output exists
      if [[ -f "$output_path" && -s "$output_path" ]]; then
        return 0
      else
        echo "unknown task type: output missing or empty" >&2
        return 1
      fi
      ;;
  esac
}

# Export
export ROOT_DIR ORCH_DIR CREW_DIR LOGS_DIR WORKTREES_DIR ORCH_LOG
