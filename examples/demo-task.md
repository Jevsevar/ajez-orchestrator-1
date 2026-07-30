# Demo: Parallel Crew on a Sample Repo

This walkthrough shows a **concrete** end-to-end scenario: spawning 3 workers in parallel on a sample repo, supervising them via filesystem, and collecting/merging results.

You can copy-paste every command.

---

## 0. Prerequisites

```bash
# Required
which tmux  # should print /opt/homebrew/bin/tmux or similar, tmux 3.x
which git   # git 2.5+
which bash  # bash 4+
# Optional but recommended
which jq    # for pretty JSON
which claude # if you want claude-code adapter, else generic works

# Ensure tmux server will auto-start (handled by spawn-worker.sh)
tmux --version
```

If missing: `brew install tmux jq` or `apt install tmux jq`.

---

## 1. Create a Sample Repo (Todo API)

We create a minimal repo to simulate real work. You can also use your own codebase — the distro works anywhere.

```bash
mkdir -p /tmp/demo-todo && cd /tmp/demo-todo
git init -b main
git config user.email "demo@agent-distro.test"
git config user.name "Demo"

cat > README.md <<'MD'
# Demo Todo API
Simple in-memory todo.

- src/todo.js - core logic
- src/auth.js - auth placeholder
- tests/
MD

mkdir -p src tests

cat > src/todo.js <<'JS'
let todos = [];
export function addTodo(text) {
  if (!text) throw new Error("text required");
  todos.push({ id: Date.now(), text, done: false });
}
export function listTodos() { return todos; }
export function clear() { todos = []; }
JS

cat > src/auth.js <<'JS'
// Auth placeholder - currently no validation
export function isAuthenticated(req) {
  return true; // TODO: real JWT check
}
JS

cat > package.json <<'JSON'
{
  "name": "demo-todo",
  "scripts": { "test": "node --test tests/*.test.js || echo no tests yet" }
}
JSON

cat > tests/todo.test.js <<'JS'
import { addTodo, listTodos, clear } from '../src/todo.js';
import test from 'node:test';
import assert from 'node:assert';
test('add todo', () => {
  clear();
  addTodo('buy milk');
  assert.equal(listTodos().length, 1);
});
JS

# Install agent distro scaffolding into this sample repo
cp -r /path/to/agent-distro/scripts .
cp -r /path/to/agent-distro/adapters .
cp -r /path/to/agent-distro/skills .
cp -r /path/to/agent-distro/.orchestrator .
cp /path/to/agent-distro/setup.sh /path/to/agent-distro/AGENTS.md /path/to/agent-distro/.gitignore .
# If you are already inside the agent-distro repo cloned from GitHub, just:
# cd /tmp/demo-todo
# git clone https://github.com/your-org/agent-distro.git --depth 1 /tmp/agent-distro-src
# cp -r /tmp/agent-distro-src/scripts /tmp/agent-distro-src/adapters /tmp/agent-distro-src/skills /tmp/agent-distro-src/.orchestrator /tmp/agent-distro-src/setup.sh /tmp/agent-distro-src/AGENTS.md /tmp/agent-distro-src/.gitignore .

git add . && git commit -m "init: demo todo api + agent distro"

# Validate
./setup.sh
# Expected: all [ok], Creates .orchestrator/crew, logs, worktrees
```

**Resulting sample repo structure:**
```
demo-todo/
├── src/todo.js
├── src/auth.js
├── tests/todo.test.js
├── scripts/spawn-worker.sh, watcher.sh, collect-output.sh, etc
├── adapters/generic.sh, claude-code.sh
├── .orchestrator/
├── setup.sh
└── AGENTS.md
```

---

## 2. Decompose Into 3 Parallel Tasks

User story: *"Harden auth, add delete feature, and audit test coverage"*

We decompose:

1. **scout-auth** (type: scout) — Map auth flow, list files, JWT risks, report
2. **ship-delete** (type: ship) — Implement `deleteTodo(id)` in src/todo.js + test + commit
3. **ship-docs** (type: ship) — Update README.md with API docs + add JSDoc comments to src/auth.js, commit

These are independent → can run in parallel.

---

## 3. Spawn 3 Workers

**Exact commands:**

```bash
cd /tmp/demo-todo

# 1. Scout auth
./scripts/spawn-worker.sh \
  --task-type scout \
  --task "Investigate auth layer: read src/auth.js, grep for isAuthenticated usages, list middleware, check JWT validation, write report with file:line refs and 3 hardening recommendations. Report structure: Summary, Files Examined, Risks, Recommendations" \
  --adapter generic \
  --id scout-auth

# 2. Ship delete feature
./scripts/spawn-worker.sh \
  --task-type ship \
  --task "Implement deleteTodo(id) in src/todo.js: remove todo by id, return true if removed else false. Add test in tests/todo.test.js covering delete existing and non-existing id. Run npm test. Commit with git add src/todo.js tests/todo.test.js and git commit -m 'crew(delete): add deleteTodo'" \
  --adapter generic \
  --id ship-delete-todo

# 3. Ship docs
./scripts/spawn-worker.sh \
  --task-type ship \
  --task "Update docs: expand README.md with API table for addTodo, listTodos, deleteTodo (once exists), clear, isAuthenticated. Add JSDoc to src/auth.js explaining isAuthenticated and TODO. Commit README.md and src/auth.js" \
  --adapter generic \
  --id ship-docs

# If repo is dirty, add --allow-dirty to each, or commit first
```

**Expected output per spawn:**
```
=== Worker Spawned ===
ID: scout-auth
Type: scout
Adapter: generic
Worktree: /tmp/demo-todo/.orchestrator/worktrees/scout-auth
Branch: crew/scout-auth
Tmux: crew-scout-auth
Manifest: /tmp/demo-todo/.orchestrator/crew/scout-auth/manifest.json
Output: /tmp/demo-todo/.orchestrator/crew/scout-auth/output.md

Attach: tmux attach -t crew-scout-auth
```

**After spawning, check filesystem state:**

```bash
ls .orchestrator/crew/
# scout-auth/  ship-delete-todo/  ship-docs/  .gitkeep

cat .orchestrator/crew/scout-auth/manifest.json
```

**Expected initial manifest (PENDING → quickly RUNNING):**

```json
{
  "id": "scout-auth",
  "task_type": "scout",
  "task": "Investigate auth layer: read src/auth.js, grep for isAuthenticated usages...",
  "status": "PENDING",
  "created_at": "2026-07-30T12:00:00Z",
  "updated_at": "2026-07-30T12:00:00Z",
  "worktree_path": "/tmp/demo-todo/.orchestrator/worktrees/scout-auth",
  "branch": "crew/scout-auth",
  "tmux_session": "crew-scout-auth",
  "tmux_pane": null,
  "adapter": "generic",
  "pid": null,
  "exit_code": null,
  "output_path": ".orchestrator/crew/scout-auth/output.md",
  "base_ref": "HEAD"
}
```

After 0.5s, watcher transitions to:

```json
{
  "id": "scout-auth",
  "task_type": "scout",
  "status": "RUNNING",
  "tmux_session": "crew-scout-auth",
  "tmux_pane": "%0",
  "pid": 12345,
  ...
}
```

**Expected output.md header (created by spawn-worker.sh, before worker logs):**

```markdown
# Worker Output: scout-auth

- **Task Type:** scout
- **Task:** Investigate auth layer: read src/auth.js...
- **Adapter:** generic
- **Created:** 2026-07-30T12:00:00Z
- **Worktree:** /tmp/demo-todo/.orchestrator/worktrees/scout-auth
- **Branch:** crew/scout-auth
- **Session:** crew-scout-auth

## Status: RUNNING
Worker is starting...

## Task Details
> Investigate auth layer: ...

## Work Log
```

**Expected worktree:**

```bash
git worktree list
# /tmp/demo-todo                      abcd123 [main]
# /tmp/demo-todo/.orchestrator/worktrees/scout-auth       efgh456 [crew/scout-auth]
# /tmp/demo-todo/.orchestrator/worktrees/ship-delete-todo efgh457 [crew/ship-delete-todo]
# /tmp/demo-todo/.orchestrator/worktrees/ship-docs        efgh458 [crew/ship-docs]

ls .orchestrator/worktrees/scout-auth/src/
# auth.js  todo.js
cat .orchestrator/worktrees/scout-auth/PROMPT.md | head -n 20
```

---

## 4. Monitor Workers

**Poll once:**

```bash
./scripts/watcher.sh --once
```

**Expected output while RUNNING:**

```
[watcher] Mode: once interval: 5s crew_dir: /tmp/demo-todo/.orchestrator/crew
[watcher] scout-auth                   status=RUNNING  tmux=alive  file=RUNNING -> RUNNING  (none)
[watcher] ship-delete-todo             status=RUNNING  tmux=alive  file=RUNNING -> RUNNING  (none)
[watcher] ship-docs                    status=RUNNING  tmux=alive  file=RUNNING -> RUNNING  (none)
--- Summary: total=3 running=3 pending=0 done=0 blocked=0 failed=0 ---
```

**Table view:**

```bash
./scripts/list-workers.sh
```

```
ID                               TYPE  STATUS    TMUX    PID    TASK
-------------------------------- ----- --------- ------- ------ ----
scout-auth                       scout RUNNING   alive   12345  Investigate auth layer: read src/auth.js...
ship-delete-todo                 ship  RUNNING   alive   12346  Implement deleteTodo(id) in src/todo.js...
ship-docs                        ship  RUNNING   alive   12347  Update docs: expand README.md...
Total: 3 workers
```

**Live logs:**

```bash
tail -f .orchestrator/logs/orchestrator.log
tail -f .orchestrator/logs/watcher.log
cat .orchestrator/crew/ship-delete-todo/output.md
tmux capture-pane -t crew-ship-delete-todo -p | tail -n 100
# or attach interactively
tmux attach -t crew-ship-delete-todo
# detach: Ctrl+b then d
```

**Continuous watch (run in separate terminal pane):**

```bash
./scripts/watcher.sh --watch --interval 3
```

**What generic adapter does in this demo (since no real agent CLI):**

- **scout-auth**: lists top-level files, `git status`, writes placeholder findings then `<!-- STATUS: DONE -->`
- **ship-delete-todo**: creates `WORKER_ship-delete-todo.md` and commits as demo — in production with `claude` or `codex` CLI, it would actually implement `deleteTodo`

In this demo run with `generic`, expect after ~5-15 seconds (or immediate for placeholder):

```
[watcher] scout-auth                   status=RUNNING  tmux=alive  file=DONE    -> DONE     (completed)
[watcher] Transition scout-auth: RUNNING -> DONE (completed)
...
--- Summary: total=3 running=0 pending=0 done=3 blocked=0 failed=0 ---
```

**If using `claude-code` adapter (requires `claude` CLI in PATH):**

```bash
./scripts/spawn-worker.sh --task-type ship --task "Implement deleteTodo..." --adapter claude-code --id ship-delete-real
# Worker pane will auto-run `claude --print` with CLAUDE_TASK.md
```

For `claude-code`, the worktree will have `CLAUDE_TASK.md` containing full task context, and the worker will actually edit `src/todo.js` and commit.

---

## 5. Expected DONE State Files

**Manifest after DONE (example for ship-delete-todo):**

```json
{
  "id": "ship-delete-todo",
  "task_type": "ship",
  "task": "Implement deleteTodo(id) in src/todo.js...",
  "status": "DONE",
  "created_at": "2026-07-30T12:00:00Z",
  "updated_at": "2026-07-30T12:00:05Z",
  "worktree_path": "/tmp/demo-todo/.orchestrator/worktrees/ship-delete-todo",
  "branch": "crew/ship-delete-todo",
  "tmux_session": "crew-ship-delete-todo",
  "tmux_pane": "%0",
  "adapter": "generic",
  "pid": 12346,
  "exit_code": 0,
  "output_path": ".orchestrator/crew/ship-delete-todo/output.md",
  "base_ref": "HEAD"
}
```

**output.md after DONE (scout example):**

```markdown
# Worker Output: scout-auth
...
## Work Log

[worker scout-auth] Starting adapter generic
...

## Adapter: generic
...

## Simulated Scout Work

Task: Investigate auth layer...

### File structure (top level):
```
total 16
...
src/auth.js
src/todo.js
```

### Git status:
```
On branch crew/scout-auth
...
```

### Findings (auto-generated placeholder)

- Searched files via ls, git
- Task was: Investigate auth layer...

<!-- STATUS: DONE -->
```

**output.md after DONE (real claude-code ship example):**

```markdown
## Progress
- Read src/todo.js, found todos array
- Implemented deleteTodo
- Added test, ran npm test: 2 passing

## Commits
- a1b2c3d crew(ship-delete-todo): add deleteTodo with tests

## Tests
npm test: 2 passing

## Result: Implemented deleteTodo(id) returning boolean, added tests

<!-- STATUS: DONE -->
```

**Worktree diff for ship worker:**

```bash
git -C .orchestrator/worktrees/ship-delete-todo log --oneline crew/ship-delete-todo ^main
# a1b2c3d crew(ship-delete-todo): add deleteTodo with tests

git diff main..crew/ship-delete-todo --stat
#  src/todo.js              | 8 ++++++++
#  tests/todo.test.js       | 12 ++++++++++++
#  2 files changed, 20 insertions(+)

git show crew/ship-delete-todo --stat
```

**If worker BLOCKED (example):**

```markdown
## Blocked
Need clarification: should deleteTodo throw if id not found or return false?

<!-- STATUS: BLOCKED -->
```

Then watcher will mark `BLOCKED`, and you unblock via:

```bash
echo "Return false, don't throw" > .orchestrator/worktrees/ship-delete-todo/LEAD_HINT.md
tmux send-keys -t crew-ship-delete-todo "Read LEAD_HINT.md" Enter
```

**If FAILED (tmux died, no marker):**

Manifest stays `RUNNING` until watcher sees tmux dead → `FAILED` with `exit_code: 1`.

---

## 6. Collect Results

```bash
# List
./scripts/collect-output.sh --list

# All terminal workers as markdown
./scripts/collect-output.sh --all --format markdown

# Single worker
./scripts/collect-output.sh --worker scout-auth --format markdown

# Generate combined report
./scripts/collect-output.sh --report
cat .orchestrator/report.md
```

**Expected report.md (generated):**

```markdown
# Crew Report
Generated: 2026-07-30T12:05:00Z
Root: /tmp/demo-todo

## Summary

| Worker ID | Type | Status | Branch | Task |
|---|---|---|---|---|
| scout-auth | scout | DONE | crew/scout-auth | Investigate auth layer: read src/auth.js... |
| ship-delete-todo | ship | DONE | crew/ship-delete-todo | Implement deleteTodo(id) in src/todo.js... |
| ship-docs | ship | DONE | crew/ship-docs | Update docs: expand README.md... |

## Worker Details

### scout-auth (DONE)
- **Type:** scout
- **Task:** Investigate auth layer...
- **Branch:** `crew/scout-auth`
- **Worktree:** `/tmp/demo-todo/.orchestrator/worktrees/scout-auth`

<details>
<summary>Output (click to expand)</summary>

```markdown
# Worker Output: scout-auth
...
```
</details>

### ship-delete-todo (DONE)
...
**Merge suggestion:**
```bash
git log --oneline crew/ship-delete-todo ^main
git merge --no-ff crew/ship-delete-todo
git worktree remove .orchestrator/worktrees/ship-delete-todo
```

## Merge Commands for ship workers
...
```

**With merge hints:**

```bash
./scripts/collect-output.sh --report --merge-branches
```

---

## 7. Merge Ship Workers

Check diffs first:

```bash
git log --oneline crew/ship-delete-todo ^main
git diff main..crew/ship-delete-todo

git log --oneline crew/ship-docs ^main
git diff main..crew/ship-docs

# If they touch same file, merge one, rebase the other:
git checkout main
git merge --no-ff crew/ship-delete-todo   # first
# second may conflict - rebase it:
git -C .orchestrator/worktrees/ship-docs checkout crew/ship-docs
git -C .orchestrator/worktrees/ship-docs rebase main
# resolve conflicts in that worktree, then
git -C .orchestrator/worktrees/ship-docs rebase --continue
git checkout main
git merge --no-ff crew/ship-docs

# Verify
npm test
cat README.md
```

**Cleanup after merge:**

```bash
# Safe cleanup (merge first, then remove)
git worktree remove .orchestrator/worktrees/scout-auth
git worktree remove .orchestrator/worktrees/ship-delete-todo
git worktree remove .orchestrator/worktrees/ship-docs

git branch -d crew/scout-auth
git branch -d crew/ship-delete-todo
git branch -d crew/ship-docs

# Keep crew output for audit, or:
rm -rf .orchestrator/crew/scout-auth .orchestrator/crew/ship-delete-todo .orchestrator/crew/ship-docs
# Keep .gitkeep
touch .orchestrator/crew/.gitkeep

# Or use helper (removes worktree+branch BEFORE merge - only for abandoned):
./scripts/kill-worker.sh ship-delete-todo --remove-worktree --force-failed
```

---

## 8. End-to-End One-Liner for CI / Smoke Test

```bash
./scripts/smoke-test.sh
# Runs: clean, spawn scout, wait DONE, watcher, collect, ship, parallel, BLOCKED detection, cleanup
# => === All Smoke Tests Passed ===
```

We also tested this distro with real `codex` CLI (Meta's wrapper): `codex exec` actually implemented `deleteTodo` and committed.

---

## 9. Troubleshooting During Demo

| Symptom | Diagnose | Fix |
|---|---|---|
| `tmux NOT found` | `which tmux` | `brew install tmux` |
| `Git repo is not clean` | `git status --porcelain` | `git commit -A` or `--allow-dirty` |
| `Worker directory already exists` | `ls .orchestrator/crew/` | `rm -rf .orchestrator/crew/<id> .orchestrator/worktrees/<id>; git branch -D crew/<id>` or `--force` |
| `Branch already exists` | `git branch \| grep crew/` | `git branch -D crew/<id>` |
| `Tmux session already exists` | `tmux ls | grep crew-` | `tmux kill-session -t crew-<id>` or `--force` |
| Worker stuck `RUNNING` no output | `tmux capture-pane -t crew-<id> -p` | Check adapter logs, `cat .orchestrator/crew/<id>/output.md`, send hint via `tmux send-keys` |
| Worktree creation fails `no HEAD` | `git log --oneline` empty | `git add . && git commit -m init` |
| Generic adapter shows placeholder only | Expected without real agent CLI | Install `claude` CLI and use `--adapter claude-code`, or ensure your agent CLI in PATH |

Logs:
```bash
tail -f .orchestrator/logs/orchestrator.log
tail -f .orchestrator/logs/watcher.log
cat .orchestrator/logs/orchestrator.log | grep FAIL
```

---

## 10. What You Learned

- **Lead agent** (you) decomposes task → spawns crew with `spawn-worker.sh`
- Each worker gets **isolated git worktree** + **tmux session** + **adapter**
- Communication via **filesystem**: `PROMPT.md` / `CLAUDE_TASK.md` (lead→worker) and `output.md` + `<!-- STATUS: DONE -->` (worker→lead)
- **watcher.sh** polls `tmux alive?` + `output.md` marker → updates `manifest.json` lifecycle `PENDING→SPAWNING→RUNNING→DONE|BLOCKED|FAILED`
- **collect-output.sh** gathers outputs, generates `report.md`, suggests merge commands
- **Restart-proof**: all JSON+Markdown on disk; `tmux list-sessions` + `list-workers.sh` recover after crash
- Works with **any** terminal agent via adapter contract

Now swap in your own sample repo and tasks — same commands work.
