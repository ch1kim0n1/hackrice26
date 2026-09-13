# 08 — Implementation and validation

Status: **first slice implemented.** The full schema (ordinary tables, hypertables, continuous aggregates) is deployed and seeded on Tiger Cloud DEV service `db-19576` (`j7s0lyqh6t`). No backend runtime is wired to it yet — that is the next task.

This document is the dependency-ordered plan and the merge gates. It supersedes the "design-only" posture recorded in earlier docs for the schema layer only; **application wiring is still unimplemented.**

## What is deployed now

| Layer | Objects | Migration file |
|---|---|---|
| Schemas | `app`, `telemetry`, `analytics`, `ops` | `0001` |
| Ordinary tables | `app` 64, `ops` 10 | `0001`–`0006` |
| Hypertables | `telemetry` ×6 | `0007` |
| Continuous aggregates | `analytics` ×4 (real-time) | `0008` |
| Demo data | 3 players, full loop | `backend/seed/0100_demo_seed.sql` |

Service: TimescaleDB **2.30.0** on PostgreSQL **18.6**, `us-west-2`, DEV, 0.5 cores / 2 GB.

Migrations were applied with `tiger db query -f`, using a per-command `TIGER_READ_ONLY=prod` override (this is a DEV service, so `read_only=prod` leaves it writable) while the persisted CLI/MCP config stays `read_only: all`.

## Validation actually run

- **Populated:** all six hypertables have rows; 64 `app` + 10 `ops` tables created.
- **Nutrition invariant:** signed `nutrition_deltas` net to 450 kcal for the corrected meal (600 intake − 600 reversal + 450 replacement). No double-count.
- **Real-time aggregate:** `analytics.health_hourly` returns bucketed rows immediately without waiting for the background policy (because `materialized_only = false`).
- **Cross-store join:** `app.battles ⋈ telemetry.battle_events` on `(id, stream_started_at)` returns the ordered replay — the flagship "one database, two storage models" query.

**Not yet validated:** concurrency/row-lock correctness, columnstore/retention lifecycle, backend integration, CI Timescale job, backup/fork recovery. These are gates below.

## Implementation slices (dependency order)

The schema slice (0) is done. Remaining slices wire the application.

0. **Schema + seed** — *done* (`0001`–`0008`, `0100`).
1. **DB access layer** — add `pg` + bounded `pg.Pool`; `DATABASE_URL` (TLS) replaces `NUTRIQUEST_DB`; a `schema_migrations` ledger table + a migration runner that applies `backend/migrations/*.sql` in order exactly once; a readiness endpoint that checks connectivity, the TimescaleDB extension, the migration version, and that the expected hypertables/aggregates exist.
2. **Async conversion** — introduce a shared async-handler wrapper (Express 4 does not forward rejected promises); convert `auth/store.ts`, `game/quests.ts`, `services/lootboxState.ts` + `routes/lootbox.ts`, `routes/scan.ts`, `routes/user.ts`, `routes/battle.ts`, `vitals/*` from synchronous `node:sqlite` to `pg`.
3. **Vitals vertical slice** — write normalized `health_samples`/`activity_observations`/`workouts`; expose a trend endpoint reading `analytics.health_hourly`.
4. **Transactional game state** — profiles, scan collection, dish workflow, quests, lootbox state, promos, squads, async battle feed, dungeon. Implement row locks/transaction boundaries (see §Concurrency) before enabling more than one backend instance.
5. **Event model** — append `food_scans`/`lootbox_opens`/`battle_events`/`economy_events`/`gameplay_events`; refresh/expose aggregates.
6. **Lifecycle** — columnstore + retention policies from [04](04-timescale-design.md) §Columnstore, guarded by `ops.lifecycle_checkpoints`. **Do not add retention before the demo unless seed data ages are adjusted, or recent seed rows will be dropped.**
7. **Cutover cleanup** — remove `node:sqlite` and `NUTRIQUEST_DB` once parity tests pass. (The dormant admin module, its npm dependency and the pre-TigerData schema directory are already gone.)

## Concurrency correctness (implement while porting, slice 4)

- Lootbox open: `select … for update` the player's `fairness_seeds`/`pity_state`/`wallets`; update seed nonce, pity, balance, character grant, and `crate_opens` receipt in one transaction; also append the open event.
- Quest claim: insert `quest_claims` and the currency/XP grant in one transaction.
- Promo redemption: redemption bookkeeping + reward grant in the same transaction.
- Dish confirmation: `update app.meal_drafts set … where analysis_status='ready'` (or `consumed=false`) `returning …` to mint the character exactly once.
- Battle settlement: result, XP, counters, `battle_metrics`, and receipts commit together.
- Retire the in-process `GameState` map; it is unsafe across multiple instances.

## Merge-to-main safety (the wiring concern)

Merging `dev-db` to `main` must not break the running app or CI. Watch these:

1. **The app on `main` still uses SQLite synchronously.** Merging the schema/migration files is inert (they are not imported at runtime). The app only changes behavior when slices 1–2 land. Merge the SQL + docs first; wire the runtime in a follow-up PR so a bad DB connection cannot take down the current build.
2. **Two competing DB branches exist.** `feat/db-alignment` hardens the *SQLite* runtime (migration runner, integrity constraints) and `fix/db-schema-enforcement` adds a CI DB-test job. Decide explicitly: TigerData/Postgres is the deploy target. Options — (a) keep SQLite for local unit tests and Postgres for integration/deploy, or (b) drop the SQLite path entirely at cutover. Do not merge all three without reconciling, or CI will try to enforce two different schemas.
3. **Secrets.** `DATABASE_URL` must be a TLS Tiger Cloud string, injected server-side (Railway env), never committed and never in the iOS/Watch bundle. The local `read_only: all` CLI/MCP config is a developer-safety setting and has no effect on the app's own `pg` connection — the app connects with its own role and must be writable.
4. **Migration idempotency.** `0001`–`0007` are mostly `IF NOT EXISTS`. `0008` is **not** idempotent (`CREATE MATERIALIZED VIEW` and `add_continuous_aggregate_policy` error on re-run). The slice-1 migration runner must record applied versions in `schema_migrations` and run each file once.
5. **Do not ship the seed.** `backend/seed/0100_demo_seed.sql` is for the demo/dev service only.
6. **Roles.** If the plan permits, create a restricted runtime role (no DDL) distinct from the migration role; keep RLS as optional defense-in-depth with a transaction-local player context (`app.current_player`).

## Merge/acceptance gates

The wiring is complete when:

- no runtime import references `node:sqlite`; no production setting references `NUTRIQUEST_DB`;
- the migration runner applies `backend/migrations/*` from empty and is idempotent under `schema_migrations`;
- TimescaleDB is enabled and the six hypertables + four aggregates appear in `timescaledb_information` views (verified: they do on `db-19576`);
- concurrent lootbox opens, quest claims, promo redemptions, and dish confirmations cannot double-spend or double-award;
- a restart and two simultaneous backend instances see consistent state;
- the Watch/iOS vitals path writes normalized samples and the trend endpoint reads a continuous aggregate;
- backup/restore or Tiger Cloud fork recovery is rehearsed;
- CI runs migrations against a TimescaleDB container (or isolated Tiger Cloud test service) before integration tests; pure game-formula tests stay database-free;
- source-of-truth docs describe the deployed system.
