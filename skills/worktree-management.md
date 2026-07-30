# Skill: Worktree Management

How git worktrees provide isolation for crew workers.

## Why Worktrees

- Isolated filesystem: each worker has own checkout at `.orchestrator/worktrees/<id>/`
- Isolated branch: `crew/<id>` from base
- Safe parallelism: workers don't step on each other's uncommitted changes
- Main branch untouched until you merge
- `git worktree list` shows all

## Worktree Lifecycle

### Creation (by spawn-worker.sh)

```bash
git worktree add -b crew/<id> .orchestrator/worktrees/<id> HEAD
```

- Base defaults to HEAD, or --base-branch if given
- Branch name: `crew/<worker-id>`
- Path: `.orchestrator/worktrees/<id>/`
- If not in git repo: fallback to plain directory mkdir (no isolation but still works for demo)

### During Work

Worker:

- `cd .orchestrator/worktrees/<id>/`
- `git status`, `git add`, `git commit`
- Commits stay on `crew/<id>` branch
- Not pushed

Lead can inspect:

```bash
git -C .orchestrator/worktrees/<id> status
git -C .orchestrator/worktrees/<id> log --oneline -10
git -C .orchestrator/worktrees/<id> diff
git log --oneline crew/<id> ^main
```

### Merging

After worker DONE and you verified:

Option A: merge to main

```bash
git checkout main
git merge --no-ff crew/<id>
```

Option B: cherry-pick

```bash
git log crew/<id> ^main --oneline
git cherry-pick <sha>
```

Option C: interactive review via PR tooling - push crew branch to remote? But spec says do NOT push automatically. If you want PR, push manually:

```bash
git push origin crew/<id>
```

### Cleanup

After merge:

```bash
git worktree remove .orchestrator/worktrees/<id>
git branch -d crew/<id>   # or -D if not merged
```

Our helper:

```bash
./scripts/kill-worker.sh <id> --remove-worktree --force-failed
# Note: this removes BEFORE merge, so only use after merge or if abandoning
```

Safe post-merge cleanup snippet lead should use:

```bash
git worktree remove --force .orchestrator/worktrees/<id> 2>/dev/null || rm -rf .orchestrator/worktrees/<id>
git branch -d crew/<id> 2>/dev/null || git branch -D crew/<id> 2>/dev/null || true
rm -rf .orchestrator/crew/<id>   # optional, removes manifest and output (archives result)
```

We generally keep crew manifest+output even after merge for audit, but worktrees are safe to delete.

## List All Worktrees

```bash
git worktree list
```

Shows:

```
<root>              abcd123 [main]
.orchestrator/worktrees/worker-1  efgh456 [crew/worker-1]
...
```

## Troubleshooting

### Worktree creation fails "branch already exists"

Branch leftover from previous run:

```bash
git branch -D crew/<id>
git worktree remove --force .orchestrator/worktrees/<id> || rm -rf ...
```

Then respawn.

### Worktree path exists but git worktree list doesn't show

Orphan directory: `rm -rf .orchestrator/worktrees/<id>`

### Worktree dirty or main has uncommitted changes

git worktree add uses HEAD, so uncommitted changes in main stay in main, NOT in worktree. Worktree gets HEAD commit, clean. It's okay. But if main has uncommitted changes you wanted to include, commit first.

### Basing off specific branch

```bash
./scripts/spawn-worker.sh --task-type ship --task "..." --base-branch develop
```

Use when main is behind.

### Non-git mode

If repo not git (e.g., demo), spawn creates plain dir at `.orchestrator/worktrees/<id>/`. No branch isolation, but still directory isolation. Merging meaningless then. Tasks should be scout.

## Gitignore

`.orchestrator/worktrees/` and `.orchestrator/logs/` are gitignored.

Crew manifests (`crew/*/manifest.json`, `output.md`) are NOT ignored by default - you may want to keep them for restart-proof audit, or ignore them in production by adding to .gitignore.

## Security

- Workers should NOT push: enforce via prompt: "Do NOT run git push"
- Workers should NOT edit outside worktree: prompt says work only inside worktree
- Lead's setup.sh does NOT set up hooks, but could add pre-push hook to block crew/* push if needed future

## Lead Checklist

- [ ] Setup ensured git repo?
- [ ] Worktree creation succeeded (not placeholder)?
- [ ] Used --base-branch appropriately?
- [ ] After ship DONE, inspected log and diff before merge?
- [ ] Applied merge in correct order to minimize conflicts?
- [ ] Cleaned up worktrees after merge?
- [ ] Did NOT delete worktree before merge if you still need branch?

## Quick Reference Commands

```bash
# Create manually (if debug)
git worktree add -b crew/debug .orchestrator/worktrees/debug HEAD

# List
git worktree list
ls .orchestrator/worktrees/

# Inspect
git -C .orchestrator/worktrees/<id> status
git log crew/<id> ^main --oneline --graph

# Diff vs main
git diff main..crew/<id>
git diff main..crew/<id> --stat

# Merge
git checkout main && git merge --no-ff crew/<id>

# Cleanup
git worktree remove .orchestrator/worktrees/<id>
git branch -d crew/<id>
```

