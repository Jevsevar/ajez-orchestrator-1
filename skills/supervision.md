# Skill: Supervision

How to monitor, debug, and recover crew workers.

## Watcher Script

```bash
./scripts/watcher.sh --once
./scripts/watcher.sh --watch --interval 5
```

Watcher does:

1. List all `manifest.json` under `.orchestrator/crew/`
2. For each, check:
   - tmux session alive? `tmux has-session -t crew-<id>`
   - output.md status marker? Looks for `<!-- STATUS: DONE|BLOCKED|FAILED -->` in last 200 lines
   - If output says DONE/BLOCKED/FAILED → transition manifest status
   - If tmux dead + no DONE marker → FAILED (or DONE if auto-completed placeholder)
3. Logs to `.orchestrator/logs/watcher.log` + orchestrator.log
4. Prints summary table

## When to Poll

- Immediately after spawn: confirm RUNNING
- Every 30-60 seconds for long tasks, or use --watch in dedicated pane
- Before collect: ensure status up-to-date
- When user asks "how are workers doing?" -> run watcher --once + list-workers

## Reading Worker Progress

- Output file: `.orchestrator/crew/<id>/output.md` is live log
- Launch script: `.orchestrator/crew/<id>/launch.sh` shows how adapter started
- Worktree: `.orchestrator/worktrees/<id>/` - check git status, commits
- Manifest: read JSON for structured status

```bash
cat .orchestrator/crew/<id>/output.md
cat .orchestrator/crew/<id>/manifest.json | jq .
git -C .orchestrator/worktrees/<id> log --oneline -5
git -C .orchestrator/worktrees/<id> status
tmux capture-pane -t crew-<id> -p | tail -n 100
```

## Handling BLOCKED

Worker signals BLOCKED when:

- Needs clarification
- Missing dependency
- Can't find file, ambiguous requirement

Steps:

1. Read output.md: `cat .orchestrator/crew/<id>/output.md | tail -n 100`
2. Understand blocker
3. Options:
   - **Hint file**: create `LEAD_HINT.md` in its worktree with clarification, then notify tmux:
     ```bash
     echo "Clarification: do X" > .orchestrator/worktrees/<id>/LEAD_HINT.md
     tmux send-keys -t crew-<id> "Read LEAD_HINT.md" Enter
     ```
   - **Direct tmux message**: `tmux send-keys -t crew-<id> "Use approach B" Enter`
   - **Update task.txt** with more info + re-prompt
   - **Kill & respawn** with improved description if task was flawed
   - **Ask user** if blocker requires human decision

4. After unblocking, monitor: `watcher.sh --once` should still show RUNNING until worker marks DONE
5. If worker created unblock note but forgot to remove BLOCKED marker? It should append new DONE marker. Last marker wins in our watcher (we scan tail). Best practice: worker appends DONE after BLOCKED resolved.

## Handling FAILED

Failure reasons:

- Worktree creation failed (branch exists, dirty HEAD)
- tmux session died (panic, machine reboot, adapter error)
- Adapter exited non-zero without DONE marker

Recovery:

1. Read logs:
   ```bash
   cat .orchestrator/crew/<id>/output.md
   cat .orchestrator/logs/orchestrator.log | grep <id>
   tmux capture-pane? But pane dead.
   ```
2. Check worktree still exists: `ls .orchestrator/worktrees/<id>` and `git worktree list`
3. Decisions:
   - Retry same task: kill old + respawn
   - Retry with fix: adjust task, base-branch
   - Abandon: leave FAILED and move on

Kill and retry:
```bash
./scripts/kill-worker.sh <id> --remove-worktree --force-failed
./scripts/spawn-worker.sh --task-type ship --task "improved description" --id <id>-retry
```

## Heartbeat and Restart-Proof

All state is JSON + md files. If your own session dies (you are lead agent and you crash), you can restart:

- State persists in `.orchestrator/`
- Run `./scripts/list-workers.sh` to recover
- Run `./scripts/watcher.sh --once` to sync tmux liveness
- tmux sessions may still be alive even if you died - they are managed by tmux server
- Re-attach: `tmux attach -t crew-<id>`

This is restart-proof design.

## Tmux Tips

- List crew sessions: `tmux list-sessions | grep crew-`
- Attach: `tmux attach -t crew-<id>`
- Detach: Ctrl+b then d
- Capture pane without attach: `tmux capture-pane -t crew-<id> -p`
- Send keys: `tmux send-keys -t crew-<id> "ls" Enter`
- Kill: `tmux kill-session -t crew-<id>` or via `kill-worker.sh`

## List Workers

```bash
./scripts/list-workers.sh
# Output:
# ID TYPE STATUS TMUX PID TASK
```

Shows live/dead tmux, PID, etc.

## Event Logs

- `orchesrator.log`: all spawn, state transitions, collect, kill
- `watcher.log`: watcher polling results

Format:
```
[2025-...] [LEVEL] [worker-id] message
```

Check last events:
```bash
tail -n 50 .orchestrator/logs/orchestrator.log
tail -n 100 .orchestrator/logs/watcher.log
```

## Lead Agent Supervision Loop (Pseudo)

```
while tasks not complete:
  watcher --once
  list-workers
  for each worker:
    read output.md tail
    if DONE: collect-output --worker <id> (show user)
    if BLOCKED: handle per above
    if FAILED: log, decide retry
    if RUNNING && no progress for long time: check tmux capture-pane, maybe nudge
  sleep / wait
  collect --report when all done
```

## When to Escalate to User

- Worker BLOCKED needs product decision
- Multiple workers FAILED same reason -> systemic issue (git, tmux, adapter missing)
- Task ambiguous even after your decomposition
- Ship workers conflict (modify same file) - you must coordinate merging order

## Checklist

- [ ] watcher --once after spawn?
- [ ] Checked output.md tail for progress?
- [ ] Monitored tmux alive status?
- [ ] Handled BLOCKED/FALED quickly (not ignored)?
- [ ] Logs checked for errors?
- [ ] User informed of status regularly (list-workers output)?

