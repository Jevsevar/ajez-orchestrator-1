# Data Pipeline Infrastructure Research – Small Project That Could Grow
*Scout: scout-pipeline-research | Date: 2026-07-30*

> Objective: exhaustive market research on what to build manually vs plug-and-play for a small project with growth ambitions.

## Table of Contents
1. Executive Summary
2. Ingestion Layer
3. Storage Layer
4. Transformation Layer
5. Orchestration Layer
6. Observability Layer
7. Cost, Operational Overhead, Team Size
8. Build vs Buy Matrix (Master Table)
9. Stage Recommendations (0-1k, 1k-1M, 1M-100M, 100M+)
10. What to Build Manually for Learning/Control vs Plug-and-Play for Speed
11. Reference Architectures by Stage
12. Anti-Patterns & Pitfalls
13. Final Checklist & Quick-Start Stack

---

## 1. Executive Summary

**Core thesis:** Start boring. Postgres + S3 + Python + cron/Dagster + DBT + DuckDB gets you to 1M events/day with <1 person overhead. Only introduce distributed systems (Kafka, Spark, Flink, Airflow cluster) when pain is real, measured, and recurring.

**2026 market reality:**
- Warehouses (BigQuery, Snowflake) commoditized – serverless, pay-per-query, zero ops.
- Object storage is the universal sink – S3/GCS is the cheapest durable thing.
- OSS orchestration (Dagster, Prefect) overtook Airflow for small teams due to UX.
- CDC + ELT tooling (Fivetran, Airbyte, Debezium, Estuary) is "solved" – don't build connectors.
- Observability: OpenTelemetry is standard; managed Grafana/Datadog tradeoff is cost vs convenience.

**Golden path for small -> large:**
```
Stage 0-1k/d:  Webhooks/API -> Python FastAPI ingestion -> Postgres -> DuckDB/DBT -> Cron -> Grafana logs
Stage 1k-1M/d: + S3 parquet landing, + PubSub/SQS/Kinesis, + Dagster/Prefect, + BigQuery/Snowflake, + Airbyte
Stage 1M-100M/d: + Kafka/Redpanda or Kinesis, + Flink/Spark or DBT+Snowflake, + Temporal for workflows, + OTel
Stage 100M+: Multi-region Kafka, CDC (Debezium), Iceberg/Delta on S3, Spark/Flink, Warehouse+Lakehouse, Datadog
```

**Principle:** Buy ingestion connectors, buy warehouse, buy observability SaaS. Build business transforms and domain logic.

---

## 2. Ingestion Layer

### 2.1 Options

| Tool | Type | Latency | Throughput | Ops Overhead | Cost Model | Best For |
|------|------|---------|------------|--------------|------------|----------|
| **Webhooks / REST API** | Push | <100ms | Low-Med | Low | Compute only | SaaS events, Stripe, GitHub |
| **Kafka / Redpanda / MSK** | Pub/Sub log | <10ms | 1M+/s | High (unless managed) | Brokers+storage | High-throughput, replay, ordering |
| **Kinesis (AWS)** | Stream | ~200ms | 10k shard/s | Low | Per shard/hour + PUT | AWS-native streaming |
| **Pub/Sub (GCP) / SQS+SNS (AWS)** | Queue/PubSub | 50-500ms | Huge auto-scale | Very Low | Per message | Simple decoupling, scale-to-zero |
| **CDC (Debezium, Fivetran, Supabase Realtime)** | Log capture | secs | DB-bound | Med | Connector pricing | Postgres->Warehouse sync |
| **Batch (Airbyte, Fivetran, custom S3 loads)** | Poll/copy | Minutes-hours | Bulk | Low | Per connector/row | 3rd party APIs, legacy DBs |
| **Estuary, Confluent Connect, Bytewax** | Managed streaming | Low | High | Low-Med | Usage based | Startup-friendly managed capture |

### 2.2 Deep Dive & Tradeoffs

**Webhooks:**
- Pros: Simplest to start, no infra. FastAPI + queue handles 10k rpm easily. Natural for external SaaS.
- Cons: No replay, at-least-once headache, ordering not guaranteed, backpressure difficult.
- Build vs Buy: Build receiver manually (50 LOC). Buy: Svix for webhook delivery/retries.

**Kafka:**
- Pros: Gold standard for ordering, replay, exactly-once (with transactions), ecosystem.
- Cons: ZooKeeper legacy gone but still operationally heavy. Need Schema Registry, monitoring, partition strategy. Overkill <100k events/day.
- Alternative: **Redpanda** – Kafka API compatible, C++ single binary, 10x simpler. **Warpcore/Upstash Kafka** serverless.
- Build vs Buy: Do NOT self-host Kafka early. Use Confluent Cloud, Redpanda Cloud, or Upstash. Only self-host if you need learning.

**Kinesis:**
- Pros: No ops, integrates with Firehose->S3, Lambda. Good for AWS shop.
- Cons: Shard management, ordering per shard only, 7-day retention (extend costly), replay limited vs Kafka. Record size 1MB.
- Buy: Use it if AWS-only and <100M/day. Otherwise consider PubSub.

**PubSub / SQS+SNS:**
- Pros: True serverless, infinite scale, dead-letter queues. Cheapest for bursty.
- Cons: No ordering (PubSub has ordering keys but limited), no replay beyond retention. SQS FIFO limited throughput.
- Verdict: **Best starting queue for small team**. SQS -> Lambda -> S3 pattern covers 80%.

**CDC:**
- Debezium: OSS gold. Captures Postgres WAL -> Kafka. Needs Kafka Connect. Powerful but operational lift.
- Fivetran/Airbyte: Managed CDC – expensive but zero ops.
- Logical replication directly to warehousing (e.g., Supabase, Neon): Simplest for Postgres->BigQuery.

**Batch:**
- For external APIs (Shopify, Salesforce), batch is fine. Use Airbyte open source (self-host) or Fivetran (buy).
- Don't build custom connectors unless API is proprietary.

### 2.3 Ingestion Decision Flowchart
```
Need replay + ordering + >10k/sec sustained?
  YES -> Redpanda/Kafka managed
  NO -> Need AWS/GCP only serverless?
    YES -> Kinesis or PubSub/SQS
    NO -> Webhooks + queue enough?
      YES -> FastAPI + SQS/PG queue
      NO -> Batch/CDC
        Is source Postgres/MySQL you own?
          YES -> Debezium/Neon logical replication
          NO -> Airbyte/Fivetran
```

---

## 3. Storage Layer

### 3.1 Comparison Matrix

| Storage | Type | Scalability | Query Latency | Cost (small) | Ops | When |
|---------|------|-------------|---------------|--------------|-----|------|
| **Postgres (RDS/Supabase/Neon)** | OLTP | 1 node to TBs | ms | $10-50/mo | Low | App DB, <10M rows, transactional |
| **S3 / GCS** | Object lake | Infinite | Sec-min (via query engine) | $0.023/GB | Zero | Raw landing, parquet, backup |
| **Snowflake** | Cloud Warehouse | Auto-scale | Secs | $2-4/credit, min $200+ | Zero | Enterprise SQL, governed |
| **BigQuery** | Serverless Warehouse | Auto | Secs | $5/TB queried + storage | Zero | GCP, analytics, ML, pay-per-query |
| **DuckDB** | Embedded OLAP | Single node | ms-secs | Free | Zero | Local dev, <100GB, small-prod analytics |
| **ClickHouse / MotherDuck / Tinybird** | Real-time OLAP | Horizontal | ms | $50-300/mo | Low | Real-time dashboards |
| **Delta Lake / Iceberg on S3** | Lakehouse | Infinite | Secs | S3 + compute | Med | Need ACID on lake, time travel |

### 3.2 Guidance

- **S3 as source of truth:** Always land raw JSON/parquet in S3/GCS first. Cheapest, immutable, re-processable. Use `s3://raw/YYYY/MM/DD/` pattern.
- **Postgres is enough for longer than you think:** With proper indexing, TOAST, JSONB, pg_cron, pg_partman, it handles 100M rows. Supabase/Neon gives S3 backup, branching, autoscale.
- **Warehouse choice:**
  - **BigQuery:** Best for small team, pay-per-query, serverless, generous free tier, good for ML (BigQuery ML). No cluster sizing. Cons: GCP lock, query cost surprises if no partitioning.
  - **Snowflake:** Best governance, separation compute/storage, great for enterprise. Cons: Cost unpredictable, cold start, minimum overhead.
  - **DuckDB:** Insane value. Run transformations locally, then upload to S3. MotherDuck gives cloud sharing. Use as embedded transformation engine before warehouse.
- **Anti-pattern:** Starting with Snowflake for 1k events/day. Use Postgres + DuckDB until warehouse needed (~1M+/day or need BI team).

### 3.3 Lakehouse Format
When you need ACID on S3:
- Delta Lake: Best Spark/Databricks ecosystem.
- Iceberg: More open, best for multi-engine (Trino, Flink, Snowflake reads). Flink native.
- Hudi: Good for upserts.
Recommendation: Start parquet, migrate to Iceberg when you need time-travel, concurrent writes, or trillion-row.

---

## 4. Transformation Layer

### 4.1 Tools

| Tool | Paradigm | Skill Needed | Scale | Ops | Use Case |
|------|----------|--------------|-------|-----|----------|
| **Python (pandas/polars/duckdb)** | Script | Python | <10GB single node | Zero | Early stage, prototypes, custom logic |
| **DBT** | SQL ELT | SQL | Warehouse-level | Low | SQL transforms in warehouse, tests, docs |
| **Spark (PySpark, EMR, Databricks)** | Distributed batch | JVM/Python | TB-PB | High | Large batch, ML |
| **Flink / ksqlDB / Bytewax** | Streaming | Java/Python | Millions/sec | High | Stateful streaming, windowing |
| **Airflow/Dagster/Prefect (as transform runner)** | DAG | Python | Orchestration dependent | Med | Scheduling Python/DBT jobs |

### 4.2 Deep Dive

**Python + DuckDB + Polars:**
- Modern small-data stack. Polars 10x faster than pandas. DuckDB queries parquet directly.
- Can process 100M rows on laptop. No cluster.
- Build manually – full control, easy debugging.
- When to outgrow: Data > RAM, need distributed, team >3 needing collaboration.

**DBT:**
- **Must-use for any warehouse.** SQL with Jinja, tests, docs, lineage. Transforms live in warehouse, not custom Python.
- DBT Cloud vs Core: Start Core (free), move to Cloud for CI.
- Build vs Buy: Use OSS DBT – don't build transform framework. Your value is models, not runner.
- Pros: Standard, hiring-friendly, tests. Cons: Only batch SQL, not streaming.

**Spark:**
- Heavyweight. Need EMR/Databricks unless you want pain.
- Only justified >100GB shuffled or complex ML.
- Most startups prematurely adopt Spark – avoid until 100M+/day and transforms >1hr in DB.

**Flink:**
- True streaming (exactly-once stateful). Best for fraud, real-time aggregations.
- Operationally complex – requires checkpointing, state backend (RocksDB+S3).
- Alternative: **Bytewax, RisingWave, Materialize** for Python-friendly streaming.
- Small team? Prefer ksql or DBT + micro-batch (1-min) over Flink.

### 4.3 Decision Matrix
| Volume | Latency Need | Team Size | Recommendation |
|--------|--------------|-----------|----------------|
| <1GB batch | Hourly-daily | 1-2 | Python + DuckDB |
| 1-100GB | Hourly | 2-5 | DBT on Postgres/BigQuery + Python |
| 100GB-10TB | Hourly-daily | 5+ | DBT + Spark (Databricks/BigQuery) |
| Streaming <100k/sec | Seconds | 2+ | Bytewax/RisingWave or Kinesis+Lambda |
| Streaming 100k+/sec | ms-sec, stateful | 5+ | Flink managed (Confluent/Ververica) |

---

## 5. Orchestration Layer

| Orchestrator | Model | UI | Scale | Ops | Learning Curve | Ecosystem |
|--------------|-------|----|-------|-----|----------------|-----------|
| **Cron + Python** | Time based | None | Single node | Zero | Low | Works surprisingly long |
| **Airflow** | DAG, open source standard | Rich but old | Large, Celery+K8s | High | High | 1000+ operators, hiring pool |
| **Dagster** | Asset-based, software-defined | Modern, excellent lineage | Med-Large | Low-Med | Med | Best for small->mid team |
| **Prefect 2.x** | Pythonic tasks/flows | Nice | Med-Large | Low | Low | Easiest for Python devs |
| **Temporal** | Durable execution | Good | Huge | Med | High | Microservices workflows, never lose job |
| **Step Functions / Cloud Workflows** | State machine | AWS/GCP console | Huge serverless | Zero | Med | Serverless glue |

### 5.1 Analysis

**Airflow:**
- Pros: Incumbent, every integration exists. Managed via MWAA/Cloud Composer.
- Cons: DAG writing clunky, scheduler fragile pre-2.7, deployment heavy, needs Celery/RDBMS/Redis. UI dated. Small team overhead high.
- Verdict: Choose if hiring data engineers who know it, or need 200+ operators.

**Dagster (Recommended for growing small teams):**
- Asset paradigm matches modern ELT (declare tables, not tasks). Great lineage, data quality checks built-in.
- Local dev `dagster dev` instant. Dagster Cloud serverless.
- Lower ops than Airflow. Best tradeoff learning vs power.
- Buy vs Build: Use OSS, deploy on single VM; pivot to Dagster Cloud at scale.

**Prefect 2:**
- Most Pythonic – `@flow @task`. Minimal boilerplate.
- Prefect Cloud generous free tier. Good for <10 flows.
- Cons: Asset lineage less mature than Dagster.
- Best for: API-triggered workflows, data science teams.

**Temporal:**
- Solves different problem: durable long-running workflows (e.g., user signup that calls 5 services over days). Guarantees execution.
- Overkill for ELT but excellent for critical pipelines needing exactly-once.
- Consider when pipeline = business process (payments, provisioning).

**Step Functions:**
- Zero ops, ties Lambda, Glue. Great if AWS-native. JSON state machine verbose, local testing hard.
- Good for glueing S3->Lambda->Warehouse.

### 5.2 Recommendation
Start: Cron or Prefect. Grow: Dagster. Specialized durable: Temporal.

---

## 6. Observability Layer

#### Core Signals

| Signal | OSS | Managed SaaS | Cost Small | Ops |
|--------|-----|--------------|------------|-----|
| Logs | Loki, ELK, CloudWatch | Datadog, BetterStack | Free-$50 | Med |
| Metrics | Prometheus + Grafana | Datadog, New Relic, Grafana Cloud | Free-$100 | Low-Med |
| Traces | OpenTelemetry + Jaeger/Tempo | Datadog, Honeycomb, Grafana Cloud | Free-$50 | Low |
| Data Quality | DBT tests, Great Expectations, Soda | Monte Carlo, Bigeye | Free-$500 | Low-High |
| Alerting | Grafana Alerts, Pagerduty OSS | Pagerduty, Opsgenie | Free | Low |

#### OTel is Non-Negotiable
- OpenTelemetry standard for traces/metrics/logs. Instrument Python with `opentelemetry-instrumentation-fastapi`, `psycopg`.
- Send to Grafana Cloud (free 10k series) or Jaeger initially.
- Don't build custom tracing.

#### Logging Guidance
- Structure logs JSON, include `trace_id`, `pipeline_run_id`, `event_count`.
- Centralize in Loki (cheap) or CloudWatch. For early stage, stdout + Better Stack.
- S3 access logs for audit.

#### Data Observability (Unique to pipelines)
- DBT tests: uniqueness, not_null, accepted_values – free data quality.
- Great Expectations / Soda: heavier but good.
- Monte Carlo/Bigeye: expensive ($10k+/yr) – only when data downtime costs > tool cost.
- Build vs Buy: Build DBT tests manually; buy Monte Carlo only at 100M+.

#### Alerting Tiers
- T1: Pipeline failed (PagerDuty/Slack)
- T2: Freshness lag > X (Grafana alert)
- T3: Data quality anomaly (DBT test fail)
- T4: Cost anomaly (BigQuery cost spike)

---

## 7. Cost, Operational Overhead, Team Size

### 7.1 Cost Models by Layer (Monthly est. for illustrative scale)

| Component | 0-1k/d | 1k-1M/d | 1M-100M/d | 100M+ |
|-----------|--------|---------|-----------|-------|
| Ingestion (queue) | $0-5 SQS/webhook | $10-100 Kinesis/PubSub | $200-2k Kafka managed | $2k-20k |
| Storage (Postgres) | $15 Neon/Supabase | $50-200 RDS | $300-1k+ | Shared |
| Storage (S3) | $1 | $10-50 | $100-1k | $1k-10k |
| Warehouse | $0 DuckDB | $100-600 BQ/Snowflake | $500-5k | $5k-50k+ |
| Transform (compute) | $0 local | $50-200 DBT/BQ | $500-5k Spark | $5k+ |
| Orchestration | $0 cron | $0-100 Prefect Cloud | $200-800 Dagster/Airflow | $1k+ |
| Observability | $0 logs | $50-200 Grafana Cloud | $300-2k Datadog | $2k-10k |
| **Total** | **$15-50/mo** | **$200-1.5k/mo** | **$2k-15k/mo** | **$20k-100k+** |

### 7.2 Operational Overhead (hrs/week)

| Stack | Ops hrs/week (team 1-2) | Why |
|-------|------------------------|-----|
| Postgres+S3+Python+Cron | 0-1 | Near zero ops |
| +Dagster+Supabase+BigQuery | 1-3 | Managed services |
| +Airflow+Kafka+Spark self-host | 10-20 | You become infra team |
| Managed Kafka/Databricks/Snowflake | 3-5 | Vendor ops but complexity |
| Lakehouse Iceberg+Flink self-host | 15-30 | Specialist needed |

### 7.3 Team Size Implications

- **Solo / 1-2 engineers, no data engineer:** Must go serverless/managed: SQS/PubSub, Supabase/Neon, BigQuery, Prefect/Dagster Cloud, DBT Core, Grafana Cloud. Avoid Airflow, self-hosted Kafka, Spark.
- **3-5 engineers, one data-focused:** Can self-host Dagster/Prefect, Airbyte, Redpanda single node, ClickHouse. Still avoid Spark/Flink unless needed.
- **5-10 with data platform engineer:** Can run MSK/Confluent, MWAA, EMR. Introduce Iceberg, Flink.
- **10+ platform team:** Multi-region, CDC at scale, cost optimization team.

**Rule:** Each self-hosted distributed system (Kafka, Flink, Airflow, Spark) costs ~0.5-1 FTE ongoing.

---

## 8. Build vs Buy Matrix (Master)

| Category | Component | Build Manual (Pros/Cons) | Buy/Managed (Pros/Cons) | Recommendation by Stage | Verdict |
|----------|-----------|--------------------------|------------------------|-------------------------|---------|
| **Ingestion** | Webhook receiver | Pro: 50 LOC, control. Con: retry, idempotency | Svix $ (pros: retries, delivery) | 0-1M: BUILD | BUILD early |
| | Queue (SQS/PubSub) | Build simple PG queue (skip_locked) – pro: no bill | Managed queue – pro: scales | 0-1M: BUY | BUY managed |
| | Kafka | Build: learning, control. Con: huge ops | Confluent/Redpanda/Upstash – pro: zero ops | <1M: DON'T NEED; >1M: BUY managed | BUY managed, BUILD only for learning |
| | CDC | Debezium OSS build | Fivetran/Airbyte/Neon | <1M: BUY simple; >10M: Build Debezium | BUY first |
| | Connectors (Shopify etc) | Build custom: fragile, API changes | Airbyte/Fivetran: 300+ connectors | Always BUY unless proprietary | BUY |
| **Storage** | Postgres | Self-host Docker – cheap | Neon/Supabase/RDS – backups, branching | <100M: BUY managed PG | BUY managed |
| | S3/GCS | Can't build – always buy | Always buy | All stages: BUY | BUY |
| | Warehouse | Can't build | BQ/Snowflake/DuckDB MotherDuck | <1M: DuckDB/Postgres; >1M: BUY BQ | BUY, but DuckDB for dev |
| | Lakehouse format | OSS Iceberg/Delta – build tooling | Onehouse/Tabular managed | Only >100M: BUILD OSS | BUY/OSS later |
| **Transformation** | SQL transforms | Build DBT manually – custom Jinja | DBT Cloud – CI, docs hosting | All: BUILD with DBT framework | BUILD models, BUY framework |
| | Python transforms | Build Polars/DuckDB scripts | Databricks notebooks | <100M: BUILD | BUILD early |
| | Streaming transforms | Build Flink – complex | RisingWave/Materialize/Confluent | <1M: DON'T; >10M: BUY managed | BUY managed |
| | Spark | Self-host painful | EMR/Databricks | Only TB scale: BUY managed | BUY when needed |
| **Orchestration** | Cron | Build – easy | Managed cron (Cloud Scheduler) | 0-1k: BUILD cron | BUILD |
| | DAG orchestrator | Self-host Airflow/Dagster | Managed MWAA/Dagster Cloud/Prefect Cloud | 1k-1M: BUY cloud; 1M+: Dagster self or cloud | BUY cloud early, SELF later if cost |
| **Observability** | Logs | Build Loki/Prom | BetterStack/Datadog logs | Early: BUILD Loki/Grafana Cloud | BUILD OSS or Grafana Cloud |
| | Metrics/Traces | OTel + Prometheus + Grafana | Datadog/New Relic | Early: OTel+GRAFANA CLOUD | BUY Grafana Cloud free tier |
| | Data Quality | Build DBT tests | Monte Carlo/Soda | Early: BUILD DBT tests | BUILD early, BUY later |

**Summary rule:**
- BUILD: Business logic, transforms, domain models, webhook receiver skeleton, DBT models/tests, custom ML.
- BUY: Queues, Postgres managed, S3, warehouse, connector ingestion, orchestration control plane, observability SaaS.

---

## 9. Stage Recommendations

### Stage 0: 0-1k events/day (Prototype / Pre-PMF)
**Goal:** Ship fast, zero infra cost, prove value.
**Architecture:**
- Ingestion: FastAPI webhook endpoint + Pydantic validation + Postgres queue table (`SELECT ... FOR UPDATE SKIP LOCKED`) or SQS.
- Storage: Supabase/Neon Postgres (free tier). S3 raw landing `s3://raw/yyyymmdd/*.jsonl`.
- Transformation: Python Polars or DuckDB script nightly. DBT optional.
- Orchestration: Cron (`pg_cron` or GitHub Actions cron or `apscheduler`) – 1 file.
- Observability: Structured JSON logging to stdout, Better Stack or Grafana Cloud free, Sentry for errors.
**Cost:** $0-50/mo.
**Team:** 1 full-stack engineer.
**Build vs Buy:** Build everything except Postgres (buy managed). Avoid Kafka, Airflow, Snowflake.

### Stage 1: 1k-1M events/day (Early Traction)
**Goal:** Reliability, replay, modest scale.
**Architecture:**
- Ingestion: SQS/PubSub or Kinesis (if AWS) + Lambda/Cloud Run consumers. Add Airbyte for external APIs. Consider Svix for inbound webhooks.
- Storage: Neon/Supabase scaled up + S3 parquet (partitioned). Introduce BigQuery (or MotherDuck) for analytics. Start landing raw to S3.
- Transformation: DBT Core on BigQuery/Postgres. Python DuckDB for heavy lifts. Use Polars for memory efficiency.
- Orchestration: Prefect Cloud or Dagster OSS single Docker container on Fly.io/Render. Schedule DBT.
- Observability: OpenTelemetry in FastAPI -> Grafana Cloud (Tempo/Loki). DBT tests + freshness checks. Sentry still.
**Cost:** $200-1500/mo.
**Team:** 1-2 engineers + analyst.
**Milestones to next stage:** Queries >10s, Postgres CPU >70%, backlog in queue, manual retry pain.

### Stage 2: 1M-100M events/day (Growth)
**Goal:** Scale, exactly-once, self-serve.
**Architecture:**
- Ingestion: Managed Kafka (Redpanda Cloud / Confluent) or Kinesis with enhanced fan-out, or PubSub. Exactly-once with idempotent producer. CDC via Debezium or Neon->Kafka for PG.
- Storage: S3/GCS as lake (Iceberg if needing ACID). BigQuery/Snowflake for warehouse. Postgres remains OLTP but sharded or read-replicas. ClickHouse for real-time dashboards.
- Transformation: DBT + warehouse for batch. For streaming: Bytewax/RisingWave or Kinesis Data Analytics. Introduce Spark only if TB shuffle needed – use BigQuery or Snowflake first.
- Orchestration: Dagster Cloud or self-hosted Dagster on K8s. Asset lineage. Data quality checks as asset checks. Maybe Temporal for critical business workflows (e.g., payment pipeline).
- Observability: Full OTel, Prometheus, Grafana dashboards for lag (consumer lag, queue depth), Monte Carlo or Soda for data quality at $500+/mo, Datadog if budget (or Grafana Cloud). PagerDuty.
**Cost:** $2k-15k/mo.
**Team:** 3-5 engineers incl. data/analytics engineer.
**Build vs Buy:** Buy managed streaming, warehouse, orchestration control plane. Build transforms and domain services.

### Stage 3: 100M+ events/day (Scale)
**Goal:** Multi-region, cost optimization, SLOs.
**Architecture:**
- Ingestion: Multi-AZ Kafka (Confluent or WarpStream – Kafka on S3), schema registry, Tiered Storage (S3). CDC at scale with Debezium + Kafka Connect distributed.
- Storage: Lakehouse (Iceberg on S3) with Trino/StarRocks query. Snowflake/BigQuery for BI, but offload heavy scans to lake. Postgres for OLTP with Vitess/Cockroach or split.
- Transformation: Spark on EMR/ Databricks or Snowflake Snowpark for massive batch. Flink managed (Confluent Flink, Ververica) for streaming joins, session windows. DBT still for warehouse marts.
- Orchestration: Dagster/Airflow on K8s with 1000s DAGs, or Temporal for 10k workflows. Step Functions for serverless pieces.
- Observability: Datadog / Grafana Enterprise, SLO-based alerting, lineage (OpenLineage + Marquez), data observability (Monte Carlo).
**Cost:** $20k-100k+/mo – focus on tiered storage, query cost controls, partition pruning.
**Team:** Platform team 5-10.
**Build vs Buy:** Mix. Buy warehouse, streaming managed, observability SaaS. Build platform abstractions (internal ingestion SDK, schema enforcement) for control.

---

## 10. What to Build Manually for Learning/Control vs Plug-and-Play for Speed

### Build Manually – High Learning, High Control, Low Ops Risk

1. **Webhook receiver + validation** – 1 FastAPI route, Pydantic. Learn idempotency patterns.
2. **Simple queue consumer** – PG `FOR UPDATE SKIP LOCKED` or SQS polling loop. Understand ack/retry.
3. **Raw to staging transforms in DuckDB/Polars** – Own your business logic; avoid black-box magic.
4. **DBT models + tests** – Your data model is core IP; never outsource.
5. **S3 partitioning scheme + Parquet writer** – Understand file layout impacts query cost 100x.
6. **OTel instrumentation** – Add trace, metrics yourself – vendor neutral skill.
7. **Data API / serving layer** – Build FastAPI over DuckDB/Postgres warehouse view.
8. **Dead-letter + replay mechanism** – Manual DLQ handling teaches exactly-once vs at-least-once.
9. **Idempotency keys + deduplication** – Critical, not solved fully by tooling.

**Benefits:** Deep understanding, hiring interview stories, debugging ability, no lock-in.

### Plug-and-Play for Speed – Low Learning Value, High Ops If Built

1. **Kafka hosting** – Use Redpanda/Confluent Cloud. Self-hosting teaches but wastes sprints.
2. **Postgres hosting/backups** – Neon/Supabase/RDS. Don't manage WAL archiving yourself.
3. **Warehouse engine** – BigQuery/Snowflake. Never build warehouse.
4. **Connector ingestion (Salesforce, Stripe, Hubspot)** – Airbyte/Fivetran. API changes constant.
5. **Airflow hosting** – Dagster Cloud/Prefect Cloud/MWAA. Scheduler ops is thankless.
6. **Spark cluster** – EMR/Databricks serverless. Don't tune YARN.
7. **Observability backend** – Grafana Cloud/Datadog. Don't run ELK unless expert.
8. **Schema Registry, CDC infrastructure** – Confluent Schema Registry, Debezium managed.
9. **Secret management, auth** – Use cloud IAM, Doppler.

### Learning Ladder (Recommended Path for Engineer Wanting Growth)

**Month 1:** Build FastAPI->SQS->S3->DuckDB->Grafana local.
**Month 2:** Swap SQS->Redpanda local (Docker), PG queue->Kafka consumer, add DBT.
**Month 3:** Migrate DuckDB->BigQuery, orchestrate with Dagster OSS, add OTel->Grafana Cloud, add Airbyte for 1 external source.
**Month 4:** Add Debezium CDC PG->Kafka, Flink/Byetwax streaming count, Parquet->Iceberg, asset lineage.
Now you understand whole modern stack without burning prod.

---

## 11. Reference Architectures by Stage

### Stage 0 Diagram
```
[Stripe Webhook | App Events] -> FastAPI (validate) -> Postgres table (events_queue, status)
                                              \-> S3 raw JSONL
Cron every 5min: Python worker SELECT ... SKIP LOCKED -> Transform (Pandas/DuckDB) -> agg table
                            -> Logs -> stdout -> Grafana Cloud free
```

### Stage 1
```
Sources: Webhooks + API poll (Airbyte) -> SQS/PubSub -> Cloud Run / Lambda消费者
   |-> S3 raw (parquet) -> Lifecycle to Glacier
   |-> Postgres OLTP
Dagster/Prefect: Schedule -> DBT run on BigQuery (staging -> marts) -> Tests fail -> Slack alert
Grafana: OTel traces + metrics (queue depth, lag)
```

### Stage 2
```
Prod DB (Neon) --CDC Debezium--> Redpanda Cloud --\
External APIs --Airbyte--> S3 ------|-> Flink/RisingWave -> agg stream -> ClickHouse / BigQuery
App Events -> Kinesis/PubSub -> S3 Iceberg + Kafka -> |
Dagster: assets = dbt models + python assets + data quality checks
Observability: OTel -> Grafana + Monte Carlo
```

### Stage 3
```
Multi-region App -> Local Kafka (Redpanda) -> Global Kafka (Confluent) with Tiered Storage S3
   -> Flink (sessionization, fraud) -> Iceberg Lake (S3) -> Trino / Snowflake (external tables)
   -> CDC (Debezium Connect) -> Postgres read models + Cache
Temporal for business workflows (payments)
Dagster asset lineage across lake+warehouse
Datadog/OpenLineage/Marquez for compliance
```

---

## 12. Anti-Patterns & Pitfalls

1. **Kafka too early** – introduces ordering/partitioning bugs, schema complexity for <100k/day.
2. **No raw landing** – transforming in-flight without saving raw = cannot reprocess. Always save raw.
3. **EL vs ELT confusion** – Don't transform before warehouse early. ELT (DBT after load) simpler.
4. **Spark for small data** – 100x cost, 10x latency vs DuckDB.
5. **Airflow as cron replacement** – Over-engineering <10 DAGs.
6. **No idempotency** – Duplicates at scale cause money bugs. Add `idempotency_key` unique index.
7. **Manual JSON logs** – Not queryable. Use structured + trace_id.
8. **No partitioning** – BigQuery scans full table $100 query. Partition by date, cluster by user_id.
9. **Premature exactly-once** – Aim at-least-once + idempotent consumer first.
10. **Building connectors** – API drift kills you. Buy Airbyte.

---

## 13. Final Checklist & Quick-Start Stack

### Quick-Start for AAI project (recommended)

**Stack: Serverless-first**
- Ingestion: FastAPI + Pydantic + SQS (or Upstash Redis Queue) or Cloudflare Workers + R2
- Storage: Supabase Postgres + S3 (Cloudflare R2 cheaper, zero egress) + Parquet
- Transformation: DuckDB + DBT Core + Polars
- Orchestration: Prefect Cloud free tier or Dagster OSS on Fly.io (single container)
- Observability: Sentry + Grafana Cloud free (Loki+Tempo+Prometheus) + OTel + DBT tests
- Cost: ~$50-150/mo to start, scales to $1k at 1M/day

**Manifest to provision:**
```
Neon Postgres      – app DB + queue via SKIP LOCKED
R2/S3 bucket       – raw/{source}/dt=%Y-%m-%d/hour=%H/
Prefect            – flows: ingest, transform_dbt, quality_check
DuckDB             – local & CI transforms
BigQuery sandbox   – optional when >100k/day
Grafana Cloud      – OTel + alert queue depth >1000
Airbyte OSS (ECS)  – when need 3rd-party connectors
```

### Decision Rubric: Should I Build Manually?
Score 1-5:
- Is it core IP? (5 = build)
- Does managed cost > engineering cost? (5 = build)
- Is ops risk low? (5 = build)
- Will I learn something career-critical? (5 = build)
- Does OSS exist 80% solved? (1 = buy)

>15: Build. <10: Buy.

### Key Vendors to Evaluate (2026)

- **Queues:** Upstash (Redis/Kafka), AWS SQS, GCP PubSub, Cloudflare Queues
- **Streaming managed:** Redpanda Cloud, Confluent Cloud, WarpStream (Kafka on S3, cheap)
- **Postgres managed:** Neon, Supabase, CrunchyBridge
- **Warehouse:** BigQuery, Snowflake, MotherDuck, ClickHouse Cloud, Tinybird
- **Orchestration:** Dagster Cloud, Prefect Cloud, Temporal Cloud, MWAA, Shipyard
- **Ingestion CDC:** Airbyte Cloud, Fivetran, Estuary, Decodable
- **Observability:** Grafana Cloud, Datadog, Honeycomb, BetterStack, Sentry
- **Lakehouse:** Tabular, Onehouse, Dremio, Starburst

### Sources & Further Reading
- Benchmark: DuckDB vs Spark: https://duckdb.org/docs/stable/clients/python.html
- Redpanda vs Kafka ops: Redpanda docs
- Dagster vs Airflow survey: 2024-2025 OSS trend
- WarpStream Kafka on S3 cost analysis
- BigQuery cost best practices (partitioning, clustering)
- OpenTelemetry Python instrumentation

---

# END OF REPORT
*Prepared for scout-pipeline-research – focus: small project that could grow – Build vs Buy*
