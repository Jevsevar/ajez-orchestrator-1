# Skill: Spawning Workers

How to effectively spawn crew workers.

## When to Spawn

- User explicitly asks for crew / parallel work
- Large task can be decomposed into independent subtasks
- User asks for investigation + implementation (scout then ship)
- You need multiple attempts / variants

## Pre-flight

Always check:
```bash
./setup.sh
ls .orchestrator/crew/
command -v tmux; command -v git
```

## Spawn Script Contract

```bash
./scripts/spawn-worker.sh \
  --task-type ship|scout \
  --task "precise description" \
  --adapter generic|claude-code \
  [--id custom-id] \
  [--base-branch main] \
  [--dry-run]
```

## Task Description Best Practices

**Good (precise, actionable):**
- scout: "Investigate auth flow: trace from src/auth/login.ts entry point, list middleware, document how JWT is validated, include file:line refs"
- ship: "Fix null check in src/user.ts line 42: add early return if user is null before accessing user.name, add test in tests/user.test.ts"

**Bad (vague):**
- "Fix bug"
- "Investigate codebase"

**Include:**
- File paths
- Expected outcome
- Acceptance criteria for ship (tests, commits)
- For scout, what report should contain

## Adapter Choice

- `generic`: default, works always. Falls back to placeholder demo if no real agent CLI.
- `claude-code`: use if `claude` CLI present or user says they use Claude Code.

Detect: `which claude` or ask user.

## Parallelism Limits

- Default max 3-5 concurrent workers. More can overwhelm machine / git.
- For large decomposition (say 10 tasks), spawn in batches: 3 now, collect, then next 3.
- Mention to user: "Spawning batch 1/3"

## ID Generation

Auto-generated IDs look like: `worker-1714567890-1234-a1b2`
- Use custom IDs for clarity: `worker-auth-fix`, `worker-scout-db`
- Must be unique. If exists, spawn fails - use kill-worker to cleanup or different id.

## Base Branch

- Default: HEAD. Workers branch from HEAD.
- If HEAD is dirty or has uncommitted changes? Worktree creation may warn but usually works. Prefer committing before spawning or using --base-branch main.
- For stacks: earlier workers merge to main, later workers branch from updated main.

## Dry Run

Use `--dry-run` to preview manifest and paths without actually creating worktree/tmux.

## Post-Spawn

Immediately after spawn:

```bash
./scripts/watcher.sh --once
./scripts/list-workers.sh
```

Confirm:
- manifest exists at `.orchestrator/crew/<id>/manifest.json`
- status is SPAWNING or RUNNING (not FAILED)
- tmux session alive: `tmux has-session -t crew-<id>`
- worktree exists: `ls .orchestrator/worktrees/<id>`

If FAILED: check `.orchestrator/logs/orchestrator.log`, read output.md, retry.

## Example: Decomposing Feature

User: "Add dark mode toggle"

Decompose:
1. scout: "Explore UI structure, theming, where preferences stored. List components needing dark mode support"
2. ship: "Implement theme context/provider in src/theme/ with localStorage persist"
3. ship: "Add dark mode styles, update components to use theme tokens"
4. ship: "Add toggle UI in settings page src/pages/Settings.tsx"
5. ship: "Add tests for theme logic in tests/theme.test.ts"

Spawn order: start with scout, wait for findings, then spawn ship workers with scout insights in their task descriptions (include key files).

## Example Commands

```bash
# Scout first
./scripts/spawn-worker.sh --task-type scout --task "Map theme system: find all css, js theming logic, list components using colors. Files: src/styles, src/components, src/context" --adapter generic --id scout-theme

./scripts/watcher.sh --wait-il? Actually --watch
# Wait for DONE, cat output

# Then ship in parallel
./scripts/spawn-worker.sh --task-type ship --task "Implement ThemeContext in src/theme/context.tsx - see scout findings in .orchestrator/crew/scout-theme/output.md - provide light/dark tokens" --adapter generic --id ship-context
./scripts/spawn-worker.sh --task-type ship --task "Add ToggleTheme component in src/components/ToggleTheme.tsx using ThemeContext" --adapter generic --id ship-toggle
```

## Troubleshooting Spawn Failures

- "Worktree exists": `ls .orchestrator/worktrees/` + `git worktree list` + cleanup via kill-worker --remove-worktree
- "Branch already exists": `git branch -D crew/<id>`
- "tmux failed": is tmux server running? `tmux list-sessions`
- "Not a git repo": Run `git init` and commit, or use placeholder dir mode (still works but no isolation).

## Logging

All spawns log to `.orchestrator/logs/orchestrator.log` via `log_event`

Check after spawn: `tail -n 20 .orchestrator/logs/orchestrator.log`

## Your Checklist as Lead

- [ ] Task decomposed?
- [ ] Task descriptions precise?
- [ ] Correct task-type ship/scout?
- [ ] Adapter chosen based on available CLI?
- [ ] IDs unique and meaningful?
- [ ] Dry-run for first worker if uncertain?
- [ ] Post-spawn watcher --once + list-workers?

