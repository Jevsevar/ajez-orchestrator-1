# E-commerce Clickstream + Purchases — Sample Data Pipeline

This project provides **realistic sample datasets** for an e-commerce clickstream analytics pipeline. It is designed for the **small-project-growable research** direction: start tiny (100 users, 50 products, 500 events) but architecturally representative of a production funnel.

## Use Case

**Business scenario:** An online retailer wants to understand shopper behavior from browsing to checkout.

- **Users browse** products (view), add to cart, and occasionally purchase.
- **Analysts ask:** What's converting? Which referrer drives revenue? Which device/category performs best? What's our funnel drop-off?
- **Product asks:** Build personalization, real-time cart-abandonment nudge, daily revenue dashboards.

### Entities

- **Users:** 100 sample shoppers with email, country, tier (free/standard/premium/enterprise)
- **Products:** 50 products across 8 categories (Electronics, Apparel, Home, Books, Sports, Beauty, Toys, Grocery) with price and stock
- **Events:** 500 clickstream events over 7 days (view 70%, add_to_cart 20%, purchase 10%)
- **Purchases:** Enriched purchase fact derived from purchase events (~38 records)

All files ship in both **JSON and CSV**: JSON for OLTP / APIs / Mongo, CSV for warehouse, JSONL for streaming.

Location: `datasets/` (mirrored at worktree root)

```
datasets/
  users.json / users.csv (100)
  products.json / products.csv (50)
  events.jsonl / events.csv / events.json (~500)
  purchases.json / purchases.csv (~38)
schemas.md
README.md
```

## Pipeline Stages (How Data Would Flow)

This sample aligns to a **medallion / Lambda** architecture but runnable locally.

### 1. Ingestion

- **Sources:** Web SDK emits click events to HTTP collector; user/product tables via CDC from Postgres/ MySQL.
- **Streaming path:** Collect `events.jsonl` into Kafka topic `clickstream.raw` or Kinesis. Use a lightweight collector (Fluentd, Segment, Rudderstack) that writes JSONL. For this sample, `events.jsonl` simulates 1 line = 1 Kafka message.
- **Batch path:** Nightly dump of `users.csv`, `products.csv` from OLTP to S3 `s3://bucket/raw/users/date=.../`
- **Considerations at small scale:** Start with files + DuckDB. Grow to Kafka once >1k EPS. This sample's JSONL makes that migration trivial: `cat events.jsonl | kafka-console-producer`.

### 2. Storage (Bronze → Silver → Gold)

- **Bronze (raw):** Land exactly as received in object store / local `raw/`. Keep both JSONL and CSV, partitioned by date: `raw/events/dt=2026-07-28/events.jsonl`. Schema-on-read, immutable, append only.
- **Silver (cleaned / conformed):** Parse timestamps to UTC, deduplicate by (user_id, product_id, timestamp, session_id). Validate FK: filter events where user_id not in users, product_id not in products. Write as Parquet partitioned by `event_date` and `event_type`. At tiny scale, DuckDB can read CSV directly and emit Parquet.
- **Gold (business):** Star schema:
  - `dim_users` (from users.csv, SCD Type1)
  - `dim_products` (SCD Type2 if price history needed; here Type1 for simplicity)
  - `fact_events` (cleaned events)
  - `fact_purchases` (joined + aggregated) – this sample already provides a gold-like `purchases.csv`
- **Growable I:** Start local: `datasets/` is your bronze. Use `duckdb` or `pandas` to produce `silver/`. Later swap to Delta Lake / Iceberg on S3.

### 3. Transform

**Batch transforms (daily, Airflow / Dagster / Prefect):**
- Funnel: view → cart → purchase conversion per category/referrer/device
- Sessionization: group by session_id, compute duration, bounce rate, events per session
- User aggregation: DAU, WAU, LTV proxy per tier/country
- Product performance: views, cart-add rate, out-of-stock hits
- Data quality checks: Great Expectations – e.g., purchase total >0, event_type in enum, timestamp within 7d

**Streaming transforms (Flink / Spark Structured Streaming / Materialize):**
- Real-time: filter `add_to_cart` not followed by `purchase` within 30 min → emit abandonment event
- Upsert counting: 5-min tumbling window count of views per product_id

Example (pseudocode, growable from small):
```python
# tiny version
import duckdb
con = duckdb.connect()
con.sql("CREATE TABLE events AS SELECT * FROM 'datasets/events.csv'")
con.sql("COPY (SELECT category, SUM(total_amount) FROM 'datasets/purchases.csv' GROUP BY category) TO 'gold_revenue.parquet'")
# production version: same SQL, but source = Delta table
```

### 4. Analytics & Serving

- **BI:** Dashboard in Metabase / Superset / Looker: Revenue by category, funnel by referrer/device, DAU trend, top products.
- **Adhoc:** Schema examples in `schemas.md` – run with DuckDB, BigQuery, Snowflake.
- **ML / Personalization:** Features from events (last viewed categories, cart add rate) → train recommendation ranking model; this dataset is tiny but feature schema matches prod.
- **Operational:** Purchase table powers order follow-up, email trigger.

**Growable path research-aligned:**
- **Phase 0 (now):** Files + DuckDB + local Python notebook. < $0 cost, < 1 sec queries.
- **Phase 1:** Add Postgres for users/products (OLTP), keep events in S3 Parquet, use dbt for transforms.
- **Phase 2:** Kafka + Flink for real-time funnel, Delta Lake bronze/silver/gold, Airflow orchestration.
- **Phase 3:** Feature store (Feast) + model serving from gold features.

### Why this use case fits small-project-growable?

- Starts trivial: 100 users synthetic – no privacy concerns, runs on laptop.
- Funnel pattern generalizable to SaaS, media, gaming.
- Both batch + streaming relevant (cart abandonment real-time, revenue daily batch).
- Schema intentionally includes dimensions needed for joins, thus forces dim/fact thinking.
- Easy to scale: change generator seed to 10k users, 100k events → same pipeline, only partitioning changes.

## How to Regenerate Larger

```bash
# edit /tmp/gen.py NUM_USERS=10000 and run again
python3 /tmp/gen.py  # outputs to datasets/
```

Seed 42 deterministic, weighted distributions ensure realistic shape even at small N.

## Files

- `schemas.md` – detailed schema + sample queries
- `datasets/*.json` – JSON array (OLTP style)
- `datasets/*.csv` – CSV (warehouse)
- `datasets/events.jsonl` – JSON lines (streaming)
- `datasets/purchases.*` – derived fact

## License / Notes

Synthetic data only. Emails are `@example.com` per RFC2606. Product names generic, prices fictitious.
