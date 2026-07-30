# Skill: Task Types - ship vs scout

Deep dive on the two supported task types.

## Overview

The orchestrator supports exactly two task types:

- **ship**: deliver code changes (branch + commits)
- **scout**: investigation reports (markdown)

This duality covers most parallel crew needs: research and delivery.

All tasks share same lifecycle PENDING→RUNNING→DONE|BLOCKED|FAILED and same filesystem protocol.

## ship

### Definition

Produce code changes that move main branch forward. Must result in commits on `crew/<worker-id>` branch.

### Agent Instructions (what worker does)

1. cd to worktree `.orchestrator/worktrees/<id>/`
2. Read task, understand acceptance criteria
3. Explore relevant files
4. Implement changes
5. Test: run repo's tests (detect: npm, make, pytest, cargo, go test, etc)
6. Commit:
   ```bash
   git add <files>
   git commit -m "crew(<id>): <summary>

   Task-Type: ship
   Worker: <id>
   ..."
   ```
7. Document in output.md: commits, files changed, test results
8. Append `<!-- STATUS: DONE -->`

### Task Description Should Include

- What to build / fix
- File paths expected
- Acceptance criteria (tests pass, specific files changed)
- Not to do (avoid scope creep)

Example good ship tasks:

- "Fix race condition in src/queue.ts: add mutex around enqueue. Add test queue.test.ts covers concurrent enqueue. Commit."
- "Implement dark mode toggle: create src/theme/ThemeContext.tsx with provider, add Toggle component src/components/ThemeToggle.tsx, update src/App.tsx to use it. Tests in src/theme/ThemeContext.test.tsx"

Example bad:

- "Fix bugs" (which bugs? where?)
- "Improve code" (how?)

### Lead Handling for Ship

- After DONE: verify commits, diff, tests
- Merge decision: merge, cherry-pick, or request changes
- Conflict handling if multiple ship workers touch same area
- Cleanup: worktree remove after merge

### Output.md Expected for Ship

```markdown
## Worker Output: worker-xyz

- Task Type: ship
- Task: ...

## Status: RUNNING

...

## Progress

- Read src/foo.ts
- Found bug at line 42
- Fixed

## Commits

- a1b2c3d - crew(worker-xyz): fix null check

## Tests

npm test passes: 42 tests

## Result: Implemented fix, verified

<!-- STATUS: DONE -->
```

## scout

### Definition

Investigation, no code delivery required (though notes allowed). Deliver report via output.md.

### Agent Instructions (scout)

1. cd to worktree (or main) - exploration only
2. Use grep, glob, read to map area
3. Document findings in output.md as markdown
4. Structure report well
5. Append `<!-- STATUS: DONE -->`

### Task Description Should Include

- What to investigate
- What report should contain (summary, file list, risks, recommendations)
- Scope (which dirs/files)
- Reference existing docs?

Example good scout tasks:

- "Investigate auth: trace from src/auth/index.ts, list middleware, how JWT validated, where session stored, entry points at src/routes/auth*. Write report with architecture diagram, file:line refs, and 3 improvement recommendations"
- "Audit test coverage for payment module: find all tests in tests/payment/*, list uncovered files, report percent estimate, suggest tests to add"

Example bad:

- "Check code" (what code? for what?)
- "Explore repo" (too broad - narrow to area)

### Report Structure Expected

```markdown
# Scout Report: <topic>

## Summary
2-3 sentences

## Files Examined
- src/foo.ts:10-50 - handles X
- src/bar.ts - Y

## Architecture / Flow
...
## Key Insights
...
## Recommendations
1. ...
2. ...

## Open Questions
...

<!-- STATUS: DONE -->
```

### Lead Handling for Scout

- No merge needed
- Summarize findings to user
- Use findings to spawn subsequent ship workers with precise tasks referencing scout report

Example: after scout auth, spawn ship workers each referencing scout output.md file path.

## Hybrid Workflows

Common pattern: scout first, then ship.

```
User: "Refactor payment module"
Lead:
  1. Spawn scout-payment to map payment module
  2. Wait DONE, read report
  3. Decompose based on report into ship tasks
  4. Spawn 3 ship workers in parallel
  5. Collect, merge
```

You can also mix: spawn 1 scout + 2 ship in parallel if ship tasks don't depend on scout.

## Choosing Task Type

| User intent | Type |
|---|---|
| Fix bug, implement feature, add tests, update docs that require commits | ship |
| Explore, understand, audit, map, list, investigate, report | scout |
| Unclear? | Ask user or default scout first to reduce risk |

## Task-Type Field in Manifest

Stored in `manifest.json` as `task_type`. Used by:

- Adapters to decide placeholder behavior in generic adapter (ship creates demo commit, scout does file listing)
- Collect to group ship vs scout for merge suggestions
- Watcher: no difference in polling, but you might prioritize ship for merging
- Report: separate sections?

## Extending (Future)

If you want custom types (e.g., "review", "bench"), you can still use ship/scout with conventions:

- review: scout that reads PR diffs
- bench: ship that writes bench files

But core system only guarantees handling of ship/scout.

## Checklist for Lead

- [ ] For each user task, decided ship vs scout?
- [ ] Task description includes file paths and acceptance criteria?
- [ ] For scout, specified report structure?
- [ ] For ship, mentioned commit and test expectations?
- [ ] Set adapter appropriately?
- [ ] If huge task, used scout leading to ship decomposition?

