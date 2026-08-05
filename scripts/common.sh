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

list_manifests() {
  find "$CREW_DIR" -maxdepth 2 -type f -name "manifest.json" 2>/dev/null | sort
}

ensure_orch_dirs() {
  mkdir -p "$CREW_DIR" "$LOGS_DIR" "$WORKTREES_DIR"
}

# detect_output_status <output.md> -> DONE|BLOCKED|FAILED|RUNNING
#
# The completion marker is honoured ONLY on the last non-empty line of the file.
#
# Why: output.md contains the worker's task brief, and a brief that documents the
# completion protocol ("append <!-- STATUS: DONE --> when finished") used to match
# a whole-file grep and complete the worker instantly. Any prose that mentions a
# marker - a brief, a quoted instruction, an agent thinking out loud - must not be
# able to end the worker. Only a marker the worker appends last counts.
# See .orchestrator/decisions/D001-spawn-injection-and-false-done.md
detect_output_status() {
  local out="$1" last
  if [[ ! -f "$out" ]]; then
    echo "RUNNING"
    return
  fi
  last="$(grep -v '^[[:space:]]*$' "$out" 2>/dev/null | tail -n 1)"
  case "$last" in
    *'<!--'*STATUS:*DONE*'-->'*)    echo "DONE" ;;
    *'<!--'*STATUS:*BLOCKED*'-->'*) echo "BLOCKED" ;;
    *'<!--'*STATUS:*FAILED*'-->'*)  echo "FAILED" ;;
    *)                              echo "RUNNING" ;;
  esac
}

# Export
export ROOT_DIR ORCH_DIR CREW_DIR LOGS_DIR WORKTREES_DIR ORCH_LOG
