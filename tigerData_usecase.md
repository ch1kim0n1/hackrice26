# TigerData in NutriQuest — use case, rationale, and roadmap

> **Living document.** Update this whenever we add a feature, fix a bug, or polish something that touches the database. Add a dated line to the **Update log** at the bottom. Keep the top sections current so a newcomer can understand *why* TigerData is here in five minutes.

Last updated: 2026-09-12.

---

## 1. What TigerData is, in this project

NutriQuest runs on **one Tiger Cloud database** (service `db-19576`). It is plain PostgreSQL 18 with the **TimescaleDB** extension turned on. That single database holds two kinds of tables:

- **Ordinary PostgreSQL tables** (`app`, `ops` schemas) — the things that must always be correct: accounts, characters you own, your key/capsule balance, battle results, receipts.
- **TimescaleDB hypertables** (`telemetry` schema) — the things that pile up over time: Apple Watch readings, food logs, battle replay events, gameplay history. Plus **continuous aggregates** (`analytics` schema) that pre-compute trends.

The key idea: **it's one database, so a single SQL query (and a single transaction) can touch both.** We did not bolt a separate time-series database onto Postgres.

---

## 2. Where TigerData actually shined (ranked by real value)

### 2.1 Apple Watch / HealthKit data — the most natural fit ⭐
Heart rate, HRV, resting HR, steps, and rings are a genuine time series. We store each reading in the `telemetry.health_samples` hypertable and pre-compute hourly summaries in the `analytics.health_hourly` continuous aggregate.
- **Why it shined:** the Health/Journey dashboard reads *live recent readings* and *long-term trends* from the same place, and the trend query never has to re-scan months of raw data.
- **Correctness we get for free-ish:** time-bucketing, and the discipline to keep cumulative rings (2,000 → 2,600 steps means 2,600, never 4,600) and to leave missing data missing instead of inventing zeros.

### 2.2 One database, two storage models — the biggest architectural win ⭐
We can run `app.battles ⋈ telemetry.battle_events` (relational battle row joined to its time-series event stream) in **one query, one transaction**.
- **Why it shined:** a separate time-series DB would force us to copy data back and forth (ETL), keep two systems in sync, and give up transactional consistency. For a small team, **not operating two databases** was the single biggest payoff.

### 2.3 Battle replay with automatic expiry — the signature lifecycle story ⭐
Battle events go into `telemetry.battle_events`, chunked every 6 hours by the battle's start time, so every battle's events sit together in one chunk. Replay detail is meant to live ~72 hours; the compact result lives forever in `app.battle_results`.
- **Why it shined:** "keep the detail briefly, keep the outcome forever" maps cleanly onto Timescale chunk retention — you drop whole old chunks cheaply instead of deleting millions of rows.

### 2.4 Append-only game analytics
`nutrition_deltas` (signed food-log legs that never double-count a correction), `gameplay_events`, and `battle_metrics` feed continuous aggregates for nutrition trends, engagement, rarity distribution, and win rates.
- **Why it shined:** these are write-once, read-as-trends workloads — exactly what continuous aggregates are for.

---

## 3. Why we chose it — specific reasons

| Reason | Concrete payoff in NutriQuest |
|---|---|
| The app mixes "must be exact" state with "piles up over time" data | Wallets/ownership stay in ordinary tables; readings/events go in hypertables — **in the same DB**. |
| We are a small team | One managed service, one connection driver (`pg`), one backup story. No second database to run. |
| Health + game history are real time series | Hypertables + continuous aggregates give cheap trends without re-scanning raw history. |
| We need "recent detail, permanent summary" | Chunk-based retention expires replay/raw data while compact results/receipts persist. |
| We want a strong, honest demo | We can show live ingestion → hypertables → raw+aggregate query → relational join → retention, all on one service. |

**We deliberately did NOT make everything a hypertable.** The 64 ordinary `app` tables (accounts, wallets, promos, rankings) are point-lookups and frequently-updated current state — wrong for a time series. TigerData's value here is that they *coexist* with the hypertables, not that they're on Timescale.

---

## 4. What's live today (2026-09-12)

- Service `db-19576`, TimescaleDB **2.30**, PostgreSQL **18**, `us-west-2` (DEV).
- **64** ordinary `app` tables, **10** `ops` tables, **6** hypertables, **4** continuous aggregates.
- Seeded with a 3-player end-to-end demo (health → nutrition → battle → economy).
- Migrations: `backend/migrations/0001`–`0009`; demo seed `backend/seed/0100`.
- Verified: nutrition corrections don't double-count; real-time aggregate returns data; relational↔time-series join works.

See `db-documentation/` for the full design (01–10) and validation.

---

## 5. How we can improve it in the future

Ordered roughly by leverage. Check items off and note them in the Update log as they land.

- [ ] **Lifecycle policies** — turn on columnstore compression for older retained facts and time-based retention for raw health/activity. *(Timescale's headline feature; big win to demonstrate.)*
- [ ] **Gap-filled health trends** — use `time_bucket_gapfill` + LOCF so charts handle missing readings correctly instead of showing holes or fake zeros.
- [ ] **Hierarchical aggregates** — roll a daily summary up from the hourly aggregate (aggregate-on-aggregate) for the Journey screen.
- [ ] **Guarded battle-event cleanup** — a job that drops battle chunks only after outcomes are settled and >72h old, tracked in `ops.lifecycle_checkpoints` (not a blind retention policy, which could delete an active battle).
- [ ] **Chunk-exclusion proof** — keep an `EXPLAIN (ANALYZE, BUFFERS)` example in the repo showing a query scans one chunk, not all history.
- [ ] **Real-time vs materialized tuning** — measure ingestion lag, then decide per-aggregate whether the live tail is worth it.
- [ ] **Restricted runtime role + RLS context** — app connects as a non-owner role; every request sets its player context so row-level security is real defense-in-depth.
- [ ] **CI against a Timescale container** — apply migrations and run integration tests in CI before merge.
- [ ] **Backup/fork rehearsal** — practice restoring from a Tiger Cloud fork so recovery is proven, not assumed.
- [ ] **Object storage decision** — pick the provider for gym photos / generated art; the DB only stores references (`app.media_objects`).

### Known limitations / gotchas to remember
- Hypertable unique keys **must** include the time column (that's why keys look composite).
- Continuous aggregates can't join multiple hypertables — aggregate one source, join small results afterward.
- `0008` (aggregates) is **not** re-runnable; the migration runner must track applied versions.
- Retention drops whole chunks — never point a blind retention policy at `battle_events` (could delete an unsettled battle).

---

## Update log

- **2026-09-12** — Initial version. Schema deployed + seeded on `db-19576`; documented where TigerData shined and the improvement roadmap. Runtime still on SQLite; wiring in progress.
