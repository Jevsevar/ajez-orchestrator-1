# Agent Distro — Turn Any Terminal Agent into a Crew Orchestrator

> Like **firstmate** for coding agents: talk to one lead, spawn a crew in parallel tmux panes with isolated git worktrees.

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Bash Only](https://img.shields.io/badge/deps-bash%20%2B%20tmux%20%2B%20git-green)](setup.sh)

Clone this repo, run `setup.sh`, and your terminal coding agent (Claude Code, Cursor, Codex, Aider, or any shell agent) becomes a **lead orchestrator** that can delegate to a crew working in parallel.

All state is **JSON + Markdown on disk** — restart-proof, no DB.

**Bash scripts only** — no Python/Node runtime required.

---

## Architecture

```
User talks to Lead Agent (reads AGENTS.md)
        │
        ├─► scripts/spawn-worker.sh
        │     ├─ creates .orchestrator/crew/<id>/manifest.json (PENDING → SPAWNING)
        │     ├─ git worktree add .orchestrator/worktrees/<id> -b crew/<id>
        │     ├─ creates .orchestrator/crew/<id>/output.md
        │     └─ tmux new-session -d -s crew-<id> adapters/<adapter>.sh
        │           └─ Agent works in worktree, logs to output.md
        │
        ├─► scripts/watcher.sh (supervisor)
        │     ├─ poll tmux alive? + output.md STATUS marker?
        │     ├─ update manifest → DONE | BLOCKED | FAILED
        │     └─ logs to .orchestrator/logs/
        │
        └─► scripts/collect-output.sh (gather results)
              ├─ reads crew/*/output.md
              ├─ generates .orchestrator/report.md
              └─ shows merge commands for ship workers

Communication: Filesystem only (manifest.json ↔ output.md)
```

### State Diagram

```
PENDING → SPAWNING → RUNNING → DONE
                      ├→ BLOCKED
                      └→ FAILED
```

- **PENDING**: manifest created
- **SPAWNING**: worktree + tmux starting
- **RUNNING**: tmux alive, agent working
- **DONE**: `<!-- STATUS: DONE -->` in output.md
- **BLOCKED**: `<!-- STATUS: BLOCKED -->` needs input
- **FAILED**: tmux died or adapter error

All stored in `.orchestrator/crew/<id>/manifest.json`

### Directory Layout

```
.
├── AGENTS.md                Lead agent instructions (read this!)
├── setup.sh                 Validate tmux/git, create state dirs
├── scripts/
│   ├── common.sh            Shared helpers (json, logging, ids)
│   ├── spawn-worker.sh      Spawn: worktree + tmux + agent
│   ├── watcher.sh           Poll alive/done/blocked
│   ├── collect-output.sh    Gather results → report.md
│   ├── list-workers.sh      Table of workers
│   └── kill-worker.sh       Kill tmux, optionally remove worktree
├── adapters/
│   ├── generic.sh           Any terminal agent / human / fallback demo
│   └── claude-code.sh       Optimized for claude CLI
├── skills/
│   ├── spawning.md          How to spawn effectively
│   ├── supervision.md       Monitoring & recovery
│   ├── collection.md        Collect & merge
│   ├── task-types.md        ship vs scout deep dive
│   └── worktree-management.md  Git worktree lifecycle
├── .orchestrator/
│   ├── crew/<id>/           Per-worker manifest + output.md
│   ├── worktrees/<id>/      Isolated git checkouts
│   ├── logs/                orchestrator.log + watcher.log
│   └── README.md            State dir docs
└── LICENSE (MIT)
```

---

## Quickstart

### 1. Clone + Setup

```bash
git clone https://github.com/your-org/agent-distro.git
cd agent-distro
./setup.sh
```

Setup validates `git`, `tmux`, `bash` (required), `jq` (optional but recommended), `claude` (optional) and creates `.orchestrator/` dirs.

### 2. Spawn a Crew

Your lead agent (or you manually) spawns workers:

```bash
# Scout: investigation report
./scripts/spawn-worker.sh --task-type scout --task "Map auth flow: entry points, JWT validation, session handling. List files with line refs" --adapter generic --id scout-auth

# Ship: code changes
./scripts/spawn-worker.sh --task-type ship --task "Fix null check in src/user.ts:42 add early return for null user before name access, add test in tests/user.test.ts" --adapter generic --id ship-user-fix
```

### 3. Watch Progress

```bash
# One-off poll
./scripts/watcher.sh --once

# Live table
./scripts/list-workers.sh

# Continuous watch (in separate pane)
./scripts/watcher.sh --watch --interval 5

# Check logs
tail -f .orchestrator/logs/orchestrator.log
cat .orchestrator/crew/scout-auth/output.md
```

Attach to worker tmux:

```bash
tmux attach -t crew-scout-auth
# detach: Ctrl+b d
```

### 4. Collect Results

```bash
./scripts/collect-output.sh --list
./scripts/collect-output.sh --all --format markdown
./scripts/collect-output.sh --report                # generates .orchestrator/report.md
./scripts/collect-output.sh --report --merge-branches
cat .orchestrator/report.md
```

### 5. Merge Ship Workers

```bash
git log --oneline crew/ship-user-fix ^main
git diff main..crew/ship-user-fix --stat
git checkout main
git merge --no-ff crew/ship-user-fix

# Cleanup
git worktree remove .orchestrator/worktrees/ship-user-fix
git branch -d crew/ship-user-fix
```

---

## Task Types

### `scout` — Investigation Reports

- **Goal**: findings, no commits expected
- **Output**: `output.md` is deliverable (summary, files examined, insights, recommendations)
- **When**: explore, audit, map, understand

Example:
```bash
./scripts/spawn-worker.sh --task-type scout --task "Audit payment module test coverage, list uncovered files, suggest tests" --adapter generic
```

### `ship` — Deliver Code

- **Goal**: code changes + commits on `crew/<id>` branch
- **Output**: commits + summary in `output.md`
- **When**: fix, implement, add tests, refactor

Example:
```bash
./scripts/spawn-worker.sh --task-type ship --task "Implement ThemeContext in src/theme/context.tsx with localStorage persist, add tests" --adapter claude-code
```

See `skills/task-types.md` for full spec.

---

## Adapters

Adapter contract:

```bash
adapter.sh <worker-id> <worktree> <task_type> <task_desc> <output.md> <manifest.json>
# Must write to output.md and append <!-- STATUS: DONE|BLOCKED|FAILED -->
```

### `generic.sh`

- Works with **any** terminal agent or human
- Detects CLI: `cursor-agent`, `codex`, `aider`, `claude`, `amp`
- If none found: runs placeholder that proves flow:
  - scout: lists files, git status
  - ship: creates placeholder file + commit
- Always creates `PROMPT.md` in worktree with task instructions

Good for demo, CI, or human-in-the-loop.

### `claude-code.sh`

- Optimized for Claude Code CLI (`claude`)
- Creates `CLAUDE_TASK.md` with rich context
- If `claude --print` available: runs non-interactively, auto-marks DONE
- If interactive: starts `claude` session in tmux, waits for DONE marker
- Falls back to generic if `claude` missing

Extend: add `adapters/cursor.sh`, `adapters/codex.sh`, etc. following same contract.

---

## Lead Agent (AGENTS.md)

When a terminal coding agent reads `AGENTS.md`, it learns to orchestrate:

- Decompose tasks → spawn parallel workers
- Supervise via `watcher.sh` + `list-workers.sh`
- Communicate via filesystem (`manifest.json`, `output.md`)
- Collect via `collect-output.sh --report`
- Merge ship branches, summarize scout reports

Example lead flow:

```
User: "Refactor auth and add tests"
Lead:
  1. scout: map auth flow
  2. watch → DONE, read report
  3. spawn 3 ship workers in parallel:
     - ship-auth-refactor
     - ship-auth-tests
     - ship-auth-docs
  4. watch loop until all DONE
  5. collect --report
  6. show git diff and merge commands
```

Full instructions: [`AGENTS.md`](AGENTS.md)  
Skills: [`skills/`](skills/)

---

## Examples

### Parallel Bug Fixes

```bash
./setup.sh

./scripts/spawn-worker.sh --task-type ship --task "Fix race in src/queue.ts: add mutex to enqueue" --id queue-fix --adapter generic
./scripts/spawn-worker.sh --task-type ship --task "Fix leak in src/cache.ts: clear map on evict" --id cache-fix --adapter generic
./scripts/spawn-worker.sh --task-type ship --task "Fix null in src/user.ts:42 early return" --id user-fix --adapter generic

./scripts/watcher.sh --watch

# Later
./scripts/collect-output.sh --all --format markdown
git log --oneline --graph --all --decorate | grep crew/
```

### Scout Then Ship

```bash
# Phase 1: scout
./scripts/spawn-worker.sh --task-type scout --task "Explore payment module: list files in src/payment, entry points, test coverage, risks" --id scout-payment --adapter claude-code
./scripts/watcher.sh --once
cat .orchestrator/crew/scout-payment/output.md

# Phase 2: ship based on findings
./scripts/spawn-worker.sh --task-type ship --task "Implement idempotency in src/payment/process.ts - see scout-payment/output.md for context - add tests" --id ship-idempotency --adapter claude-code
./scripts/spawn-worker.sh --task-type ship --task "Add unit tests for uncovered files listed in scout-payment/output.md section Files Examined" --id ship-pay-tests --adapter generic

./scripts/collect-output.sh --report
```

### Using Claude Code Adapter

```bash
# Ensure claude CLI in PATH
which claude
claude --version

./scripts/spawn-worker.sh --task-type ship --task "Add dark mode toggle to Settings page" --adapter claude-code --id dark-mode

tmux attach -t crew-dark-mode
# Claude will auto-start if --print supported, or you interact

./scripts/collect-output.sh --worker dark-mode --format markdown
```

---

## Design Constraints Met

- ✅ All state JSON + Markdown on disk (restart-proof)
- ✅ Bash scripts only (no python/node deps)
- ✅ Worker lifecycle PENDING→SPAWNING→RUNNING→DONE|BLOCKED|FAILED
- ✅ ship and scout task types
- ✅ Filesystem communication (manifest.json + output.md)
- ✅ tmux pane + isolated git worktree per worker
- ✅ adapters/ for agent-specific launch
- ✅ skills/ markdown docs for lead agent
- ✅ setup.sh validates prereqs

---

## Scripts Reference

| Script | Purpose |
|---|---|
| `setup.sh` | Validate tmux, git, create state dirs |
| `scripts/common.sh` | Helpers: json_escape, log_event, generate_id |
| `scripts/spawn-worker.sh` | Create manifest, worktree, tmux session, launch adapter |
| `scripts/watcher.sh` | Poll tmux alive + output.md STATUS markers, update manifest |
| `scripts/collect-output.sh` | Gather outputs, --report, --list, --merge-branches |
| `scripts/list-workers.sh` | Table view with tmux status |
| `scripts/kill-worker.sh` | Kill tmux, optionally remove worktree/branch |
| `adapters/generic.sh` | Any agent / fallback demo |
| `adapters/claude-code.sh` | Claude Code optimized |

### Spawn Flags

```
--task-type  ship|scout (required)
--task       description (required)
--adapter    generic|claude-code (default generic)
--id         custom worker id (default auto)
--base-branch branch to base worktree off (default HEAD)
--dry-run    preview without spawning
```

### Watcher Flags

```
--once               single pass
--watch              continuous loop
--interval SEC       seconds between polls (default 5)
```

### Collect Flags

```
--all                terminal workers (DONE|BLOCKED|FAILED)
--worker ID          single worker
--status STATUS      filter by status
--format text|markdown|json
--report             generate .orchestrator/report.md
--list               table
--merge-branches     include git merge commands
-o FILE              output file
```

---

## Extending

### Add New Adapter

Create `adapters/my-agent.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
WORKER_ID=$1
WORKTREE=$2
TASK_TYPE=$3
TASK_DESC=$4
OUTPUT=$5
MANIFEST=$6

echo "## Adapter: my-agent" >> "$OUTPUT"
cd "$WORKTREE"
# launch your agent
my-agent --prompt "$TASK_DESC" 2>&1 | tee -a "$OUTPUT"
echo "<!-- STATUS: DONE -->" >> "$OUTPUT"
```

Make executable: `chmod +x adapters/my-agent.sh`

Then spawn: `./scripts/spawn-worker.sh --task-type ship --task "..." --adapter my-agent`

### Add New Skill

Create `skills/my-skill.md` with markdown instructions for lead agent. Reference it in AGENTS.md or instruct user to mention it.

---

## Troubleshooting

| Symptom | Fix |
|---|---|
| "tmux not found" | `brew install tmux` / `apt install tmux` |
| "Not in git repo" | `git init && git add . && git commit -m init` or use fallback dir mode |
| "branch already exists crew/X" | `git branch -D crew/X && git worktree remove --force .orchestrator/worktrees/X` |
| "worktree exists" | `rm -rf .orchestrator/worktrees/X` |
| Worker stuck RUNNING | `tmux capture-pane -t crew-X -p`, read output.md, `tmux send-keys -t crew-X "hint" Enter` |
| Want clean slate | `./scripts/kill-worker.sh <id> --remove-worktree` for each, or `git worktree list` then remove, `rm -rf .orchestrator/crew/*` |

Logs: `.orchestrator/logs/orchestrator.log` and `watcher.log`

---

## Why firstmate-inspired?

- **firstmate** pattern: lead agent + crew of specialists working in parallel.
- This repo packages the scaffolding (tmux, worktrees, state JSON) so any terminal agent becomes a crew orchestrator just by cloning and reading `AGENTS.md`.
- No vendor lock-in: adapters make it work with any CLI.

---

## License

MIT — see [LICENSE](LICENSE)

## Contributing

PRs welcome for:
- New adapters (Cursor, Codex, Aider, etc.)
- Skills improvements
- Watcher heuristics
- Consolidation of reporter

Run `./setup.sh` to start dev.

