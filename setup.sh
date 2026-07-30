#!/usr/bin/env bash
# setup.sh - Validate prerequisites and initialize orchestrator state
# Agent Distro / firstmate-inspired crew orchestrator
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ORCH_DIR="$ROOT_DIR/.orchestrator"
CREW_DIR="$ORCH_DIR/crew"
LOGS_DIR="$ORCH_DIR/logs"
WORKTREES_DIR="$ORCH_DIR/worktrees"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

info()  { echo -e "${CYAN}[setup]${NC} $*"; }
ok()    { echo -e "${GREEN}[ok]${NC} $*"; }
warn()  { echo -e "${YELLOW}[warn]${NC} $*"; }
fail()  { echo -e "${RED}[fail]${NC} $*" >&2; }

echo ""
echo "=== Agent Distro Setup ==="
echo "Root: $ROOT_DIR"
echo ""

# Track failures
MISSING=0
OPTIONAL_MISSING=0

check_cmd() {
  local cmd="$1"
  local required="${2:-true}"
  local hint="${3:-}"
  if command -v "$cmd" >/dev/null 2>&1; then
    ok "$cmd found: $(command -v "$cmd")"
    if [ "$cmd" = "tmux" ]; then
      tmux -V 2>/dev/null || true
    elif [ "$cmd" = "git" ]; then
      git --version 2>/dev/null || true
    elif [ "$cmd" = "jq" ]; then
      jq --version 2>/dev/null || true
    fi
  else
    if [ "$required" = "true" ]; then
      fail "$cmd NOT found - required"
      [ -n "$hint" ] && echo "      hint: $hint" >&2
      MISSING=$((MISSING+1))
    else
      warn "$cmd NOT found - optional"
      [ -n "$hint" ] && echo "      hint: $hint"
      OPTIONAL_MISSING=$((OPTIONAL_MISSING+1))
    fi
  fi
}

# Required checks
check_cmd "git" true "brew install git / apt install git"
check_cmd "tmux" true "brew install tmux / apt install tmux"
check_cmd "bash" true

# Optional but recommended
check_cmd "jq" false "brew install jq - for better JSON handling (fallback to sed if missing)"
check_cmd "claude" false "Install Claude Code CLI for claude-code adapter"

echo ""
info "Checking git repository..."
if git -C "$ROOT_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  ok "Inside git repo: $(git -C "$ROOT_DIR" rev-parse --show-toplevel)"
  # Check worktree support
  if git worktree --help >/dev/null 2>&1; then
    ok "git worktree supported"
  else
    fail "git worktree not supported - need git >= 2.5"
    MISSING=$((MISSING+1))
  fi
else
  warn "Not inside a git repository."
  echo "      The orchestrator uses git worktrees for isolation."
  echo "      Run 'git init' in this directory or clone inside a git repo."
  echo "      Setup will continue and create state dirs anyway for demo."
fi

if [ "$MISSING" -gt 0 ]; then
  echo ""
  fail "Setup failed: $MISSING required prerequisite(s) missing."
  exit 1
fi

echo ""
info "Creating state directories..."

mkdir -p "$CREW_DIR"
mkdir -p "$LOGS_DIR"
mkdir -p "$WORKTREES_DIR"

# .gitkeep for empty tracked dirs (gitignore will still exclude contents if needed)
touch "$CREW_DIR/.gitkeep" 2>/dev/null || true
touch "$LOGS_DIR/.gitkeep" 2>/dev/null || true
touch "$WORKTREES_DIR/.gitkeep" 2>/dev/null || true

# Initialize logs
LOG_FILE="$LOGS_DIR/orchestrator.log"
if [ ! -f "$LOG_FILE" ]; then
  echo "# Orchestrator log - created $(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$LOG_FILE"
fi

ok "Created $CREW_DIR"
ok "Created $LOGS_DIR"
ok "Created $WORKTREES_DIR"

# Ensure scripts executable
info "Making scripts executable..."
chmod +x "$ROOT_DIR/scripts/"*.sh 2>/dev/null || true
chmod +x "$ROOT_DIR/adapters/"*.sh 2>/dev/null || true
chmod +x "$ROOT_DIR/setup.sh"
ok "Scripts chmod +x done"

# Create .gitignore if not exists, or append orchestrator ignores
GITIGNORE="$ROOT_DIR/.gitignore"
if [ ! -f "$GITIGNORE" ]; then
  info "Creating .gitignore..."
  cat > "$GITIGNORE" <<'GITIGNORE_EOF'
# Agent Distro - orchestrator state (restart-proof, local-only)
.orchestrator/worktrees/
.orchestrator/logs/
.orchestrator/report.md
*.log

# OS
.DS_Store
Thumbs.db

# Keep structure but ignore runtime content
# crew manifests are part of state - you may want to .gitignore them too in production:
# .orchestrator/crew/*/
GITIGNORE_EOF
  ok "Created .gitignore"
else
  # Ensure our entries exist
  if ! grep -q ".orchestrator/worktrees" "$GITIGNORE" 2>/dev/null; then
    echo "" >> "$GITIGNORE"
    echo "# agent-distro state" >> "$GITIGNORE"
    echo ".orchestrator/worktrees/" >> "$GITIGNORE"
    echo ".orchestrator/logs/" >> "$GITIGNORE"
    warn "Appended worktree/log ignores to existing .gitignore"
  else
    ok ".gitignore already contains orchestrator ignores"
  fi
fi

echo ""
echo -e "${GREEN}=== Setup Complete ===${NC}"
echo ""
echo "Next steps:"
echo "  1. Read AGENTS.md to understand orchestration protocol"
echo "  2. Spawn a worker:"
echo "     ./scripts/spawn-worker.sh --task-type scout --task \"Explore codebase structure\" --adapter generic"
echo "  3. Watch workers:"
echo "     ./scripts/watcher.sh --once"
echo "     ./scripts/watcher.sh --watch   # continuous"
echo "  4. Collect results:"
echo "     ./scripts/collect-output.sh --all"
echo ""
if [ "$OPTIONAL_MISSING" -gt 0 ]; then
  warn "$OPTIONAL_MISSING optional tool(s) missing - see above. Core will still work."
fi
echo ""
