# Worker Output: scout-pipeline-research

- **Task Type:** scout
- **Task:** Market research on data pipeline infrastructure for a small project that could grow: what solutions should be built manually vs plug-and-play. Cover ingestion, storage, transformation, orchestration, observability, cost, scalability. Deliver markdown report with build-vs-buy matrix
- **Adapter:** generic
- **Created:** 2026-07-30T18:54:15Z
- **Worktree:** /Users/ajez/AAI/.orchestrator/worktrees/scout-pipeline-research
- **Branch:** crew/scout-pipeline-research
- **Session:** crew-scout-pipeline-research

## Status: RUNNING

Worker is starting...

## Task Details

> Market research on data pipeline infrastructure for a small project that could grow: what solutions should be built manually vs plug-and-play. Cover ingestion, storage, transformation, orchestration, observability, cost, scalability. Deliver markdown report with build-vs-buy matrix

## Instructions for Worker Agent

You are worker **scout-pipeline-research**.

- Your worktree is at `/Users/ajez/AAI/.orchestrator/worktrees/scout-pipeline-research`
- Task type: **scout**
- Signal completion by appending status markers to this file (see PROMPT.md for exact syntax):
  - DONE: append marker for DONE plus section ## Result: <summary>
  - BLOCKED: append marker for BLOCKED plus ## Blocked: <reason>
  - FAILED: append marker for FAILED plus ## Failed: <reason>
  Exact marker syntax is defined in PROMPT.md / CLAUDE_TASK.md in your worktree.
  Do NOT copy from this output header - read worktree prompt file for precise marker to append.

- For ship tasks, create commits in your worktree.
- For scout tasks, write findings in this output.md and in worktree if needed.

The orchestrator watches this file via filesystem polling.

## Work Log

[worker scout-pipeline-research] Starting adapter generic
[worker scout-pipeline-research] Worktree: /Users/ajez/AAI/.orchestrator/worktrees/scout-pipeline-research

## Adapter: generic
- Started: 2026-07-30T18:54:16Z
- Worker: scout-pipeline-research
- Type: scout
- Worktree: /Users/ajez/AAI/.orchestrator/worktrees/scout-pipeline-research
- Output: /Users/ajez/AAI/.orchestrator/crew/scout-pipeline-research/output.md

Created PROMPT.md in worktree
Detected agent CLI: codex (attempting launch, fallback to placeholder if unavailable)
Codex CLI at Meta (https://fburl.com/codex.cli.users)
Using AI Gateway (Azure Codex upstream)

🥑 Start using Avocado/MetaCode today and contribute to Muse Spark 🥑
Help us improve Avocado by using it for your daily workflows for the next 3-4 weeks. Learn more: https://fburl.com/workplace/5v9ba122

Reading prompt from stdin...
Not inside a trusted directory and --skip-git-repo-check was not specified.
No STATUS marker from codex, running placeholder to ensure DONE

## Simulated Scout Work

Task: Market research on data pipeline infrastructure for a small project that could grow: what solutions should be built manually vs plug-and-play. Cover ingestion, storage, transformation, orchestration, observability, cost, scalability. Deliver markdown report with build-vs-buy matrix

Exploring codebase...

### File structure (top level):
```
total 16
drwxr-xr-x  4 ajez  staff   128 Jul 30 11:54 .
drwxr-xr-x  5 ajez  staff   160 Jul 30 11:54 ..
-rw-r--r--@ 1 ajez  staff  2308 Jul 30 11:54 PROMPT.md
-rw-r--r--  1 ajez  staff    60 Jul 30 11:54 README.md
```

### Git status:
```
fatal: not a git repository (or any of the parent directories): .git

hint: Run `sl root` to check if this is a Sapling repository.
hint: If it is, run `sl help commands` to find an alternative Sapling command.
hint: Run `sl help <command>` to learn how to use it.
```

### Findings (auto-generated placeholder)

Since this is generic adapter fallback, this is placeholder.
In production, your coding agent would replace this with real investigation.

- Searched files via ls, git
- Task was: Market research on data pipeline infrastructure for a small project that could grow: what solutions should be built manually vs plug-and-play. Cover ingestion, storage, transformation, orchestration, observability, cost, scalability. Deliver markdown report with build-vs-buy matrix
- Recommendation: Use real adapter (claude-code) or ensure agent CLI in PATH

<!-- STATUS: DONE - PLACEHOLDER SUPERSEDED -->

---
# REAL RESEARCH REPORT – 2026-07-30 – Data Pipeline Infrastructure

*Worker: scout-pipeline-research – Thorough market research, Build vs Buy, Stage Recommendations*
*Full detailed version: `/Users/ajez/AAI/.orchestrator/worktrees/scout-pipeline-research/research.md`*

## Executive Summary

**Golden rule: Start boring. Scale when pain is observed, not anticipated.**

- **0-1k events/day:** FastAPI + Postgres queue (SKIP LOCKED) + S3 JSONL + Python DuckDB + Cron. Cost $15-50/mo, ops 0-1h/wk, 1 engineer.
- **1k-1M/day:** SQS/PubSub/Kinesis + S3 Parquet + Supabase/Neon + BigQuery/MotherDuck + DBT + Dagster/Prefect Cloud + Grafana Cloud + Airbyte. Cost $200-1.5k, ops 1-3h/wk.
- **1M-100M/day:** Redpanda/Confluent managed Kafka, CDC Debezium, S3 Iceberg, ClickHouse, Flink/Bytewax/RisingWave, Dagster Cloud + Temporal for critical workflows, data quality (Soda/Monte Carlo). Cost $2k-15k, team 3-5.
- **100M+:** Multi-region Kafka tiered to S3 (WarpStream), Iceberg lakehouse Trino, Spark on Databricks/EMR, Flink managed, lineage (OpenLineage/Marquez), Datadog, cost optimization focus. Cost $20k-100k+, team 5-10.

**Build vs Buy principle:** BUILD business transforms, domain models, webhook receivers, idempotency, DBT models/tests, serving APIs. BUY queues, managed Postgres, S3, warehouse engine, connectors, orchestration control plane, observability backends, Kafka hosting.

## 1. Ingestion

### Options matrix

| Tool | Latency | Throughput | Ops | Cost Model | Best For |
|------|---------|------------|-----|------------|----------|
| Webhooks/REST | <100ms | Low-Med | Low | Compute | SaaS events (Stripe) |
| Kafka / Redpanda | <10ms | 1M+/s | High (LOW if managed) | Broker+storage | Replay, ordering, high scale |
| Kinesis | ~200ms | 10k/shard/s | Low | per shard+PUT | AWS-native |
| PubSub / SQS+SNS | 50-500ms | Huge autoscale | Very Low | per message | Simple decoupling |
| CDC Debezium | secs | DB-bound | Med | Self-host or Fivetran $ | Postgres->Warehouse |
| Batch Airbyte/Fivetran | mins-hrs | Bulk | Low | per connector/row | 3rd party APIs |

**Verdict:**
- Start: Webhooks + PG queue (`SELECT ... FOR UPDATE SKIP LOCKED`) or SQS. Build manually – 50 LOC.
- Grow: Buy PubSub/SQS/Kinesis. Don't self-host Kafka until >1M/day sustained and need replay. When you do, buy Redpanda Cloud / Confluent Cloud / Upstash Kafka serverless / WarpStream (Kafka on S3). Svix for webhook retries.
- CDC: Buy Airbyte/Fivetran initially; build Debezium only at >10M/day.
- Connectors: Always buy (Airbyte OSS) unless proprietary API – API drift kills custom builds.

## 2. Storage

| Storage | Scale | Query Latency | Small Cost | Ops | When |
|---------|-------|---------------|------------|-----|------|
| Postgres (Neon/Supabase/RDS) | TBs single node | ms | $10-50/mo | Low | OLTP, <10M rows, transactional |
| S3/GCS/R2 | Infinite | Secs via engine | $0.023/GB | Zero | Raw landing, immutable, reprocessable |
| Snowflake | Auto | Secs | $200+/mo min | Zero | Gov, enterprise SQL |
| BigQuery | Auto serverless | Secs | $5/TB queried + free tier | Zero | Small team, pay-per-query, ML |
| DuckDB/MotherDuck | Single node | ms-secs | Free | Zero | Local dev, <100GB prod, transform engine |
| ClickHouse/Tinybird | Horizontal | ms | $50-300/mo | Low | Realtime dashboards |
| Delta/Iceberg on S3 | Infinite | Secs | S3+compute | Med | ACID on lake, time travel |

**Key insight:** Always land raw in S3/GCS/R2 first – cheapest, reprocessable. Postgres handles 100M rows with JSONB, partitioning. DuckDB can process 100M rows on laptop – don't start with Snowflake for 1k events/day. Warehouse choice: BigQuery for small team serverless; Snowflake for governance; MotherDuck/DuckDB for cost-sensitive early.

Lakehouse: Start Parquet. Migrate to Iceberg when you need concurrent writes, time travel, trillion-row.

## 3. Transformation

| Tool | Paradigm | Skill | Scale | Ops | Use Case |
|------|----------|-------|-------|-----|----------|
| Python pandas/polars/duckdb | Script | Python | <10GB single | Zero | Prototype, custom logic |
| DBT | SQL ELT | SQL | Warehouse-level | Low | Standard for warehouse, tests/docs |
| Spark | Dist batch | JVM/Python | TB-PB | High | Large batch, ML |
| Flink/ksqlDB/Bytewax/RisingWave | Streaming | Java/Python | M/sec | High | Stateful streaming |
| Airflow/Dagster as runner | DAG | Python | Depends | Med | Scheduling |

**Guidance:**
- Early: Python + DuckDB + Polars. Polars 10x pandas. Build manually – full control.
- Must-use: DBT for any warehouse – don't build transform framework. Models are IP.
- Spark: Only >100GB shuffle or >1hr transform in DB. Avoid premature.
- Streaming: Prefer micro-batch (1-min DBT) over Flink until <seconds really needed and >100k/sec. If needed, buy managed: RisingWave, Materialize, Confluent Flink, Bytewax Python-friendly.

Decision: <1GB hourly, 1-2 devs -> Python+DuckDB. 1-100GB -> DBT+BQ. 100GB-10TB -> DBT+Spark. Streaming <100k/sec seconds -> Bytewax/RisingWave. 100k+/sec stateful -> Flink managed.

## 4. Orchestration

| Orchestrator | Model | UI | Ops | Curve | Best For |
|--------------|-------|----|-----|-------|----------|
| Cron+Python | Time | None | Zero | Low | <10 jobs |
| Airflow | DAG standard | Rich old | High | High | 200+ operators, hiring pool |
| Dagster | Asset-based, lineage | Modern excellent | Low-Med | Med | Small->mid team **RECOMMENDED** |
| Prefect 2.x | Pythonic flow/task | Nice | Low | Low | Python devs, easiest |
| Temporal | Durable execution | Good | Med | High | Business workflows must never lose |
| Step Functions | State machine | AWS console | Zero | Med | Serverless glue S3->Lambda |

**Analysis:** Airflow is incumbent but heavy – Celery+Redis+RDBMS+Scheduler. Prefect 2 lowest friction (`@flow @task`). Dagster asset paradigm matches ELT – declares tables not tasks, best lineage and testing. Temporal solves durable long-running business processes (payments), not just ELT.

Start Prefect or cron. Grow to Dagster. Use Temporal when pipeline = business process.

## 5. Observability

| Signal | OSS | SaaS | Cost Small | Recommendation |
|--------|-----|------|------------|----------------|
| Logs | Loki, ELK, CloudWatch | Datadog, BetterStack | Free-$50 | Structured JSON + Loki or CloudWatch early, BetterStack |
| Metrics | Prometheus+Grafana | Datadog/New Relic/Grafana Cloud | Free-$100 | OTel + Grafana Cloud free tier |
| Traces | OTel+Jaeger/Tempo | Datadog, Honeycomb | Free-$50 | OTel is standard – instrument FastAPI, psycopg |
| Data Quality | DBT tests, Great Expectations, Soda | Monte Carlo, Bigeye | Free-$500+ | Build DBT tests early (uniqueness, not_null). Buy Monte Carlo only at 100M+ |
| Alerting | Grafana Alerts | Pagerduty/Opsgenie | Free | Tiered: pipeline failed -> Pager; freshness lag -> Slack; quality -> DBT |

**Must:** OTel non-negotiable. Include trace_id, pipeline_run_id, event_count in logs. Alert on queue depth, consumer lag, freshness, cost anomaly. S3 access logs retained.

## 6. Cost, Ops Overhead, Team Size

**Cost by scale (illustrative USD/mo):**

| Layer | 0-1k | 1k-1M | 1M-100M | 100M+ |
|-------|------|-------|---------|-------|
| Ingestion queue | $0-5 | $10-100 | $200-2k Kafka managed | $2k-20k |
| Postgres | $15 | $50-200 | $300-1k | Shared |
| S3 | $1 | $10-50 | $100-1k | $1k-10k |
| Warehouse | $0 DuckDB | $100-600 BQ/SF | $500-5k | $5k-50k+ |
| Transform compute | $0 local | $50-200 | $500-5k | $5k+ |
| Orchestration | $0 cron | $0-100 | $200-800 | $1k+ |
| Observability | $0 | $50-200 | $300-2k | $2k-10k |
| **Total** | **$15-50** | **$200-1.5k** | **$2k-15k** | **$20k-100k+** |

**Ops hrs/week:**

| Stack | hrs/wk |
|-------|--------|
| PG+S3+Python+Cron | 0-1 |
| +Dagster+Supabase+BQ | 1-3 |
| +self-hosted Airflow+Kafka+Spark | 10-20 (you become infra) |
| Managed Kafka/Databricks/SF | 3-5 |
| Iceberg+Flink self-host | 15-30 specialist |

**Team size rule:** Each self-hosted distributed system ~0.5-1 FTE. Solo/1-2: serverless/managed only. 3-5 + data engineer: can self-host Dagster/Redpanda single node, ClickHouse. 5-10: MSK, MWAA, EMR. 10+ platform team.

## 7. Build vs Buy Matrix (Master)

| Category | Component | Build Manual Pros/Cons | Buy Pros/Cons | Stage Rec | Verdict |
|----------|-----------|------------------------|---------------|-----------|---------|
| Ingestion | Webhook receiver | Pro: 50 LOC, control. Con: retry handling | Svix: retries, delivery | 0-1M BUILD | BUILD |
| | Queue | PG queue build cheap, but no scale | SQS managed scales | 0-1M BUY | BUY managed |
| | Kafka | Learning, control / huge ops | Confluent/Redpanda zero ops / cost | <1M no need, >1M buy managed | BUY managed |
| | CDC | Debezium OSS powerful, ops | Fivetran/Airbyte zero ops, pricey | <1M buy simple, >10M build Debezium | BUY first |
| | Connectors | Fragile, API drift | 300+ connectors | Always BUY | BUY |
| Storage | Postgres | Docker cheap / backup pain | Neon/Supabase branching | <100M buy managed | BUY managed |
| | S3/GCS | Can't build | Always buy | All BUY | BUY |
| | Warehouse | Can't build | BQ/SF/DuckDB | <1M DuckDB/PG, >1M BQ | BUY but DuckDB dev |
| | Lakehouse | OSS Iceberg build tooling | Onehouse managed | >100M build OSS | Later |
| Transform | SQL transforms | DBT manual | DBT Cloud CI | BUILD models, framework is buy | BUILD models |
| | Python | Polars/DuckDB scripts | Databricks notebooks | <100M BUILD | BUILD early |
| | Streaming | Flink complex | RisingWave/Materialize managed | <1M don't, >10M buy managed | BUY managed |
| Orchestration | Cron | Easy | Cloud Scheduler | 0-1k BUILD | BUILD |
| | DAG | Self-host / ops | Dagster Cloud/Prefect Cloud | 1k-1M buy cloud | BUY cloud early |
| Observability | Logs | Loki/Prom build | BetterStack | Early BUILD Loki or Grafana Cloud | BUILD OSS/Grafana free |
| | Metrics/Traces | OTel+Prom+Grafo | Datadog | OTel+GRAFANA CLOUD | Grafana Cloud free |
| | Data Quality | DBT tests | Monte Carlo | BUILD early, BUY later | BUILD DBT tests |

**Summary:** BUILD business logic, transforms, domain models, webhook skeleton, DBT models, idempotency, DLQ, serving API. BUY queues, PG managed, S3, warehouse, ingestion connectors, orchestration control plane, observability SaaS, Kafka hosting.

## 8. Stage Recommendations – Detailed

### Stage 0: 0-1k/d Prototype Pre-PMF
Goal: Ship fast, zero infra, prove value.
Stack: FastAPI webhook + Pydantic + Postgres queue SKIP LOCKED + S3 JSONL raw + Python Polars/DuckDB nightly + cron (pg_cron/GitHub Actions) + stdout JSON logs + Sentry + Grafana Cloud free.
Cost $0-50. 1 engineer. Avoid Kafka/Airflow/Snowflake.

### Stage 1: 1k-1M/d Early Traction
Goal: Reliability, replay.
Stack: SQS/PubSub/Kinesis + Lambda/Cloud Run; Airbyte for external APIs; Svix; S3 parquet partitioned `year=/month=/day=`; Neon/Supabase; BigQuery/MotherDuck; DBT Core; Dagster single container on Fly.io or Prefect Cloud; OTel->Grafana Cloud; DBT tests freshness.
Cost $200-1500. 1-2 eng + analyst. Trigger to next: queries >10s, PG CPU >70%, queue backlog.

### Stage 2: 1M-100M/d Growth
Goal: Scale, exactly-once, self-serve.
Stack: Redpanda/Confluent managed Kafka or Kinesis enhanced fan-out, idempotent producer; Debezium CDC; S3 Iceberg; BQ/Snowflake; ClickHouse realtime; DBT+warehouse batch; Bytewax/RisingWave streaming; Spark only if TB shuffle – else BQ; Dagster Cloud + Temporal for critical flows; OTel+Prom+Grafana+Soda/Monte Carlo $500+; PagerDuty.
Cost $2k-15k. 3-5 eng with analytics eng.

### Stage 3: 100M+ Scale
Goal: Multi-region, SLO, cost opt.
Stack: Multi-AZ Kafka WarpStream tiered S3, Schema Registry, Debezium Connect distributed, Iceberg on S3 Trino/StarRocks, Snowflake/BQ external tables, Postgres Vitess, Spark EMR/Databricks, Flink managed, Dagster/Airflow K8s 1000s DAGs, Temporal 10k workflows, Datadog/Enterprise Grafana, OpenLineage/Marquez, Monte Carlo.
Cost $20k-100k+, platform team.

## 9. What to Build Manually for Learning/Control vs Plug-and-Play Speed

**Build manually – high learning/control, low ops risk:**
- Webhook receiver + validation (FastAPI+Pydantic)
- PG SKIP LOCKED queue consumer – understand ack/retry
- Raw->staging transforms DuckDB/Polars – own business logic
- DBT models + tests – core IP
- S3 partitioning + Parquet writer – file layout impacts cost 100x
- OTel instrumentation – vendor neutral
- Data API serving layer – FastAPI over warehouse view
- DLQ + replay, idempotency keys + dedup

**Plug-and-play – low learning, high ops if built:**
- Kafka hosting -> Redpanda Cloud
- PG backups -> Neon/Supabase/RDS
- Warehouse -> BigQuery/Snowflake
- Connectors -> Airbyte/Fivetran
- Airflow hosting -> Dagster/Prefect Cloud/MWAA
- Spark cluster -> EMR/Databricks
- Observability backend -> Grafana Cloud/Datadog
- Schema Registry, CDC infra -> Confluent managed
- Secrets -> cloud IAM/Doppler

**Learning ladder:**
Month1: FastAPI->SQS->S3->DuckDB->Grafana local
Month2: Swap SQS->Redpanda Docker + Kafka consumer + DBT
Month3: DuckDB->BigQuery, Dagster OSS, OTel->Grafana Cloud, Airbyte 1 source
Month4: Debezium CDC PG->Kafka, Flink/Bytewax streaming count, Parquet->Iceberg
Now you understand full modern stack.

## 10. Reference Architectures (Text)

**0-1k:** [Webhook|App] -> FastAPI validate -> PG queue + S3 raw JSONL -> Cron 5min Python worker SELECT SKIP LOCKED -> Transform -> agg table -> logs stdout->Grafana Cloud

**1k-1M:** Sources webhook+Airbyte -> SQS/PubSub -> Cloud Run -> S3 raw parquet lifecycle Glacier + PG OLTP; Dagster->DBT on BQ staging->marts tests fail Slack; Grafana OTel queue depth lag.

**1M-100M:** Neon Prod --CDC Debezium-> Redpanda --APIs Airbyte->S3-- Flink/RisingWave->ClickHouse/BQ; Dagster assets = dbt + python checks; OTel->Grafana+Monte Carlo.

**100M+:** Multi-region App->Local Redpanda->Global Confluent Tiered S3 Kafka -> Flink fraud sessionization -> Iceberg Lake S3 -> Trino/Snowflake external; Debezium -> PG read + cache; Temporal workflows; Dagster lineage; Datadog+Marquez compliance.

## 11. Anti-Patterns

1. Kafka too early – ordering/partition bugs for <100k.
2. No raw landing – cannot reprocess. Always save raw immutable.
3. EL vs ELT – don't transform before warehouse early; ELT simpler.
4. Spark for small data – 100x cost vs DuckDB.
5. Airflow as cron – overkill <10 DAGs.
6. No idempotency – duplicates cause money bugs; unique index key.
7. Manual JSON logs not queryable – structured + trace_id.
8. No partitioning – BQ scans full $100 query; partition date, cluster user_id.
9. Premature exactly-once – aim at-least-once + idempotent consumer first.
10. Building connectors – API drift kills you; buy Airbyte.

## 12. Quick-Start Stack for AAI

Serverless-first recommended:
- Ingestion: FastAPI+Pydantic+SQS/Upstash Queue or Cloudflare Workers+R2
- Storage: Supabase Postgres + S3/R2 (zero egress) + Parquet
- Transform: DuckDB + DBT Core + Polars
- Orchestration: Prefect Cloud free or Dagster OSS on Fly.io
- Observability: Sentry + Grafana Cloud free Loki+Tempo+Prometheus + OTel + DBT tests
- Cost $50-150/mo start, scales to $1k at 1M/day

Rubric Should I Build? Score 1-5: Core IP? (5 build), Managed cost > eng cost? (5 build), Ops risk low? (5 build), Career-critical learning? (5 build), OSS 80% solved? (1 buy). >15 Build else Buy.

Vendors 2026 eval: Upstash Redis/Kafka, SQS, PubSub, Cloudflare Queues; Redpanda Cloud, Confluent, WarpStream; Neon, Supabase, CrunchyBridge; BQ, Snowflake, MotherDuck, ClickHouse Cloud, Tinybird; Dagster Cloud, Prefect Cloud, Temporal Cloud, MWAA; Airbyte Cloud, Fivetran, Estuary; Grafana Cloud, Datadog, Honeycomb, BetterStack, Sentry; Tabular, Onehouse, Dremio.

---

## Result: Thorough pipeline infra research completed – build vs buy matrix + 4-stage roadmap (0-1k to 100M+). Full 30k detailed report in worktree research.md. Quick-start recommendation: FastAPI+SQS+S3+Postgres+DuckDB+DBT+Dagster/Prefect+Grafana Cloud. BUILD business logic/transforms/idempotency, BUY queues/warehouse/connectors/Kafka managed/observability SaaS.

<!-- STATUS: DONE -->

