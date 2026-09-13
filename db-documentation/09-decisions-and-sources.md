# 09 — Decisions and sources

Accepted direction, proposed defaults, what was verified against the live service, and reference material. Read alongside [CONTEXT](CONTEXT.md) and [08](08-implementation-and-validation.md).

## Accepted decisions (locked)

- **One Tiger Cloud PostgreSQL service** holds ordinary tables and TimescaleDB hypertables. No SQLite server, no second Postgres, no message broker initially. SQLite remains **on-device only** (cache + outbox).
- **Ordinary tables are authoritative** for identity, ownership, balances, progression, battle results, and durable receipts. Hypertables hold time-organized facts and are never the sole copy of ownership, balance, or entitlement.
- **Player IDs stay `text`** (the API's `p_<hex>` contract). New domain/command IDs are UUIDs. Currency is integer units.
- **Game formulas live in versioned TypeScript, not SQL.** The DB enforces invariants (constraints, triggers, unique keys, transactions — `backend/migrations/0018`, asserted by `backend/tests/db/invariants.sql`); it does not re-implement loot/combat/Elo math. Behaviours like fusion, ranked settlement, multiplier recalculation, capsule opening and arena settlement are implemented in the backend against these tables.
- **Seven-tier rarity** is the parity baseline. `rules_version` is pinned on every reward-bearing operation.
- **Keys and capsules are distinct currencies** with no automatic conversion.
- **72-hour retention** applies only to battle-replay detail and device caches — never to collections, balances, meals, achievements, or battle results.
- **Continuous aggregates are for trends, not settlement.** Current daily state and wallet decisions read authoritative rows, never a delayed aggregate.

## Proposed defaults (tune with evidence)

- Chunk intervals: health/activity/gameplay 1 day, nutrition 7 days, battle_events 6 hours, battle_metrics 7 days ([04](04-timescale-design.md)).
- Continuous aggregates created `materialized_only = false` (real-time) so the app and demo see fresh data; background refresh policies run per [04](04-timescale-design.md).
- Columnstore/retention deferred (slice 6) so demo seed data does not age out.
- No hash/space partitioning, no per-player tables, no read replica or tiering initially.

## Verified against the live service (2026-09-12)

- Service `db-19576` (`j7s0lyqh6t`): TimescaleDB **2.30.0**, PostgreSQL **18.6**, DEV, `us-west-2`.
- `create_hypertable` succeeds for all six telemetry tables; hypertable/aggregate metadata visible in `timescaledb_information`.
- `CREATE MATERIALIZED VIEW … WITH (timescaledb.continuous, timescaledb.materialized_only=false)` and `add_continuous_aggregate_policy(...)` supported.
- `gen_random_uuid()` available built-in (PG18) — no `pgcrypto` needed for UUIDs.
- Writes/DDL require lifting the local `read_only` guard; the API's own `pg` role must be writable.

## Still to verify before/while wiring

- Columnstore (`hypercore`) APIs and any auto-created policies on this service version, before adding custom lifecycle policies.
- Behavior of hypertable foreign keys if later added (kept out for now; relationships go through ordinary parent tables per [04](04-timescale-design.md)).
- Actual credit balance / expiry and connection limits for pool sizing.
- Object-storage provider (gym photos, generated art) — still an open Phase-0 decision; the DB stores only metadata/refs in `app.media_objects`.

## Sources

- Tiger Data docs — https://www.tigerdata.com/docs
- Tiger Cloud is PostgreSQL + TimescaleDB — https://docs.tigerdata.com/integrations/latest
- Continuous aggregates — https://www.tigerdata.com/docs/learn/continuous-aggregates
- Retention with continuous aggregates — https://www.tigerdata.com/docs/learn/data-lifecycle/data-retention/data-retention-with-continuous-aggregates
- Hypertable unique-index rules — https://docs.tigerdata.com/use-timescale/latest/hypertables/hypertables-and-unique-indexes/
- Documented limitations — https://docs.tigerdata.com/timescaledb/latest/overview/limitations/
- Hypercore / columnstore — https://www.tigerdata.com/docs/learn/columnar-storage/understand-hypercore
- Tiger Cloud pricing — https://www.tigerdata.com/pricing
- `node-postgres` (`pg`) — https://node-postgres.com
- Tiger CLI: `tiger db query`, `tiger db save-password`, `read_only` config (`all`/`prod`).

Repository evidence checked for the parity audit is listed in [10](10-schema-parity-audit.md).
