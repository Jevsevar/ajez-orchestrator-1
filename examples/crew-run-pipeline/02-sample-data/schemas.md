# Schemas – E-commerce Clickstream Sample Datasets

This document describes the schemas for all generated sample datasets. All files live in `datasets/` and are also mirrored at worktree root for convenience.

## Overview

| Dataset | Files | Count | Formats |
|---------|-------|-------|---------|
| users | users.json, users.csv | 100 | JSON array, CSV |
| products | products.json, products.csv | 50 | JSON array, CSV |
| events (clickstream) | events.jsonl, events.csv, events.json | ~500 (500) | JSONL (1 obj/line), CSV, JSON array |
| purchases (derived) | purchases.json, purchases.csv | 38 (10-12% of events) | JSON array, CSV |

---

## 1. users

Represents registered shoppers.

| Column | Type | Description | Example |
|--------|------|-------------|---------|
| id | string | Primary key, `user_0001` format | `user_0001` |
| email | string | Fake email | `emma.smith123@example.com` |
| created_at | ISO8601 string (UTC) | Account creation time, spread over last 2 years | `2024-11-03T08:22:11+00:00` |
| country | string (ISO2) | Country code, weighted: US 28%, IN 12%, DE 10%, UK 8%, BR 6%, others | `US` |
| tier | string enum | Subscription tier: free (50%), standard (25%), premium (20%), enterprise (5%) | `premium` |

**Constraints:**
- id unique, indexed
- email syntactically valid but not real
- country from set: US, DE, IN, UK, BR, CA, FR, JP, AU, MX, NG, SE, NL, SG, ZA, IT

**Sample JSON:**
```json
{
  "id": "user_0042",
  "email": "ravi.kumar87@example.com",
  "created_at": "2023-08-15T14:22:33+00:00",
  "country": "IN",
  "tier": "standard"
}
```

---

## 2. products

50 products across 8 categories.

| Column | Type | Description | Example |
|--------|------|-------------|---------|
| id | string | PK `prod_0001` | `prod_0007` |
| name | string | Human-readable product name | `Wireless Headphones` |
| category | string enum | One of 8 categories | `Electronics` |
| price | float | Unit price USD, category-dependent range | `59.99` |
| stock | int | Units in inventory, 0-500 | `127` |

**Categories & price ranges:**
- Electronics: $25-299
- Apparel: $15-120
- Home: $12-180
- Books: $8-45
- Sports: $10-150
- Beauty: $9-85
- Toys: $10-90
- Grocery: $5-40

**Sample:**
```json
{
  "id": "prod_0003",
  "name": "Mechanical Keyboard",
  "category": "Electronics",
  "price": 129.5,
  "stock": 42
}
```

---

## 3. events (clickstream)

Core fact table: ~500 events across 7 days, realistic funnel distribution.

| Column | Type | Description | Example |
|--------|------|-------------|---------|
| user_id | string FK | References users.id | `user_0023` |
| product_id | string FK | References products.id | `prod_0012` |
| event_type | enum string | view (70%), add_to_cart (20%), purchase (10%) | `view` |
| timestamp | ISO8601 UTC | Event time within last 7 days, sorted asc | `2026-07-28T14:05:00+00:00` |
| session_id | string | Session grouping: `sess_00001`, 1-4 per active user | `sess_00042` |
| device | enum | mobile 60%, desktop 30%, tablet 10% | `mobile` |
| referrer | enum | google 30%, direct 25%, facebook 12%, instagram 10%, email 8%, twitter 5%, bing 4%, affiliate_blog 3%, youtube 3% | `google` |
| page | string | Page path: /products/{id}, /category/{cat}, /cart, /checkout | `/products/prod_0012` |

**Generation logic:**
- 70% of 100 users active in last 7 days (30% dormant)
- Each active user: 1-4 sessions (weights 0.5,0.3,0.15,0.05)
- Each session: 1-8 events, time increments 10s-15min
- Funnel realism: first event always view (85%) or add_to_cart; purchase more likely after add_to_cart
- Stock check: if product stock==0, purchase coerced to view

**Sample JSONL line:**
```json
{"user_id": "user_0010", "product_id": "prod_0005", "event_type": "view", "timestamp": "2026-07-25T09:12:33+00:00", "session_id": "sess_00010", "device": "mobile", "referrer": "google", "page": "/products/prod_0005"}
```

**File notes:**
- `events.jsonl` – best for streaming ingestion (Kafka/Kinesis)
- `events.csv` – for warehouse/BigQuery/Spark
- `events.json` – same data as array (convenience)

---

## 4. purchases (joined / derived)

Derived from events where event_type=purchase, enriched with user + product dims.

| Column | Type | Description |
|--------|------|-------------|
| purchase_id | string PK | `pur_00001` incremental |
| user_id | string FK | to users |
| user_email | string | denormalized |
| user_country | string | denormalized |
| user_tier | string | denormalized |
| product_id | string FK | to products |
| product_name | string | denormalized |
| category | string | product category |
| unit_price | float | at time of purchase |
| quantity | int | 1 (75%), 2 (20%), 3 (5%) |
| total_amount | float | unit_price * quantity |
| timestamp | ISO8601 | = event timestamp |
| session_id | string | originating session |
| device | string | device |
| referrer | string | referrer |

**Count:** ~38 purchases (expect 35-60 with seed 42, ~7-12% of events)

**Sample:**
```json
{
  "purchase_id": "pur_00007",
  "user_id": "user_0015",
  "user_email": "sofia.garcia42@example.com",
  "user_country": "MX",
  "user_tier": "premium",
  "product_id": "prod_0022",
  "product_name": "Yoga Mat",
  "category": "Home",
  "unit_price": 34.99,
  "quantity": 2,
  "total_amount": 69.98,
  "timestamp": "2026-07-27T16:44:10+00:00",
  "session_id": "sess_00018",
  "device": "mobile",
  "referrer": "instagram"
}
```

---

## Example Queries (SQL / DuckDB / SparkSQL)

### Conversion funnel
```sql
SELECT
  COUNT(*) FILTER (WHERE event_type='view') AS views,
  COUNT(*) FILTER (WHERE event_type='add_to_cart') AS carts,
  COUNT(*) FILTER (WHERE event_type='purchase') AS purchases,
  ROUND(100.0 * COUNT(*) FILTER (WHERE event_type='purchase') / NULLIF(COUNT(*) FILTER (WHERE event_type='view'),0),2) AS view_to_purchase_pct
FROM events;
```

### Revenue by category (last 7 days)
```sql
SELECT category, SUM(total_amount) AS revenue, COUNT(*) AS orders
FROM purchases
GROUP BY category
ORDER BY revenue DESC;
```

### Top products by views
```sql
SELECT p.name, p.category, COUNT(*) AS view_count
FROM events e JOIN products p ON e.product_id=p.id
WHERE e.event_type='view'
GROUP BY p.id, p.name, p.category
ORDER BY view_count DESC LIMIT 10;
```

### Device & referrer breakdown
```sql
SELECT device, referrer, COUNT(*) AS events, COUNT(DISTINCT user_id) AS users
FROM events
GROUP BY device, referrer
ORDER BY events DESC;
```

### User LTV proxy
```sql
SELECT u.tier, u.country, COUNT(DISTINCT u.id) AS users, SUM(p.total_amount) AS total_spent
FROM users u LEFT JOIN purchases p ON u.id=p.user_id
GROUP BY u.tier, u.country;
```

### Sessionization
```sql
SELECT session_id, user_id, MIN(timestamp) AS start, MAX(timestamp) AS end,
       COUNT(*) AS events, SUM(CASE WHEN event_type='purchase' THEN 1 ELSE 0 END) AS purchases
FROM events GROUP BY session_id, user_id ORDER BY start;
```

### Cohort retention prep
```sql
SELECT DATE_TRUNC('day', e.timestamp) AS day, COUNT(DISTINCT e.user_id) AS dau
FROM events e GROUP BY 1 ORDER BY 1;
```

## Data Quality Notes

- Intentional edge cases: stock=0 products, dormant users, sessions with single event
- Timestamps intentionally out-of-order in raw generation but sorted in output for convenience
- Email uniqueness not 100% guaranteed (first.last+number collision possible but rare)
- UTF: plain ASCII for simplicity (no unicode in product names)
- Growable: seed 42 for reproducibility; regenerate larger by looping more users/products

## Extensibility

- Add `payments.json` with fraud, payment_method
- Add `reviews` table
- Add `inventory_changes` CDC stream
- Add geo/ip, A/B test variant, promo_code fields to events
