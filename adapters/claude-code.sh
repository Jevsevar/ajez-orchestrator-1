#!/usr/bin/env bash
# adapters/claude-code.sh - Claude Code terminal adapter
# Optimized for Claude Code CLI (`claude` command)
# Contract identical to generic.sh:
#   adapters/claude-code.sh <worker-id> <worktree_path> <task_type> <task_desc> <output_path> <manifest_path>

set -euo pipefail

WORKER_ID="${1:-unknown}"
WORKTREE_PATH="${2:-$(pwd)}"
TASK_TYPE="${3:-ship}"
TASK_DESC="${4:-No task provided}"
OUTPUT_PATH="${5:-$WORKTREE_PATH/../output.md}"
MANIFEST_PATH="${6:-}"

log_to_output() {
  echo "$@" | tee -a "$OUTPUT_PATH"
}

log_to_output ""
log_to_output "## Adapter: claude-code"
log_to_output "- Started: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
log_to_output "- Worker: $WORKER_ID"
log_to_output "- Type: $TASK_TYPE"
log_to_output "- Worktree: $WORKTREE_PATH"
log_to_output "- Output: $OUTPUT_PATH"
log_to_output "- Manifest: $MANIFEST_PATH"
log_to_output ""

# Create detailed prompt for Claude
cat > "$WORKTREE_PATH/CLAUDE_TASK.md" <<TASK_EOF
# Crew Worker Task: $WORKER_ID

You are an autonomous worker in a crew orchestrator system. You work in an isolated git worktree.

## Context

- **Worker ID:** $WORKER_ID
- **Type:** $TASK_TYPE
- **Worktree:** $WORKTREE_PATH
- **Branch:** crew/$WORKER_ID
- **Lead output:** $OUTPUT_PATH
- **Manifest:** $MANIFEST_PATH

## Your Task

> $TASK_DESC

## Task Type Specifics

### If TASK_TYPE=ship:
- Deliver code changes that satisfy the task
- You are on branch crew/$WORKER_ID already
- Workflow:
  1. Understand codebase in this worktree
  2. Implement solution
  3. Run tests if they exist (npm test, make test, pytest, etc.)
  4. Commit: git add <files> && git commit -m "crew($WORKER_ID): <summary>"
  5. Document what you did in $OUTPUT_PATH
- Do NOT push. Lead agent will handle merging.

### If TASK_TYPE=scout:
- Investigation / report only
- Do NOT make code changes unless asked to create notes
- Explore files via Read, Grep, Glob
- Write thorough findings to $OUTPUT_PATH:
  - Summary
  - Files examined
  - Architecture / flow insights
  - Recommendations
  - Open questions

## Communication Protocol (CRITICAL)

The lead agent communicates with you ONLY via filesystem.

- **Your output:** $OUTPUT_PATH (markdown)
  - Append progress, logs, decisions, findings there
  - Use bash tool to append: echo "..." >> "$OUTPUT_PATH"

- **Completion signals (append to output):**
  - DONE:
    \`\`\`
    ## Result: <summary>
    <!-- STATUS: DONE -->
    \`\`\`
  - BLOCKED:
    \`\`\`
    ## Blocked: <reason>
    <!-- STATUS: BLOCKED -->
    \`\`\`
  - FAILED:
    \`\`\`
    ## Failed: <reason>
    <!-- STATUS: FAILED -->
    \`\`\`

The watcher polls your manifest and output.md. If you forget the marker, you'll be marked FAILED after tmux dies.

- **Manifest:** $MANIFEST_PATH
  - You MAY update your own status via jq:
    \`\`\`bash
    jq '.status="DONE" | .updated_at="'$(date -u +%Y-%m-%dT%H:%M:%SZ)'"' $MANIFEST_PATH > /tmp/m.json && mv /tmp/m.json $MANIFEST_PATH
    \`\`\`
  - But output marker is primary signal.

- **PROMPT.md vs CLAUDE_TASK.md:** CLAUDE_TASK.md is your main instruction (this file). PROMPT.md exists for generic adapters.

## Rules

1. Work ONLY in $WORKTREE_PATH
2. Do not edit files outside worktree
3. Do not run git push
4. Keep output.md up-to-date - it's what lead agent reads
5. Be autonomous: try, run tests, fix, iterate
6. On DONE, include commit hashes and file list for ship, or full report for scout

## Quick Checks Available

- pwd, ls, git status, git log --oneline -5
- Your worktree remote: git -C $WORKTREE_PATH remote -v
- Existing workers: ls $WORKTREE_PATH/../.orchestrator/crew/ (from root)

Begin work now. Good luck.

TASK_EOF

log_to_output "Created CLAUDE_TASK.md"

# Also create PROMPT.md for compatibility
cp "$WORKTREE_PATH/CLAUDE_TASK.md" "$WORKTREE_PATH/PROMPT.md" 2>/dev/null || true

# Detect claude CLI
if ! command -v claude >/dev/null 2>&1; then
  log_to_output "WARNING: claude CLI not found in PATH"
  log_to_output "Falling back to generic adapter behavior with manual instructions"
  log_to_output ""
  log_to_output "To use this adapter properly:"
  log_to_output "  - Install Claude Code: https://docs.claude.com/claude-code"
  log_to_output "  - Ensure 'claude' is in PATH"
  log_to_output ""
  # Fallback to generic placeholder logic but with claude task file
  bash "$(dirname "${BASH_SOURCE[0]}")/generic.sh" "$WORKER_ID" "$WORKTREE_PATH" "$TASK_TYPE" "$TASK_DESC" "$OUTPUT_PATH" "$MANIFEST_PATH"
  exit $?
fi

echo ""
echo "=========================================="
echo " Claude Code Adapter - $WORKER_ID"
echo "=========================================="
echo " Worktree: $WORKTREE_PATH"
echo " Task: $TASK_DESC"
echo " Type: $TASK_TYPE"
echo " Prompt: $WORKTREE_PATH/CLAUDE_TASK.md"
echo " Output: $OUTPUT_PATH"
echo "=========================================="
echo ""

log_to_output "Detected claude CLI: $(which claude) - version $(claude --version 2>&1 || echo unknown)"

# Prepare claude launch command
# We want non-interactive for ship tasks where possible, but interactive for complex
# Claude Code supports --print and direct prompt, but for crew we often want full session.
# Option 1: claude --dangerously-skip-permissions task file? However we keep safe default.
# We'll use: claude "Read CLAUDE_TASK.md and do it"

# Check claude-code best practices: use -p for print mode if available for automation
# But for crew orchestrator, workers should be autonomous interactive agents in tmux pane,
# so we start normal claude session with initial prompt piped? Approach:

# Method: Launch claude with task via file
# The tmux session is already created by spawn-worker.sh running this adapter, so we are inside tmux
# So we can exec claude directly

cd "$WORKTREE_PATH"

# Write a startup script that claude will execute as first message trick? Simpler: we have CLAUDE_TASK.md
# We'll invoke claude printing task and then keep interactive

# Some versions of claude-code support: claude --prompt "$(cat file)"
# Try to detect help

CLAUDE_HELP="$(claude --help 2>&1 || true)"

if echo "$CLAUDE_HELP" | grep -q "\-\-print"; then
  log_to_output "Using claude --print mode"
  echo "[claude-code adapter] Running in --print (non-interactive) mode"
  echo ""

  # In print mode, claude outputs result and exits; we tee to output.md
  # Need to ensure it writes completion marker - we instruct via prompt
  PROMPT_TEXT="$(cat "$WORKTREE_PATH/CLAUDE_TASK.md")"
  PROMPT_TEXT="$PROMPT_TEXT

IMPORTANT FINAL STEP: After completing work, run:
echo '## Result: Done' >> $OUTPUT_PATH
echo '<!-- STATUS: DONE -->' >> $OUTPUT_PATH

If blocked:
echo '## Blocked: reason' >> $OUTPUT_PATH
echo '<!-- STATUS: BLOCKED -->' >> $OUTPUT_PATH
"

  set +e
  echo "$PROMPT_TEXT" | claude --print --dangerously-skip-permissions --output-format text 2>&1 | tee -a "$OUTPUT_PATH"
  CLAUDE_EXIT=${PIPESTATUS[0]:-0}
  set -e

  echo ""
  echo "[claude-code adapter] Claude finished with exit $CLAUDE_EXIT"

  if ! grep -q "STATUS: DONE\|STATUS: BLOCKED\|STATUS: FAILED" "$OUTPUT_PATH" 2>/dev/null; then
    if [[ $CLAUDE_EXIT -eq 0 ]]; then
      log_to_output ""
      log_to_output "<!-- STATUS: DONE -->"
      log_to_output "## Auto-marked DONE (claude --print exited 0)"
    else
      log_to_output ""
      log_to_output "<!-- STATUS: FAILED -->"
      log_to_output "## Failed with exit $CLAUDE_EXIT"
    fi
  fi
  exit $CLAUDE_EXIT

else
  log_to_output "Using interactive claude mode"
  echo "[claude-code adapter] Interactive mode - starting claude session"
  echo ""
  echo "If this looks stuck, try: claude \"\$(cat CLAUDE_TASK.md)\""
  echo ""

  # Provide task as initial context via file + explicit instruction
  # We'll try to start claude with prompt if supported, else just launch with instructions printed

  cat <<LAUNCH_HINT
To start work, run inside this pane:

  claude

Then paste / read CLAUDE_TASK.md

Or try non-interactive:

  claude "$(cat CLAUDE_TASK.md | head -n 200)"

The adapter will wait until you signal DONE in output.md
LAUNCH_HINT

  # Try auto-start claude with task file
  if [[ -f "$WORKTREE_PATH/CLAUDE_TASK.md" ]]; then
    exec_cmd="claude"
    echo "[adapter] Attempting: $exec_cmd with task"
    echo ""

    # We will set CLAUDE_TASK to be passed as argument; we use bash to preserve history
    # Use --prompt file if supported, else cat
    if echo "$CLAUDE_HELP" | grep -q "prompt"; then
      # Some builds support reading from stdin prompt file?
      PROMPT="$(cat "$WORKTREE_PATH/CLAUDE_TASK.md")"
      # Try passing as arg (might be truncated, but attempt)
      claude "$PROMPT" 2>&1 | tee -a "$OUTPUT_PATH" || true
    else
      # Just launch claude, user/agent can read task file manually
      claude 2>&1 | tee -a "$OUTPUT_PATH" || true
    fi

    CLAUDE_EXIT=${PIPESTATUS[0]:-0}
  else
    claude 2>&1 | tee -a "$OUTPUT_PATH" || true
    CLAUDE_EXIT=$?
  fi

  echo "[claude-code adapter] Session ended exit $CLAUDE_EXIT"

  # Ensure status marker
  if ! grep -q "STATUS: DONE\|STATUS: BLOCKED\|STATUS: FAILED" "$OUTPUT_PATH" 2>/dev/null; then
    log_to_output ""
    if [[ $CLAUDE_EXIT -eq 0 ]]; then
      log_to_output "<!-- STATUS: DONE -->"
    else
      log_to_output "<!-- STATUS: FAILED -->"
    fi
  fi

  exit $CLAUDE_EXIT
fi
