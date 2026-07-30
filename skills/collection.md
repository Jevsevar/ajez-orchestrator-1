# Skill: Collection & Merging

How to gather results from completed workers and integrate code.

## Collect Script

```bash
./scripts/collect-output.sh --list
./scripts/collect-output.sh --all
./scripts/collect-output.sh --all --format markdown
./scripts/collect-output.sh --worker <id>
./scripts/collect-output.sh --status DONE
./scripts/collect-output.sh --report
./scripts/collect-output.sh --report --merge-branches
```

## What collect-output does

- Reads all `manifest.json` under `.orchestrator/crew/`
- Filters by status (DONE, BLOCKED, FAILED, RUNNING, etc)
- For each, finds `output.md` and prints
- Format options:
  - `text` (default): detailed blocks with separators
  - `markdown`: suitable for posting / report
  - `json`: machine-readable per worker
- `--report` generates `.orchestrator/report.md` with summary table + collapsible outputs

It logs to `orchestrator.log`.

## When to Collect

- Worker becomes DONE (watcher shows DONE)
- All workers in terminal state (DONE/BLOCKED/FAILED)
- User asks "what did crew find?" / "show results"
- Before merging ship workers

## Ship Workers: Integration Workflow

Ship workers have:

- Branch: `crew/<id>` (from manifest.json)
- Worktree: `.orchestrator/worktrees/<id>/`
- Commits: changes isolated

Steps to verify:

```bash
# List commits unique to worker vs main
git log --oneline crew/worker-xyz ^main

# Diff vs main
git diff main..crew/worker-xyz

# Show stats
git show --stat crew/worker-xyz

# Check status in worktree
git -C .orchestrator/worktrees/worker-xyz status

# Run tests in worktree if applicable
(cd .orchestrator/worktrees/worker-xyz && npm test || make test || pytest)
```

### Merge Strategies

1. **Fast merge if work clean and no conflicts:**
   ```bash
   git checkout main
   git merge --no-ff crew/worker-xyz
   ```

2. **Cherry-pick specific commits if worker has messy history:**
   ```bash
   git log crew/worker-xyz ^main --oneline
   git cherry-pick <sha>
   ```

3. **Review then merge via PR tooling:** keep branch for remote PR.

### Cleanup After Merge

```bash
# Remove worktree (after merge)
git worktree remove .orchestrator/worktrees/worker-xyz

# Delete branch (optional, after merge safe)
git branch -d crew/worker-xyz

# Or use kill script
./scripts/kill-worker.sh worker-xyz --remove-worktree
# But kill --remove-worktree deletes before merge! So merge first, then remove.
```

**Important**: Do NOT use kill --remove-worktree before merging, it deletes worktree and branch.

Recommended safe cleanup wrapper:

```bash
# After successful merge
git worktree remove --force .orchestrator/worktrees/<id> 2>/dev/null || rm -rf .orchestrator/worktrees/<id>
git branch -d crew/<id> 2>/dev/null || git branch -D crew/<id> 2>/dev/null || true
```

### Handling Conflicts Between Workers

If two ship workers touched same file:

- They are on separate branches from same base, so both branches may conflict with each other when merging serially.
- Strategy:
  1. Merge first worker to main
  2. Rebase second worker onto new main:
     ```bash
     git -C .orchestrator/worktrees/worker-second checkout crew/worker-second
     git -C .orchestrator/worktrees/worker-second rebase main
     # resolve conflicts inside that worktree
     git -C .orchestrator/worktrees/worker-second rebase --continue
     ```
  3. Then merge second
- Alternatively, ask one worker to fix conflict via hint file + run watcher.

Prevent via task decomposition: assign non-overlapping files.

## Scout Workers: Reporting

Scout output.md IS deliverable.

Typical scout report structure expected:

```markdown
## Summary
...
## Files Examined
- src/auth/login.ts:100-200 - ...
## Architecture Insights
...
## Recommendations
...
## Open Questions
```

Your job as lead:

- `cat .orchestrator/crew/scout-*/output.md` to read
- Summarize for user in your own response
- If you had ship workers waiting for scout findings, feed findings into their tasks when spawning

Generate report:

```bash
./scripts/collect-output.sh --report
cat .orchestrator/report.md
```

### Merge-Branches Flag

`--merge-branches` adds merge suggestions to report for ship DONE workers.

## JSON Format for Automation

```bash
./scripts/collect-output.sh --status DONE --format json > /tmp/done.json
# Each worker as JSON object
```

Useful if you want to programmatically post-process.

## Example Lead Flows

### All scout crew

```bash
./scripts/spawn-worker.sh --task-type scout --task "Explore DB layer" --id scout-db --adapter generic
./scripts/spawn-worker.sh --task-type scout --task "Explore API layer" --id scout-api --adapter generic
./scripts/watcher.sh --watch
# Wait...
./scripts/collect-output.sh --report
# Present report to user, highlight recommendations
```

### All ship crew

```bash
./scripts/spawn-worker.sh --task-type ship --task "Fix foo" --id ship-foo --adapter claude-code
./scripts/spawn-worker.sh --task-type ship --task "Fix bar" --id ship-bar --adapter claude-code
./scripts/watcher.sh --watch
# After DONE
./scripts/collect-output.sh --all --format markdown

# Verify
git diff main..crew/ship-foo
git diff main..crew/ship-bar

# Merge
git checkout main
git merge --no-ff crew/ship-foo
git merge --no-ff crew/ship-bar

# Cleanup
git worktree remove .orchestrator/worktrees/ship-foo
git worktree remove .orchestrator/worktrees/ship-bar
```

## Final Report Artifact

`.orchestrator/report.md` is gitignored (worktrees/logs ignored). But it's your handoff artifact.

If user asks for final deliverable: generate report + list merged branches + show diff stat.

## Checklist

- [ ] watcher --once confirmed DONE before collecting?
- [ ] Used --list to see all workers?
- [ ] For ship: showed git log and diff?
- [ ] For scout: summarized findings, not just raw output?
- [ ] Merge order considered for conflict?
- [ ] Cleanup worktrees after merge?
- [ ] Report generated via --report?
- [ ] User sees final summary?

