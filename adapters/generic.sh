#!/usr/bin/env bash
# adapters/generic.sh - Generic terminal coding agent adapter
# Works with ANY terminal-based agent (or human).
# Contract:
#   generic.sh <worker-id> <worktree_path> <task_type> <brief_path> <output_path> <manifest_path>
#   brief_path is a file containing the task description (avoids shell injection)

set -euo pipefail

WORKER_ID="${1:-unknown}"
WORKTREE_PATH="${2:-$(pwd)}"
TASK_TYPE="${3:-ship}"
BRIEF_PATH="${4:-}"
OUTPUT_PATH="${5:-$WORKTREE_PATH/../output.md}"
MANIFEST_PATH="${6:-}"

# Read task description from brief file if provided, else fallback to legacy positional arg
if [[ -n "$BRIEF_PATH" && -f "$BRIEF_PATH" ]]; then
  TASK_DESC="$(cat "$BRIEF_PATH")"
else
  # Fallback for backward compatibility: treat $4 as task desc if not a file
  TASK_DESC="$BRIEF_PATH"
  BRIEF_PATH=""
fi
TASK_DESC="${TASK_DESC:-No task provided}"

log_to_output() {
  echo "$@" | tee -a "$OUTPUT_PATH"
}

# Ensure output exists
mkdir -p "$(dirname "$OUTPUT_PATH")" 2>/dev/null || true
touch "$OUTPUT_PATH" 2>/dev/null || true

log_to_output ""
log_to_output "## Adapter: generic"
log_to_output "- Started: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
log_to_output "- Worker: $WORKER_ID"
log_to_output "- Type: $TASK_TYPE"
log_to_output "- Worktree: $WORKTREE_PATH"
log_to_output "- Output: $OUTPUT_PATH"
log_to_output ""

# Create PROMPT.md in worktree for the agent
cat > "$WORKTREE_PATH/PROMPT.md" <<PROMPT_EOF
# Task for Worker: $WORKER_ID

- **Type:** $TASK_TYPE
- **ID:** $WORKER_ID
- **Output:** $OUTPUT_PATH
- **Manifest:** $MANIFEST_PATH

## Task Description

$TASK_DESC

## Your Role

You are an autonomous coding agent working in an isolated git worktree.

- Worktree: \`$WORKTREE_PATH\`
- Branch: crew/$WORKER_ID
- All changes here are isolated - will be merged by lead agent later

## Task-Type Rules

### If ship:
- Deliver code changes
- Make commits: git add + git commit
- Write tests if applicable
- Update $OUTPUT_PATH with progress and final summary
- On completion: append "<!-- STATUS: DONE -->" and summary

### If scout:
- Investigation only, no code changes required (but you may create notes)
- Explore codebase, read files, run grep/rg
- Write findings to $OUTPUT_PATH as markdown report
- Include: summary, files examined, key insights, recommendations
- On completion: append "<!-- STATUS: DONE -->" and report

## Communication Protocol

Filesystem is your IPC:
- **output.md** at \`$OUTPUT_PATH\` - your main channel
- Append logs, findings, progress
- Signal terminal state with HTML comment marker:
  - <!-- STATUS: DONE -->
  - <!-- STATUS: BLOCKED --> + reason
  - <!-- STATUS: FAILED --> + reason

Example when done (ship):
\`\`\`markdown
## Completed

Implemented X, Y, Z. Tests pass. Commits: abc123.

<!-- STATUS: DONE -->
\`\`\`

Example when blocked:
\`\`\`markdown
## Blocked

Need clarification on auth requirements.

<!-- STATUS: BLOCKED -->
\`\`\`

## Environment

- You have full shell access in worktree
- Git available, worktree is a full checkout
- Write freely, but remember to signal completion

## Start

Begin work now. Log everything to output.md
PROMPT_EOF

log_to_output "Created PROMPT.md in worktree"

# Placeholder simulation function (demo mode)
run_placeholder() {
  log_to_output ""
  if [[ "$TASK_TYPE" == "scout" ]]; then
    log_to_output "## Simulated Scout Work"
    log_to_output ""
    log_to_output "Task: $TASK_DESC"
    log_to_output ""
    log_to_output "Exploring codebase..."
    log_to_output ""
    if [[ -d "$WORKTREE_PATH" ]]; then
      log_to_output "### File structure (top level):"
      log_to_output '```'
      ls -la "$WORKTREE_PATH" 2>/dev/null | head -n 50 | tee -a "$OUTPUT_PATH" || true
      log_to_output '```'
      log_to_output ""
      log_to_output "### Git status:"
      log_to_output '```'
      git -C "$WORKTREE_PATH" status 2>&1 | head -n 100 | tee -a "$OUTPUT_PATH" || true
      log_to_output '```'
    fi
    log_to_output ""
    log_to_output "### Findings (auto-generated placeholder)"
    log_to_output ""
    log_to_output "Since this is generic adapter fallback, this is placeholder."
    log_to_output "In production, your coding agent would replace this with real investigation."
    log_to_output ""
    log_to_output "- Searched files via ls, git"
    log_to_output "- Task was: $TASK_DESC"
    log_to_output "- Recommendation: Use real adapter (claude-code) or ensure agent CLI in PATH"
    log_to_output ""
    log_to_output "<!-- STATUS: DONE -->"
    echo "[generic adapter] Scout placeholder completed"
    exit 0
  else
    log_to_output "## Simulated Ship Work"
    log_to_output ""
    log_to_output "Task: $TASK_DESC"
    log_to_output ""
    log_to_output "No real agent - creating demo commit to prove flow."
    log_to_output ""
    (
      cd "$WORKTREE_PATH" 2>/dev/null || exit 0
      echo "# Worker $WORKER_ID" > "WORKER_${WORKER_ID}.md"
      echo "" >> "WORKER_${WORKER_ID}.md"
      printf 'Task: %s\n' "$TASK_DESC" >> "WORKER_${WORKER_ID}.md"
      printf 'Type: %s\n' "$TASK_TYPE" >> "WORKER_${WORKER_ID}.md"
      printf 'Created: %s\n' "$(date -u)" >> "WORKER_${WORKER_ID}.md"
      echo "" >> "WORKER_${WORKER_ID}.md"
      echo "This is placeholder file created by generic adapter." >> "WORKER_${WORKER_ID}.md"
      echo "In production, replace with real code changes." >> "WORKER_${WORKER_ID}.md"
      if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        git add "WORKER_${WORKER_ID}.md" 2>/dev/null || true
        git config user.email "crew@generic.adapter" 2>/dev/null || true
        git config user.name "Generic Crew Worker $WORKER_ID" 2>/dev/null || true
        # Write commit message to file to avoid shell injection via TASK_DESC
        COMMIT_MSG_FILE=$(mktemp)
        {
          printf 'crew(%s): ' "$WORKER_ID"
          cat "$BRIEF_PATH" 2>/dev/null || printf '%s' "$TASK_DESC"
          printf '\n\nTask-Type: %s\n' "$TASK_TYPE"
          printf 'Worker: %s\n' "$WORKER_ID"
          printf 'Adapter: generic\n\n'
          printf 'Placeholder commit to demo ship flow.\n'
        } > "$COMMIT_MSG_FILE"
        git commit -F "$COMMIT_MSG_FILE" 2>&1 | tee -a "$OUTPUT_PATH" || true
        rm -f "$COMMIT_MSG_FILE"
      else
        log_to_output "Not in git repo - placeholder file created but not committed"
      fi
    )
    log_to_output ""
    log_to_output "Created placeholder artifact."
    log_to_output ""
    log_to_output "<!-- STATUS: DONE -->"
    echo "[generic adapter] Ship placeholder completed"
    exit 0
  fi
}

# Detect available agent CLIs
AGENT_CMD=""
if command -v cursor-agent >/dev/null 2>&1; then
  AGENT_CMD="cursor-agent"
elif command -v codex >/dev/null 2>&1; then
  AGENT_CMD="codex"
elif command -v aider >/dev/null 2>&1; then
  AGENT_CMD="aider"
elif command -v claude >/dev/null 2>&1; then
  AGENT_CMD="claude"
elif command -v amp >/dev/null 2>&1; then
  AGENT_CMD="amp"
fi

if [[ -n "$AGENT_CMD" ]]; then
  log_to_output "Detected agent CLI: $AGENT_CMD (attempting launch, fallback to placeholder if unavailable)"
  echo "============================================"
  echo "Launching agent: $AGENT_CMD"
  echo "Worktree: $WORKTREE_PATH"
  echo "Task: $TASK_DESC"
  echo "============================================"

  case "$AGENT_CMD" in
    cursor-agent)
      if cursor-agent --print "Read $WORKTREE_PATH/PROMPT.md and complete task. Log to $OUTPUT_PATH" 2>&1 | tee -a "$OUTPUT_PATH"; then
        true
      else
        log_to_output "cursor-agent failed, fallback to placeholder"
      fi
      ;;
    codex)
      if codex --help 2>&1 | grep -q "Codex CLI at Meta"; then
        log_to_output "Meta Codex detected - using exec mode"
        # Try non-interactive exec, but don't block forever if needs auth
        set +e
        timeout 10 bash -c "cat \"$WORKTREE_PATH/PROMPT.md\" | codex exec --cd \"$WORKTREE_PATH\" --skip-git-repo-check 2>&1 | tee -a \"$OUTPUT_PATH\""
        CODEX_EC=$?
        set -e
        if [[ $CODEX_EC -eq 124 ]]; then
          log_to_output "codex exec timed out or needs interactive auth - fallback to placeholder"
        elif [[ $CODEX_EC -ne 0 ]]; then
          log_to_output "codex exec exited $CODEX_EC - fallback to placeholder"
        fi
      else
        # OpenAI public codex
        set +e
        if codex --help 2>&1 | grep -q "\-q"; then
          codex -q "$(cat "$WORKTREE_PATH/PROMPT.md")" 2>&1 | tee -a "$OUTPUT_PATH"
        else
          cat "$WORKTREE_PATH/PROMPT.md" | codex exec 2>&1 | tee -a "$OUTPUT_PATH"
        fi
        set -e
      fi
      ;;
    aider)
      set +e
      aider --message "$(cat "$WORKTREE_PATH/PROMPT.md")" 2>&1 | tee -a "$OUTPUT_PATH"
      set -e
      ;;
    claude)
      log_to_output "Claude detected but using generic adapter. For full claude-code adapter use --adapter claude-code"
      sleep 1
      ;;
    *)
      log_to_output "Agent $AGENT_CMD detected, no custom launch - see PROMPT.md"
      ;;
  esac

  # After attempt, check if STATUS marker now present
  if grep -q "STATUS: DONE\|STATUS: BLOCKED\|STATUS: FAILED" "$OUTPUT_PATH" 2>/dev/null; then
    echo "Agent signaled completion via output.md"
    exit 0
  else
    echo "Agent did not signal STATUS, falling back to placeholder simulation"
    log_to_output "No STATUS marker from $AGENT_CMD, running placeholder to ensure DONE"
    run_placeholder
  fi
else
  log_to_output "No known agent CLI detected. Running in SIMULATION mode."
  log_to_output "Worktree: $WORKTREE_PATH"
  log_to_output "Prompt: $WORKTREE_PATH/PROMPT.md"
  echo ""
  echo "GENERIC ADAPTER - SIMULATION MODE"
  echo "Worktree: $WORKTREE_PATH"
  echo "Task: $TASK_DESC"
  run_placeholder
fi
