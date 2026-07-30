# .orchestrator/ State Directory

This directory holds all restart-proof state for the agent distro orchestrator. All state is JSON + Markdown on disk.

## Structure

```
.orchestrator/
├── crew/
│   ├── <worker-id>/
│   │   ├── manifest.json  # FSM state, branch, tmux, pid, task
│   │   ├── output.md      # Worker live output / report
│   │   ├── task.txt       # Task metadata (env file)
│   │   └── launch.sh      # How worker was launched (inside tmux)
│   └── .gitkeep
├── worktrees/
│   ├── <worker-id>/       # Isolated git worktrees (git worktree)
│   │   └── ...            # full checkout, worker's branch crew/<id>
│   └── .gitkeep
├── logs/
│   ├── orchestrator.log   # All events (spawn, state transitions, collect, kill)
│   ├── watcher.log        # Watcher polling results
│   └── .gitkeep
└── report.md              # Generated combined report (via collect-output.sh --report)
```

## manifest.json Schema

```json
{
  "id": "worker-1715000000-1234-a1b2",
  "task_type": "ship or scout",
  "task": "human readable task description",
  "status": "PENDING|SPAWNING|RUNNING|DONE|BLOCKED|FAILED",
  "created_at": "2025-01-01T00:00:00Z",
  "updated_at": "2025-01-01T00:01:00Z",
  "worktree_path": ".orchestrator/worktrees/worker-xxx",
  "branch": "crew/worker-xxx",
  "tmux_session": "crew-worker-xxx",
  "tmux_pane": "%0 or null",
  "adapter": "generic or claude-code",
  "pid": 12345 or null,
  "exit_code": null or int,
  "output_path": ".orchestrator/crew/worker-xxx/output.md",
  "base_ref": "HEAD"
}
```

Lifecycle: PENDING → SPAWNING → RUNNING → DONE|BLOCKED|FAILED

## output.md Protocol

Workers communicate to lead via this file.

- Append progress, logs, decisions
- Signal terminal state with HTML comment marker in file:

  - `<!-- STATUS: DONE -->`
  - `<!-- STATUS: BLOCKED -->`
  - `<!-- STATUS: FAILED -->`

Watcher polls last 200 lines for marker and updates manifest.

## Logs

All scripts use `log_event` from `scripts/common.sh` writing to `orchestrator.log`:

```
[2025-01-01T00:00:00Z] [LEVEL] [worker-id] message
```

Levels: INFO, SPAWN, STATE, RUNNING, WATCHER, COLLECT, KILL, FAIL

## Gitignore

- `worktrees/` and `logs/` are gitignored (runtime, machine-local)
- `crew/` and `report.md` may be ignored in production, but kept here for audit default .gitignore includes only worktrees/logs so manifests survive restart.

## Restart-Proof

If lead agent process dies, restart by:

```bash
./scripts/list-workers.sh
./scripts/watcher.sh --once
tmux list-sessions | grep crew-
```

Tmux sessions survive lead death (tmux server). Manifests and outputs survive. No DB needed.

## Cleanup

- After merge, remove worktree: `git worktree remove .orchestrator/worktrees/<id>`
- Delete branch: `git branch -d crew/<id>`
- Optional: keep crew dir for audit, or `rm -rf .orchestrator/crew/<id>`
- Report can be regenerated anytime

## Do Not Edit Manually (unless debugging)

- manifest.json: normally updated by scripts or worker via jq
- output.md: appended by worker
- If you must, use jq or edit carefully, keep valid JSON.

