#!/usr/bin/env bash
# scripts/spawn-worker.sh - Spawn a new worker: worktree + tmux pane + agent
# Enhanced with robust error handling:
#   - validates tmux binary and ensures tmux server is running (starts if needed)
#   - checks git repo clean state before worktree creation
#   - clear error messages with actionable hints and distinct exit codes
#   - creates .orchestrator/crew/<id>/ with initial manifest in PENDING state
#
# Usage:
#   ./scripts/spawn-worker.sh --task-type ship|scout --task "description" [--adapter claude-code|generic] [--id custom-id] [--base-branch main] [--allow-dirty] [--force] [--dry-run]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

# Defaults
TASK_TYPE=""
TASK_DESC=""
ADAPTER="generic"
CUSTOM_ID=""
BASE_BRANCH=""
DRY_RUN="false"
ALLOW_DIRTY="false"
FORCE="false"
QUEUE="false"

# Max concurrent workers (can be overridden by env var)
MAX_CONCURRENT_WORKERS="${MAX_CONCURRENT_WORKERS:-5}"
QUEUE_FILE="$ORCH_DIR/queue.txt"
STAGGER_DELAY=2  # seconds between spawns in batch mode

# Colors for error clarity (fallback to no color if not tty)
RED='\033[0;31m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'
if [[ ! -t 2 ]]; then
  RED=''; YELLOW=''; CYAN=''; NC=''
fi

usage() {
  cat <<'USAGE'
spawn-worker.sh - Spawn a new crew worker

Usage:
  ./scripts/spawn-worker.sh --task-type <ship|scout> --task "<description>" [options]

Required:
  --task-type  Task type: ship (deliver code) or scout (investigation)
  --task       Task description string

Options:
  --adapter      Adapter name: claude-code | generic (default: generic)
  --id           Custom worker id (default: auto-generated)
  --base-branch  Base branch for worktree (default: current HEAD or main)
  --allow-dirty  Allow spawning even if git repo has uncommitted changes
  --force        Force overwrite: remove existing worker dir/worktree/branch/session if they exist
  --dry-run      Print what would happen without spawning
  --queue        If at max workers, queue task instead of refusing
  --no-stagger   Skip the 2-second delay between batch spawns
  -h, --help     Show this help

Environment:
  MAX_CONCURRENT_WORKERS  Max parallel workers (default: 5)
  ORCHESTRATOR_NO_STAGGER Skip stagger delay if set

Lifecycle:
  PENDING -> SPAWNING -> RUNNING -> DONE | BLOCKED | FAILED

State:
  All state is stored in .orchestrator/crew/<worker-id>/manifest.json
  Worker output in .orchestrator/crew/<worker-id>/output.md
  Worktree in .orchestrator/worktrees/<worker-id>

Prerequisites:
  - tmux binary in PATH (will auto-start server if not running)
  - git binary in PATH, and inside a git repo for worktree isolation
  - Bash 4+ recommended, jq optional but recommended

Examples:
  ./scripts/spawn-worker.sh --task-type scout --task "Investigate auth flow" --adapter generic
  ./scripts/spawn-worker.sh --task-type ship --task "Fix bug in login" --adapter claude-code --id worker-login-fix
  ./scripts/spawn-worker.sh --task-type ship --task "Fix" --allow-dirty --force

USAGE
}

# ---- Logging helpers with clear prefixes ----
info()  { echo -e "${CYAN}[spawn:info]${NC} $*" >&2; }
warn()  { echo -e "${YELLOW}[spawn:warn]${NC} $*" >&2; }
error() { echo -e "${RED}[spawn:error]${NC} $*" >&2; }
die() {
  local msg="$1"
  local code="${2:-1}"
  error "$msg"
  # Log to orchestrator log if possible and manifest exists
  if [[ -n "${WORKER_ID:-}" ]]; then
    log_event "FAIL" "$WORKER_ID" "$msg" 2>/dev/null || true
  else
    log_event "FAIL" "-" "$msg" 2>/dev/null || true
  fi
  exit "$code"
}

# ---- Concurrency control ----

count_running_workers() {
  # Count workers in RUNNING or SPAWNING state
  local count=0
  local manifests
  manifests="$(list_manifests 2>/dev/null || true)"
  
  if [[ -z "$manifests" ]]; then
    echo "0"
    return
  fi
  
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

queue_task() {
  # Queue a task for later execution
  # queue_task <task_type> <task_desc> <adapter> <custom_id> <base_branch>
  local task_type="$1"
  local task_desc="$2"
  local adapter="$3"
  local custom_id="$4"
  local base_branch="$5"
  local timestamp
  timestamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  
  # Escape pipes in task description
  local escaped_desc
  escaped_desc="${task_desc//|/\\|}"
  
  mkdir -p "$(dirname "$QUEUE_FILE")"
  printf '%s|%s|%s|%s|%s|%s\n' "$timestamp" "$task_type" "$escaped_desc" "$adapter" "$custom_id" "$base_branch" >> "$QUEUE_FILE"
  
  info "Task queued (position $(wc -l < "$QUEUE_FILE" | tr -d ' ')):"
  info "  Type: $task_type"
  info "  Task: ${task_desc:0:80}..."
  info "  Queue file: $QUEUE_FILE"
  info "  Use watcher to auto-dequeue, or run: ./scripts/dequeue.sh"
}

process_queue() {
  # Process the next item in the queue if slots available
  if [[ ! -f "$QUEUE_FILE" || ! -s "$QUEUE_FILE" ]]; then
    return 0
  fi
  
  local running
  running="$(count_running_workers)"
  
  if [[ "$running" -ge "$MAX_CONCURRENT_WORKERS" ]]; then
    return 0
  fi
  
  # Read first line from queue
  local line
  line="$(head -n1 "$QUEUE_FILE")"
  
  if [[ -z "$line" ]]; then
    return 0
  fi
  
  # Remove first line from queue (atomic)
  local tmp_queue
  tmp_queue="$(mktemp)"
  tail -n +2 "$QUEUE_FILE" > "$tmp_queue" 2>/dev/null || true
  mv "$tmp_queue" "$QUEUE_FILE" 2>/dev/null || rm -f "$tmp_queue"
  
  # Parse the queued task
  # Format: timestamp|task_type|task_desc|adapter|custom_id|base_branch
  IFS='|' read -r timestamp task_type task_desc adapter custom_id base_branch <<< "$line"
  
  # Unescape pipes
  task_desc="${task_desc//\\|/|}"
  
  info "Dequeuing task: $task_type - ${task_desc:0:60}..."
  log_event "QUEUE" "dequeue" "Processing queued task: $task_type"
  
  # Reconstruct command and execute
  local cmd=("$0" "--task-type" "$task_type" "--task" "$task_desc" "--adapter" "$adapter")
  [[ -n "$custom_id" ]] && cmd+=("--id" "$custom_id")
  [[ -n "$base_branch" ]] && cmd+=("--base-branch" "$base_branch")
  
  # Execute in background to avoid blocking watcher
  "${cmd[@]}" &
}

# ---- Prerequisite checks ----

check_tmux_binary() {
  if ! command -v tmux >/dev/null 2>&1; then
    die "tmux NOT found in PATH. Required for crew panes.

Install:
  macOS: brew install tmux
  Ubuntu/Debian: apt install tmux
  Then re-run setup.sh" 2
  fi
  local ver
  ver="$(tmux -V 2>/dev/null || echo "tmux unknown")"
  info "$ver found at $(command -v tmux)"
}

ensure_tmux_server() {
  # tmux server check: tmux info fails when no server, tmux list-sessions fails with specific message
  local tmux_info_out
  tmux_info_out="$(tmux info 2>&1 || true)"
  local tmux_ls_out
  tmux_ls_out="$(tmux list-sessions 2>&1 || true)"

  # If info succeeds, server running
  if tmux info >/dev/null 2>&1; then
    info "tmux server is running"
    return 0
  fi

  # If ls says "no server running", we need to start one
  if echo "$tmux_ls_out" | grep -qi "no server running\|no server\|can't find server\|error connecting to"; then
    warn "tmux server not running, attempting to start..."
    # start-server is idempotent
    if ! tmux start-server 2>/dev/null; then
      warn "tmux start-server failed, trying to create bootstrap session"
    fi

    # Create a persistent orchestrator dummy session to keep server alive
    # Use orchestrator-main as management session
    if ! tmux has-session -t orchestrator-main 2>/dev/null; then
      tmux new-session -d -s orchestrator-main -c "$ROOT_DIR" "echo '[orchestrator] tmux server bootstrapped at $(date)'; sleep 3600" 2>/dev/null || {
        error "Failed to create bootstrap tmux session orchestrator-main"
        # Try one more direct start
        tmux new-session -d -s orchestrator-main 2>/dev/null || true
      }
    fi

    # Final verification
    if tmux info >/dev/null 2>&1 || tmux list-sessions >/dev/null 2>&1; then
      info "tmux server successfully started (session orchestrator-main)"
      return 0
    else
      die "Failed to start tmux server after attempt. Check tmux installation: tmux -V, permissions on /tmp, and that tmux is runnable.
Try manually: tmux start-server; tmux ls" 2
    fi
  fi

  # Server might be in weird state but ls succeeded (no sessions) - that's OK, server is running
  if echo "$tmux_ls_out" | grep -qi "no sessions\|no clients\|empty"; then
    info "tmux server running (no active sessions - OK)"
    return 0
  fi

  # Fallback: if we can't determine, try start-server and assume ok
  tmux start-server >/dev/null 2>&1 || true
  info "tmux server check passed (assumed running)"
}

check_git_binary() {
  if ! command -v git >/dev/null 2>&1; then
    die "git NOT found in PATH. Required for worktree isolation.

Install: brew install git / apt install git" 2
  fi
  local gv
  gv="$(git --version 2>/dev/null || echo "git unknown")"
  info "$gv found at $(command -v git)"

  # Check worktree support
  if ! git worktree --help >/dev/null 2>&1; then
    die "git worktree not supported. Need git >= 2.5 (you have: $gv)" 2
  fi
}

check_in_git_repo() {
  if git -C "$ROOT_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    IN_GIT=true
    local top
    top="$(git -C "$ROOT_DIR" rev-parse --show-toplevel 2>/dev/null || echo "$ROOT_DIR")"
    info "Inside git repo: $top"
    # Check if HEAD exists (repo has at least one commit)
    if ! git -C "$ROOT_DIR" rev-parse HEAD >/dev/null 2>&1; then
      warn "Git repo has no commits yet (no HEAD). Worktree creation from HEAD will fail."
      warn "Create initial commit: git add . && git commit -m 'init'"
      if [[ "$ALLOW_DIRTY" != "true" ]]; then
        die "No HEAD commit found. Run: git add . && git commit -m 'initial commit', or use --allow-dirty to bypass but worktree will still fail until HEAD exists." 3
      fi
    fi
  else
    IN_GIT=false
    warn "Not inside a git repository (checked $ROOT_DIR)."
    warn "The orchestrator uses git worktrees for isolation."
    warn "  - For demo/placeholder mode: continues with plain directory (no isolation)"
    warn "  - For production: run 'git init && git add . && git commit -m init' or clone inside existing repo"
  fi
}

check_git_clean() {
  if [[ "$IN_GIT" == false ]]; then
    return 0
  fi
  if [[ "$ALLOW_DIRTY" == "true" ]]; then
    warn "Skipping git clean check (--allow-dirty)"
    return 0
  fi

  local porcelain
  porcelain="$(git -C "$ROOT_DIR" status --porcelain 2>/dev/null || echo "")"

  if [[ -n "$porcelain" ]]; then
    error "Git repo is not clean. Uncommitted changes detected:"
    echo "$porcelain" | sed 's/^/  /' >&2
    echo "" >&2
    error "Why this check? Creating a worktree from a dirty HEAD can cause confusion:"
    error "  - Worker branches from HEAD, not your dirty working tree"
    error "  - Your uncommitted changes stay in main and won't be visible to workers"
    echo "" >&2
    echo "Fix options:" >&2
    echo "  1. Commit: git add -A && git commit -m 'wip before crew'" >&2
    echo "  2. Stash: git stash push -m 'temp before crew'" >&2
    echo "  3. Bypass (not recommended): ./scripts/spawn-worker.sh ... --allow-dirty" >&2
    return 1
  fi

  info "Git repo is clean (no uncommitted changes)"
  return 0
}

check_adapter() {
  ADAPTER_SCRIPT="$ROOT_DIR/adapters/${ADAPTER}.sh"
  if [[ ! -f "$ADAPTER_SCRIPT" ]]; then
    error "Adapter script not found: $ADAPTER_SCRIPT"
    echo "" >&2
    echo "Available adapters:" >&2
    ls -1 "$ROOT_DIR/adapters/"*.sh 2>/dev/null | sed 's/.*\//  - /' | sed 's/\.sh$//' >&2 || echo "  (none found in adapters/)" >&2
    die "Invalid --adapter '$ADAPTER'. Use generic or claude-code, or create adapters/${ADAPTER}.sh" 4
  fi
  if [[ ! -x "$ADAPTER_SCRIPT" && ! -r "$ADAPTER_SCRIPT" ]]; then
    warn "Adapter $ADAPTER_SCRIPT not executable, chmod +x"
    chmod +x "$ADAPTER_SCRIPT" 2>/dev/null || true
  fi
  info "Adapter '$ADAPTER' found: $ADAPTER_SCRIPT"
}

check_worker_id_collisions() {
  # Returns 0 if OK, 1 if collision and not --force
  local collision=false
  if [[ -e "$W_DIR" ]]; then
    error "Worker directory already exists: $W_DIR"
    collision=true
  fi
  if [[ -e "$WT_PATH" ]]; then
    error "Worktree path already exists: $WT_PATH"
    collision=true
  fi
  if [[ "$IN_GIT" == true ]]; then
    if git -C "$ROOT_DIR" show-ref --verify --quiet "refs/heads/$BRANCH_NAME" 2>/dev/null; then
      error "Branch already exists: $BRANCH_NAME"
      collision=true
    fi
    if git -C "$ROOT_DIR" worktree list --porcelain 2>/dev/null | grep -q "worktree $WT_PATH"; then
      error "Worktree already registered in git: $WT_PATH (git worktree list)"
      collision=true
    fi
  fi
  if is_tmux_alive "$SESSION_NAME" 2>/dev/null; then
    error "Tmux session already exists: $SESSION_NAME"
    collision=true
  fi

  if [[ "$collision" == true ]]; then
    if [[ "$FORCE" == "true" ]]; then
      warn "--force given, cleaning up existing worker $WORKER_ID before respawn..."
      # Cleanup
      tmux kill-session -t "$SESSION_NAME" 2>/dev/null || true
      if [[ "$IN_GIT" == true ]]; then
        git -C "$ROOT_DIR" worktree remove --force "$WT_PATH" 2>/dev/null || true
        rm -rf "$WT_PATH" 2>/dev/null || true
        git -C "$ROOT_DIR" branch -D "$BRANCH_NAME" 2>/dev/null || true
      else
        rm -rf "$WT_PATH" 2>/dev/null || true
      fi
      rm -rf "$W_DIR" 2>/dev/null || true
      info "Existing worker cleaned (--force)"
      return 0
    else
      error "Use --force to overwrite, or pick different --id, or cleanup:"
      echo "  ./scripts/kill-worker.sh $WORKER_ID --remove-worktree" >&2
      echo "  rm -rf $W_DIR $WT_PATH" >&2
      [[ "$IN_GIT" == true ]] && echo "  git branch -D $BRANCH_NAME; git worktree remove --force $WT_PATH" >&2
      echo "  tmux kill-session -t $SESSION_NAME" >&2
      return 1
    fi
  fi
  return 0
}

# ---- Parse args ----
while [[ $# -gt 0 ]]; do
  case "$1" in
    --task-type)
      TASK_TYPE="$2"; shift 2;;
    --task)
      TASK_DESC="$2"; shift 2;;
    --adapter)
      ADAPTER="$2"; shift 2;;
    --id)
      CUSTOM_ID="$2"; shift 2;;
    --base-branch)
      BASE_BRANCH="$2"; shift 2;;
    --allow-dirty)
      ALLOW_DIRTY="true"; shift;;
    --force)
      FORCE="true"; shift;;
    --dry-run)
      DRY_RUN="true"; shift;;
    --queue)
      QUEUE="true"; shift;;
    --no-stagger)
      STAGGER_DELAY=0; shift;;
    -h|--help)
      usage; exit 0;;
    *)
      error "Unknown argument: $1"
      usage >&2
      exit 1;;
  esac
done

# Check env var to disable stagger
if [[ -n "${ORCHESTRATOR_NO_STAGGER:-}" ]]; then
  STAGGER_DELAY=0
fi

# ---- Validate required args ----
if [[ -z "$TASK_TYPE" ]]; then
  error "--task-type is required (ship or scout)"
  usage >&2
  exit 1
fi
if [[ "$TASK_TYPE" != "ship" && "$TASK_TYPE" != "scout" ]]; then
  die "Invalid --task-type '$TASK_TYPE': must be 'ship' or 'scout'" 1
fi
if [[ -z "$TASK_DESC" ]]; then
  error "--task is required (non-empty description)"
  usage >&2
  exit 1
fi
# Trim whitespace and check length
TASK_DESC_TRIMMED="$(echo "$TASK_DESC" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
if [[ ${#TASK_DESC_TRIMMED} -lt 5 ]]; then
  die "Task description too short (${#TASK_DESC_TRIMMED} chars). Provide at least 5 chars, e.g. 'Fix bug in login'." 1
fi
if [[ "$ADAPTER" != "generic" && "$ADAPTER" != "claude-code" ]]; then
  error "Invalid --adapter '$ADAPTER': must be generic or claude-code"
  echo "Available:" >&2
  ls -1 "$ROOT_DIR"/adapters/*.sh 2>/dev/null | xargs -n1 basename 2>/dev/null | sed 's/\.sh$//' | sed 's/^/  - /' >&2
  exit 1
fi

# ---- Prerequisite checks (clear error messages) ----
info "Validating prerequisites..."
check_tmux_binary
ensure_tmux_server
check_git_binary
check_in_git_repo
if ! check_git_clean; then
  die "Git clean check failed. Use --allow-dirty to bypass if intentional." 3
fi
check_adapter

# Ensure orch dirs with error handling
info "Ensuring orchestrator state dirs at $ORCH_DIR"
if ! mkdir -p "$CREW_DIR" "$LOGS_DIR" "$WORKTREES_DIR" 2>/dev/null; then
  die "Failed to create state dirs: $CREW_DIR $LOGS_DIR $WORKTREES_DIR. Check permissions and disk space." 5
fi
# Touch log file
touch "$ORCH_LOG" 2>/dev/null || warn "Cannot touch log $ORCH_LOG (permissions?)"

# Ensure queue file exists
touch "$QUEUE_FILE" 2>/dev/null || true

# ---- Concurrency check ----
info "Checking concurrent worker limit (max: $MAX_CONCURRENT_WORKERS)..."
RUNNING_COUNT="$(count_running_workers)"
info "Currently running: $RUNNING_COUNT workers"

if [[ "$RUNNING_COUNT" -ge "$MAX_CONCURRENT_WORKERS" ]]; then
  if [[ "$QUEUE" == "true" ]]; then
    info "At limit ($RUNNING_COUNT/$MAX_CONCURRENT_WORKERS), queuing task..."
    queue_task "$TASK_TYPE" "$TASK_DESC" "$ADAPTER" "$CUSTOM_ID" "$BASE_BRANCH"
    log_event "QUEUE" "spawn" "Task queued due to limit: $TASK_TYPE - ${TASK_DESC:0:60}"
    exit 0
  else
    error "Max concurrent workers reached ($RUNNING_COUNT/$MAX_CONCURRENT_WORKERS)"
    error ""
    error "Options:"
    error "  1. Wait for a worker to finish, then retry"
    error "  2. Use --queue flag to queue this task"
    error "  3. Increase limit: MAX_CONCURRENT_WORKERS=10 $0 ..."
    error "  4. Kill a worker: ./scripts/kill-worker.sh <id>"
    error ""
    error "Current running workers:"
    while IFS= read -r m; do
      [[ -z "$m" ]] && continue
      running_id="$(get_json_field "$m" "id" 2>/dev/null || echo "unknown")"
      running_status="$(get_json_field "$m" "status" 2>/dev/null || echo "unknown")"
      if [[ "$running_status" == "RUNNING" || "$running_status" == "SPAWNING" ]]; then
        error "  - $running_id ($running_status)"
      fi
    done <<< "$(list_manifests)"
    die "Refusing to spawn - at concurrency limit" 9
  fi
fi

# ---- Stagger delay for batch operations ----
# Simple stagger to avoid resource contention in batch spawns
if [[ "$STAGGER_DELAY" -gt 0 ]]; then
  info "Staggering spawn by ${STAGGER_DELAY}s..."
  sleep "$STAGGER_DELAY"
fi

# ---- Generate and sanitize worker ID ----
if [[ -n "$CUSTOM_ID" ]]; then
  WORKER_ID="$CUSTOM_ID"
else
  WORKER_ID="$(generate_worker_id)"
fi

# Sanitize: allow only alphanumeric, dot, underscore, hyphen; replace spaces with hyphen; strip other chars
ORIG_ID="$WORKER_ID"
WORKER_ID="$(echo "$WORKER_ID" | tr -s ' ' '-' | tr -cd 'a-zA-Z0-9._-')"
if [[ -z "$WORKER_ID" ]]; then
  warn "Sanitized worker ID empty (original: $ORIG_ID), generating random"
  WORKER_ID="$(generate_worker_id)"
fi
# Limit length
if [[ ${#WORKER_ID} -gt 64 ]]; then
  warn "Worker ID too long (${#WORKER_ID}), truncating to 64"
  WORKER_ID="${WORKER_ID:0:64}"
fi
if [[ "$WORKER_ID" != "$ORIG_ID" ]]; then
  info "Sanitized worker ID: '$ORIG_ID' -> '$WORKER_ID'"
fi

W_DIR="$(worker_dir "$WORKER_ID")"
M_PATH="$(manifest_path "$WORKER_ID")"
WT_PATH="$(worktree_path "$WORKER_ID")"
SESSION_NAME="$(tmux_session_name "$WORKER_ID")"
BRANCH_NAME="crew/$WORKER_ID"

# ---- Collision check ----
if ! check_worker_id_collisions; then
  die "Worker ID collision for '$WORKER_ID' (use --force to overwrite or choose different --id)" 6
fi

# ---- Determine base ref for branch ----
if [[ -n "$BASE_BRANCH" ]]; then
  BASE_REF="$BASE_BRANCH"
  # Validate base branch exists if in git
  if [[ "$IN_GIT" == true ]]; then
    if ! git -C "$ROOT_DIR" show-ref --verify --quiet "refs/heads/$BASE_REF" 2>/dev/null && \
       ! git -C "$ROOT_DIR" show-ref --verify --quiet "refs/remotes/origin/$BASE_REF" 2>/dev/null && \
       ! git -C "$ROOT_DIR" rev-parse --verify "$BASE_REF" >/dev/null 2>&1; then
      die "Base branch '$BASE_REF' does not exist. Available branches: $(git -C "$ROOT_DIR" branch --format='%(refname:short)' 2>/dev/null | head -n 10 | tr '\n' ' ')" 3
    fi
  fi
else
  if [[ "$IN_GIT" == true ]]; then
    if git -C "$ROOT_DIR" rev-parse HEAD >/dev/null 2>&1; then
      BASE_REF="HEAD"
    else
      BASE_REF="$(git -C "$ROOT_DIR" symbolic-ref --short HEAD 2>/dev/null || echo "main")"
    fi
  else
    BASE_REF="main"
  fi
fi
info "Base ref for worktree: $BASE_REF, branch: $BRANCH_NAME"

# ---- Prepare timestamps and escaped JSON values ----
NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
ESC_TASK="$(json_escape "$TASK_DESC")"
ESC_ID="$(json_escape "$WORKER_ID")"
ESC_TYPE="$(json_escape "$TASK_TYPE")"
ESC_ADAPTER="$(json_escape "$ADAPTER")"
ESC_BRANCH="$(json_escape "$BRANCH_NAME")"
ESC_WT="$(json_escape "$WT_PATH")"
ESC_SESSION="$(json_escape "$SESSION_NAME")"
ESC_BASE="$(json_escape "$BASE_REF")"

# ---- Create crew directory and initial manifest (PENDING) ----
info "Creating worker directory: $W_DIR"
if ! mkdir -p "$W_DIR" 2>/dev/null; then
  die "Failed to create worker directory $W_DIR. Check permissions (mkdir -p) and disk space." 5
fi

info "Writing initial manifest $M_PATH (PENDING)"
# Use temporary file then mv for atomicity
MANIFEST_TMP="$(mktemp)"
cat > "$MANIFEST_TMP" <<EOF
{
  "id": "$ESC_ID",
  "task_type": "$ESC_TYPE",
  "task": "$ESC_TASK",
  "status": "PENDING",
  "created_at": "$NOW",
  "updated_at": "$NOW",
  "worktree_path": "$ESC_WT",
  "branch": "$ESC_BRANCH",
  "tmux_session": "$ESC_SESSION",
  "tmux_pane": null,
  "adapter": "$ESC_ADAPTER",
  "pid": null,
  "exit_code": null,
  "output_path": ".orchestrator/crew/$ESC_ID/output.md",
  "base_ref": "$ESC_BASE"
}
EOF

# Validate JSON if jq available
if has_jq; then
  if ! jq empty "$MANIFEST_TMP" 2>/dev/null; then
    rm -f "$MANIFEST_TMP"
    die "Failed to create valid manifest JSON (jq validation failed). Task description may have unescapable characters." 5
  fi
fi

if ! mv "$MANIFEST_TMP" "$M_PATH" 2>/dev/null; then
  rm -f "$MANIFEST_TMP"
  die "Failed to write manifest to $M_PATH (mv failed). Check permissions." 5
fi

# Ensure manifest file is readable
if [[ ! -f "$M_PATH" ]]; then
  die "Manifest file not found after write: $M_PATH" 5
fi

log_event "SPAWN" "$WORKER_ID" "Created manifest PENDING type=$TASK_TYPE adapter=$ADAPTER task=$TASK_DESC"
pass_manifest="true"

# Setup trap to mark FAILED if later steps fail after manifest exists
trap 'ec=$?; if [[ $ec -ne 0 ]]; then warn "Spawn failed with exit $ec, marking manifest FAILED"; update_manifest_status "$M_PATH" "FAILED" "$ec" 2>/dev/null || true; log_event "FAIL" "$WORKER_ID" "spawn trap failed ec=$ec" 2>/dev/null || true; fi' EXIT

# ---- Dry run ----
if [[ "$DRY_RUN" == "true" ]]; then
  echo "DRY RUN - would spawn:"
  cat "$M_PATH"
  echo ""
  echo "Worktree path: $WT_PATH"
  echo "Session: $SESSION_NAME"
  echo "Branch: $BRANCH_NAME"
  echo "Base ref: $BASE_REF"
  echo "Adapter: $ADAPTER"
  # Cleanup dry-run artifacts
  rm -rf "$W_DIR"
  trap - EXIT
  exit 0
fi

# ---- Transition to SPAWNING ----
info "Transitioning manifest to SPAWNING"
update_manifest_status "$M_PATH" "SPAWNING" || warn "Failed to update manifest status to SPAWNING (non-fatal)"

# ---- Create worktree (or placeholder) ----
if [[ "$IN_GIT" == true ]]; then
  info "Creating worktree $WT_PATH from $BASE_REF branch $BRANCH_NAME"
  log_event "SPAWN" "$WORKER_ID" "Creating worktree $WT_PATH from $BASE_REF branch $BRANCH_NAME"

  mkdir -p "$WORKTREES_DIR" 2>/dev/null || die "Failed to create worktrees dir $WORKTREES_DIR" 5

  set +e
  local_wt_err=""
  if [[ "$BASE_REF" == "HEAD" ]]; then
    git -C "$ROOT_DIR" worktree add -b "$BRANCH_NAME" "$WT_PATH" HEAD >"/tmp/git-worktree-$WORKER_ID.log" 2>&1
    WT_EXIT=$?
    local_wt_err="$(cat "/tmp/git-worktree-$WORKER_ID.log" 2>/dev/null)"
  else
    if git -C "$ROOT_DIR" show-ref --verify --quiet "refs/heads/$BASE_REF" 2>/dev/null || git -C "$ROOT_DIR" show-ref --verify --quiet "refs/remotes/origin/$BASE_REF" 2>/dev/null || git -C "$ROOT_DIR" rev-parse --verify "$BASE_REF" >/dev/null 2>&1; then
      git -C "$ROOT_DIR" worktree add -b "$BRANCH_NAME" "$WT_PATH" "$BASE_REF" >"/tmp/git-worktree-$WORKER_ID.log" 2>&1
      WT_EXIT=$?
      local_wt_err="$(cat "/tmp/git-worktree-$WORKER_ID.log" 2>/dev/null)"
    else
      git -C "$ROOT_DIR" worktree add -b "$BRANCH_NAME" "$WT_PATH" HEAD >"/tmp/git-worktree-$WORKER_ID.log" 2>&1
      WT_EXIT=$?
      local_wt_err="$(cat "/tmp/git-worktree-$WORKER_ID.log" 2>/dev/null)"
    fi
  fi
  set -e

  if [[ ${WT_EXIT:-1} -ne 0 ]]; then
    error "Failed to create worktree. Exit: $WT_EXIT"
    echo "--- git worktree output ---" >&2
    echo "$local_wt_err" | sed 's/^/  /' >&2
    echo "---------------------------" >&2
    error "Common causes:"
    error "  - Branch $BRANCH_NAME already exists (use --force or git branch -D $BRANCH_NAME)"
    error "  - Worktree path $WT_PATH already exists and is registered"
    error "  - Base ref $BASE_REF invalid (does $BASE_REF exist?)"
    error "  - Git repo in conflicted state"
    # Cleanup
    git -C "$ROOT_DIR" worktree remove --force "$WT_PATH" 2>/dev/null || true
    rm -rf "$WT_PATH" 2>/dev/null || true
    git -C "$ROOT_DIR" branch -D "$BRANCH_NAME" 2>/dev/null || true
    update_manifest_status "$M_PATH" "FAILED" 1
    log_event "FAIL" "$WORKER_ID" "worktree creation failed: $local_wt_err"
    die "Worktree creation failed, see above. Manifest marked FAILED." 7
  fi
  rm -f "/tmp/git-worktree-$WORKER_ID.log"
  log_event "SPAWN" "$WORKER_ID" "Worktree created at $WT_PATH branch $BRANCH_NAME"
  info "Worktree created at $WT_PATH"
else
  info "Not in git repo - creating placeholder directory $WT_PATH (no isolation)"
  if ! mkdir -p "$WT_PATH" 2>/dev/null; then
    update_manifest_status "$M_PATH" "FAILED" 1
    die "Failed to create placeholder worktree dir $WT_PATH" 5
  fi
  echo "# Worktree placeholder for $WORKER_ID (no git)" > "$WT_PATH/README.md" 2>/dev/null || warn "Could not write README in placeholder worktree"
  log_event "SPAWN" "$WORKER_ID" "Created placeholder dir (no git repo)"
fi

# ---- Prepare worker output file ----
OUTPUT_MD="$W_DIR/output.md"
info "Creating output file $OUTPUT_MD"

# Write brief file first (contains raw task description, avoids shell injection)
BRIEF_PATH="$W_DIR/brief.md"
printf '%s' "$TASK_DESC" > "$BRIEF_PATH"
if [[ ! -f "$BRIEF_PATH" ]]; then
  update_manifest_status "$M_PATH" "FAILED" 1
  die "Failed to create brief file $BRIEF_PATH" 5
fi

# Create output.md safely without unquoted heredoc expansion
{
  printf '# Worker Output: %s\n\n' "$WORKER_ID"
  printf '%s\n' "- **Task Type:** $TASK_TYPE"
  printf '%s\n' "- **Task:**"
  cat "$BRIEF_PATH"
  printf '\n'
  printf '%s\n' "- **Adapter:** $ADAPTER"
  printf '%s\n' "- **Created:** $NOW"
  printf '%s\n' "- **Worktree:** $WT_PATH"
  printf '%s\n' "- **Branch:** $BRANCH_NAME"
  printf '%s\n' "- **Session:** $SESSION_NAME"
  printf '\n'
  printf '## Status: RUNNING\n\n'
  printf 'Worker is starting...\n\n'
  printf '## Task Details\n\n'
  printf '> '
  # Escape newlines for blockquote
  sed 's/^/> /' "$BRIEF_PATH"
  printf '\n'
  printf '## Instructions for Worker Agent\n\n'
  printf 'You are worker **%s**.\n\n' "$WORKER_ID"
  printf '%s\n' "- Your worktree is at \`$WT_PATH\`"
  printf '%s\n' "- Task type: **$TASK_TYPE**"
  printf '%s\n' "- Signal completion by appending status markers to this file (see PROMPT.md for exact syntax):"
  printf '%s\n' "  - DONE: append marker for DONE plus section ## Result: <summary>"
  printf '%s\n' "  - BLOCKED: append marker for BLOCKED plus ## Blocked: <reason>"
  printf '%s\n' "  - FAILED: append marker for FAILED plus ## Failed: <reason>"
  printf '%s\n' "  Exact marker syntax is defined in PROMPT.md / CLAUDE_TASK.md in your worktree."
  printf '%s\n' "  Do NOT copy from this output header - read worktree prompt file for precise marker to append."
  printf '\n'
  printf '%s\n' "- For ship tasks, create commits in your worktree."
  printf '%s\n' "- For scout tasks, write findings in this output.md and in worktree if needed."
  printf '\n'
  printf '%s\n' "The orchestrator watches this file via filesystem polling."
  printf '\n'
  printf '## Work Log\n\n'
} > "$OUTPUT_MD"

if [[ ! -f "$OUTPUT_MD" ]]; then
  update_manifest_status "$M_PATH" "FAILED" 1
  die "Failed to create output file $OUTPUT_MD" 5
fi

# ---- Create task file for adapter ----
info "Creating task metadata $W_DIR/task.txt"
{
  printf 'TASK_ID=%s\n' "$WORKER_ID"
  printf 'TASK_TYPE=%s\n' "$TASK_TYPE"
  printf 'TASK_BRIEF_PATH=%s\n' "$BRIEF_PATH"
  printf 'WORKTREE=%s\n' "$WT_PATH"
  printf 'OUTPUT=%s\n' "$OUTPUT_MD"
  printf 'BRANCH=%s\n' "$BRANCH_NAME"
  printf 'ADAPTER=%s\n' "$ADAPTER"
  printf 'BASE_REF=%s\n' "$BASE_REF"
  printf 'CREATED_AT=%s\n' "$NOW"
} > "$W_DIR/task.txt"

# ---- Validate adapter again (redundant safety) ----
if [[ ! -f "$ADAPTER_SCRIPT" ]]; then
  update_manifest_status "$M_PATH" "FAILED" 1
  die "Adapter disappeared after earlier check: $ADAPTER_SCRIPT" 4
fi

# ---- Spawn tmux session ----
info "Creating tmux session: $SESSION_NAME"
log_event "SPAWN" "$WORKER_ID" "Creating tmux session $SESSION_NAME"

# Final tmux binary check (defensive)
if ! command -v tmux >/dev/null 2>&1; then
  update_manifest_status "$M_PATH" "FAILED" 1
  die "tmux binary disappeared after earlier check" 2
fi

# Kill existing session with same name if exists (should have been handled by collision check, but defensive)
if is_tmux_alive "$SESSION_NAME" 2>/dev/null; then
  if [[ "$FORCE" == "true" ]]; then
    warn "Killing existing tmux session $SESSION_NAME (--force)"
    tmux kill-session -t "$SESSION_NAME" 2>/dev/null || warn "Failed to kill existing session $SESSION_NAME"
  else
    update_manifest_status "$M_PATH" "FAILED" 1
    die "Tmux session $SESSION_NAME already exists. Use --force or kill: tmux kill-session -t $SESSION_NAME" 6
  fi
fi

# Create launch script
LAUNCH_SH="$W_DIR/launch.sh"
info "Creating launch script $LAUNCH_SH"

# Use shell_quote to safely embed paths, and read TASK_DESC from brief file at runtime
# Use quoted heredoc to prevent any expansion at generation time
{
  printf '#!/usr/bin/env bash\n'
  printf 'set -e\n'
  printf '# Auto-generated launch script for worker %s\n' "$WORKER_ID"
  printf 'WORKER_ID=%s\n' "$(shell_quote "$WORKER_ID")"
  printf 'WT_PATH=%s\n' "$(shell_quote "$WT_PATH")"
  printf 'TASK_TYPE=%s\n' "$(shell_quote "$TASK_TYPE")"
  printf 'OUTPUT_MD=%s\n' "$(shell_quote "$OUTPUT_MD")"
  printf 'M_PATH=%s\n' "$(shell_quote "$M_PATH")"
  printf 'ADAPTER_SCRIPT=%s\n' "$(shell_quote "$ADAPTER_SCRIPT")"
  printf 'ADAPTER=%s\n' "$(shell_quote "$ADAPTER")"
  printf 'BRIEF_PATH=%s\n' "$(shell_quote "$BRIEF_PATH")"
  printf '\n'
  cat <<'LAUNCH_BODY'
cd "$WT_PATH"
echo "[worker $WORKER_ID] Starting adapter $ADAPTER" | tee -a "$OUTPUT_MD"
echo "[worker $WORKER_ID] Worktree: $WT_PATH" | tee -a "$OUTPUT_MD"
# Read task description from brief file at runtime to avoid injection
TASK_DESC=$(cat "$BRIEF_PATH")
echo "[worker $WORKER_ID] Task: $TASK_TYPE - $TASK_DESC"
echo ""

# Run adapter - pass brief path instead of raw task description
bash "$ADAPTER_SCRIPT" "$WORKER_ID" "$WT_PATH" "$TASK_TYPE" "$BRIEF_PATH" "$OUTPUT_MD" "$M_PATH"
EXIT_CODE=$?
echo ""
echo "[worker $WORKER_ID] Adapter exited with code $EXIT_CODE"

if ! grep -q "STATUS: DONE\|STATUS: BLOCKED\|STATUS: FAILED\|STATUS: NEEDS_REVIEW" "$OUTPUT_MD" 2>/dev/null; then
  if [ $EXIT_CODE -eq 0 ]; then
    echo "" >> "$OUTPUT_MD"
    echo "<!-- STATUS: NEEDS_REVIEW -->" >> "$OUTPUT_MD"
    echo "## Completed with exit code 0 but no explicit STATUS marker" >> "$OUTPUT_MD"
    echo "Worker exited cleanly but did not signal DONE, BLOCKED, or FAILED." >> "$OUTPUT_MD"
    echo "Marking as NEEDS_REVIEW for manual inspection." >> "$OUTPUT_MD"
  else
    echo "" >> "$OUTPUT_MD"
    echo "<!-- STATUS: FAILED -->" >> "$OUTPUT_MD"
    echo "## Failed with exit code $EXIT_CODE" >> "$OUTPUT_MD"
  fi
fi

if command -v jq >/dev/null 2>&1; then
  TMP=$(mktemp)
  if grep -q "<!--[[:space:]]*STATUS:[[:space:]]*DONE" "$OUTPUT_MD" 2>/dev/null; then
    jq --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '.status="DONE" | .updated_at=$ts | .exit_code=0' "$M_PATH" > "$TMP" 2>/dev/null && mv "$TMP" "$M_PATH" || rm -f "$TMP"
  elif grep -q "<!--[[:space:]]*STATUS:[[:space:]]*BLOCKED" "$OUTPUT_MD" 2>/dev/null; then
    jq --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '.status="BLOCKED" | .updated_at=$ts' "$M_PATH" > "$TMP" 2>/dev/null && mv "$TMP" "$M_PATH" || rm -f "$TMP"
  elif grep -q "<!--[[:space:]]*STATUS:[[:space:]]*FAILED" "$OUTPUT_MD" 2>/dev/null; then
    jq --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --argjson ec ${EXIT_CODE:-1} '.status="FAILED" | .updated_at=$ts | .exit_code=$ec' "$M_PATH" > "$TMP" 2>/dev/null && mv "$TMP" "$M_PATH" || rm -f "$TMP"
  elif grep -q "<!--[[:space:]]*STATUS:[[:space:]]*NEEDS_REVIEW" "$OUTPUT_MD" 2>/dev/null; then
    jq --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '.status="NEEDS_REVIEW" | .updated_at=$ts | .exit_code=0' "$M_PATH" > "$TMP" 2>/dev/null && mv "$TMP" "$M_PATH" || rm -f "$TMP"
  else
    # Fallback: if no marker, use exit code
    if [ $EXIT_CODE -eq 0 ]; then
      jq --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '.status="NEEDS_REVIEW" | .updated_at=$ts | .exit_code=0' "$M_PATH" > "$TMP" 2>/dev/null && mv "$TMP" "$M_PATH" || rm -f "$TMP"
    else
      jq --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --argjson ec $EXIT_CODE '.status="FAILED" | .updated_at=$ts | .exit_code=$ec' "$M_PATH" > "$TMP" 2>/dev/null && mv "$TMP" "$M_PATH" || rm -f "$TMP"
    fi
  fi
fi

exit $EXIT_CODE
LAUNCH_BODY
} > "$LAUNCH_SH"

chmod +x "$LAUNCH_SH" 2>/dev/null || warn "Failed to chmod +x $LAUNCH_SH"

# Start detached tmux session
info "Starting detached tmux session $SESSION_NAME running $LAUNCH_SH"
if ! tmux new-session -d -s "$SESSION_NAME" -c "$WT_PATH" "bash '$LAUNCH_SH'; echo '[tmux] pane finished, press enter to keep'; read || sleep 5" 2>/dev/null; then
  error "Failed to create tmux session $SESSION_NAME"
  error "Possible causes: tmux server died, invalid worktree path, session name conflict"
  update_manifest_status "$M_PATH" "FAILED" 1
  log_event "FAIL" "$WORKER_ID" "tmux session creation failed"
  die "tmux new-session failed for $SESSION_NAME" 8
fi

sleep 0.5

# Get pane pid and id
PANE_PID=""
PANE_ID=""
if is_tmux_alive "$SESSION_NAME"; then
  PANE_PID="$(tmux list-panes -t "$SESSION_NAME" -F "#{pane_pid}" 2>/dev/null | head -n1 || echo "")"
  PANE_ID="$(tmux list-panes -t "$SESSION_NAME" -F "#{pane_id}" 2>/dev/null | head -n1 || echo "")"
else
  warn "Tmux session $SESSION_NAME not alive immediately after creation"
fi

# Update manifest to RUNNING
NOW2="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
if has_jq; then
  TMP="$(mktemp)"
  jq --arg ts "$NOW2" --arg pid "${PANE_PID:-null}" --arg pane "${PANE_ID:-null}" \
    --argjson pid_num "${PANE_PID:-null}" '
    .status="RUNNING" |
    .updated_at=$ts |
    .pid= (if $pid=="null" then null else $pid_num end) |
    .tmux_pane= (if $pane=="null" then null else $pane end)
  ' "$M_PATH" > "$TMP" 2>/dev/null && mv "$TMP" "$M_PATH" || rm -f "$TMP"
else
  update_manifest_status "$M_PATH" "RUNNING"
  if [[ -n "$PANE_PID" ]]; then
    TMP="$(mktemp)"
    sed -E "s/(\"pid\"[[:space:]]*:[[:space:]]*)[^,}]+/\1${PANE_PID}/" "$M_PATH" > "$TMP" 2>/dev/null && mv "$TMP" "$M_PATH" || rm -f "$TMP"
  fi
fi

log_event "RUNNING" "$WORKER_ID" "Spawned in tmux $SESSION_NAME pane $PANE_ID pid $PANE_PID"

# Clear trap after success
trap - EXIT

echo ""
echo "=== Worker Spawned ==="
echo "ID: $WORKER_ID"
echo "Type: $TASK_TYPE"
echo "Adapter: $ADAPTER"
echo "Worktree: $WT_PATH"
echo "Branch: $BRANCH_NAME"
echo "Tmux: $SESSION_NAME"
echo "Manifest: $M_PATH"
echo "Output: $OUTPUT_MD"
echo ""
echo "Attach: tmux attach -t $SESSION_NAME"
echo "Logs: tail -f $ORCH_LOG"
echo ""
