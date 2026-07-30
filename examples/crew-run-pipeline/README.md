# Crew Run: Data Pipeline Infra Research + Sample Data + HTML Overview

This folder contains the **actual outputs from a live crew run** executed on 2026-07-30 via the agent distro orchestrator.

It demonstrates the full lifecycle: `spawn -> watcher -> collect`.

## How it was run

From repo root `/Users/ajez/AAI` (acting as lead orchestrator per `AGENTS.md`):

```bash
./setup.sh

# Parallel batch 1: research (scout) + sample data (ship)
./scripts/spawn-worker.sh --task-type scout --task "Market research on data pipeline infrastructure..." --adapter generic --id scout-pipeline-research
./scripts/spawn-worker.sh --task-type ship --task "Create sample data e-commerce..." --adapter generic --id ship-sample-data

./scripts/list-workers.sh
./scripts/watcher.sh --once
# → both RUNNING → generic adapter fallback runs codex exec → real subagents overwrite with actual research/data → DONE

# Dependent batch 2: after research DONE
./scripts/spawn-worker.sh --task-type ship --task "Build HTML overview of research..." --adapter generic --id ship-html-overview

./scripts/watcher.sh --watch
./scripts/collect-output.sh --report --merge-branches
```

All state tracked in `.orchestrator/crew/<id>/manifest.json` + `output.md` on disk (restart-proof).

## Tasks

### 1. Market Research — `01-research/`

- **ID:** `scout-pipeline-research` (scout)
- **Files:**
  - `research.md` (30k, 534 lines) — full deep dive: ingestion, storage, transformation, orchestration, observability, cost/ops team tables, build vs buy master matrix (28 rows), 4-stage evolution 0-1k → 100M+, learning ladder, anti-patterns, vendors 2026
  - `output.md` — crew output log including placeholder + real run summary, ends with `<!-- STATUS: DONE -->`
  - `manifest.json` — FSM `PENDING→SPAWNING→RUNNING→DONE`, branch `crew/scout-pipeline-research`, tmux `crew-scout-pipeline-research`

**Key thesis:** Start boring: Postgres+S3+Python+cron/Dagster+DBT+DuckDB to 1M/day. Buy connectors/warehouse/observability SaaS, build business transforms.

### 2. Sample Data — `02-sample-data/`

- **ID:** `ship-sample-data` (ship)
- **Use case:** E-commerce clickstream (view → add_to_cart → purchase funnel)
- **Files in `datasets/`:**
  - `users.json/csv` 100 users (id, email, country weighted US 31%/IN 14%, tier free/standard/premium/enterprise)
  - `products.json/csv` 50 products (8 categories, realistic price)
  - `events.jsonl/csv/json` 500 events (view 390 78%, add_to_cart 72 14.4%, purchase 38 7.6%, devices mobile 278/desktop 141/tablet 81)
  - `purchases.json/csv` 38 enriched purchases
  - `schemas.md` (7.5k) — schemas, constraints, example queries (funnel, revenue by category, LTV)
  - `README.md` (6.3k) — pipeline stages bronze→silver→gold, growable phases, how to regenerate
- **Manifest:** `ship-sample-data` DONE

This data aligns to research: files = bronze layer, easily migrated to `cat events.jsonl | kafka-console-producer`, DuckDB can read CSV directly.

### 3. HTML Overview — `03-html-overview/`

- **ID:** `ship-html-overview` (ship, dependent on research)
- **Files:**
  - `pipeline-overview.html` (64k, 791 lines) — standalone inline CSS, no external deps, responsive
    - Sticky topbar + sidebar nav with active scroll tracking
    - Hero with exec summary + 4 KPI cost cards
    - Architecture flow diagrams (div boxes with colored left border ingest/store/trans/orch/obs + arrows)
    - Build vs Buy Matrix 28 rows, interactive filter + sortable, badges build=blue/buy=green/hybrid=amber
    - Stage Evolution tabs s0-s3 with flows + graduate signals
    - Cost & Operational Overhead bars, Sample Data Use Case entity-grid (users/products/events/purchases), Recommendations, Quick-start stack $50-150/mo
  - `output.md` — log showing read research.md (534 lines) + schemas, built HTML at both worktree and root
  - `manifest.json` — DONE

Also copied to repo root as `pipeline-overview.html` for easy `open`.

## Manifest Example (DONE)

```json
{
  "id": "scout-pipeline-research",
  "task_type": "scout",
  "task": "Market research on data pipeline infrastructure...",
  "status": "DONE",
  "created_at": "2026-07-30T18:54:15Z",
  "updated_at": "2026-07-30T18:54:23Z",
  "worktree_path": "/Users/ajez/AAI/.orchestrator/worktrees/scout-pipeline-research",
  "branch": "crew/scout-pipeline-research",
  "tmux_session": "crew-scout-pipeline-research",
  "tmux_pane": "%1",
  "adapter": "generic",
  "pid": 74498,
  "exit_code": 0,
  "output_path": ".orchestrator/crew/scout-pipeline-research/output.md",
  "base_ref": "main"
}
```

## How to view

```bash
open examples/crew-run-pipeline/03-html-overview/pipeline-overview.html
# or root copy
open pipeline-overview.html

cat examples/crew-run-pipeline/01-research/research.md | head -n 100
ls examples/crew-run-pipeline/02-sample-data/datasets/
duckdb -c "SELECT event_type, COUNT(*) FROM 'examples/crew-run-pipeline/02-sample-data/datasets/events.csv' GROUP BY event_type"
```

## What this proves

- Lead agent decomposed request into parallel crew per AGENTS.md
- Worker lifecycle PENDING→RUNNING→DONE tracked via JSON+Markdown on disk (restart-proof)
- Tmux isolation: `tmux ls | grep crew-` showed 3 sessions
- Filesystem IPC: workers appended `<!-- STATUS: DONE -->` to output.md, watcher detected
- ship workers produce commits/worktrees (in this non-git demo, placeholder dir; in real git repo, `git worktree add -b crew/<id>`)
- Task 2 correctly waited for Task 1 DONE before spawning

## To reproduce

See `../demo-task.md` for step-by-step with exact commands.
