# Architecture changelog

## 2026-09-12 — Full hypertable coverage + all features wired; DB readiness verified

- **All 8 hypertables now fed by live features.** Wired the last two: `nutrition_deltas` (dish-photo confirm → intake leg, `routes/scan.ts` + `db/repositories/nutritionRepo.ts`) and `body_metrics` (weight update via `PUT /user/:id` → weigh-in, using `recordBodyMetric`).
- **Remaining feature areas wired to the gameplay-event stream:** dungeon run, character sell, character merge → `telemetry.gameplay_events` (`routes/characters.ts`, `battle.ts` dungeon). Casino (mines/plinko/crash) already feeds `gamble_events`.
- **Casino demo seed** (`seed/0104_casino_seed.sql`): mines_rounds, plinko_drops, and 6 `gamble_events` so every hypertable shows data.
- **DB readiness verified on `db-19576`:** 8 hypertables, 5 continuous aggregates, 82 ordinary tables, 53 RLS-enabled tables, TimescaleDB 2.30, latest migration 0015. Every hypertable has rows; `analytics.gamble_hourly` returns real-time rows.
- **Verified:** `tsc` clean; **12/12 integration tests pass vs live Tiger Cloud** (incl. a full-coverage assertion that all 8 hypertables exist); full suite **376 passed / 12 skipped** (only the pre-existing Windows temp-file EPERM teardown quirk).

## 2026-09-12 — Casino/gambling wired to TigerData (mines, plinko, crash)

- Synced `dev-db` with `main` (Phase 2/3/4: attacks, stars, ranks, goals, catalog, Plinko, Mines, coins/locks, revaluation). Phase 2 was completed on main — not duplicated here; took main's canonical game logic on conflict, kept the TigerData mirror layer + re-applied battle/quest mirror hooks.
- **`0015_casino.sql`** (applied to `db-19576`): `app.mines_rounds` (mine `layout` withheld from the restricted role via a column grant — verified), `app.plinko_drops`, and the **`telemetry.gamble_events` hypertable** (8th hypertable) with a real-time `analytics.gamble_hourly` rollup. Crash reuses `app.cauldron_rounds` (0012); coins reuse `currency_entries` (currency='coins').
- **Wiring (best-effort mirror):** `db/repositories/gambleRepo.ts` mirrors mines (start/reveal/cashout), plinko (drop), cauldron (start/cashout) into the authoritative tables + appends to `gamble_events`; hooks in `routes/{mines,plinko,cauldron}.ts` behind `hasDatabaseUrl()`. SQLite stays source of truth.
- **Verified:** `tsc` clean; **4/4 casino integration tests pass vs live Tiger Cloud** (incl. layout hidden from the app role + gamble_hourly rollup); full suite **376 passed / 10 skipped** (only the pre-existing Windows temp-file EPERM teardown quirk across SQLite suites).

## 2026-09-12 — Feature wiring begins (best-effort mirror) + runbook

- **Strategy:** additive best-effort mirror — SQLite stays the app's source of truth; features also write normalized rows into TigerData when `DATABASE_URL` is set. No-op (and SQLite tests unaffected) when it isn't. Full recipe + status table in [12 wiring runbook](12-wiring-runbook.md).
- **Wired (5 features):** vitals → `health_samples`/`activity_observations`/`workouts`; PvP friend battle → `battles`/`battle_participants`/`battle_events`/`battle_metrics`; scan → `gameplay_events`; lootbox open → `gameplay_events`; quest claim → `gameplay_events`.
- **New code:** `db/repositories/{players,healthRepo,gameEventsRepo,battleRepo}.ts` (+ `ensurePlayer` upsert so runtime player ids satisfy FKs). Routes call mirrors best-effort behind `hasDatabaseUrl()`.
- **Hypertable coverage: 6 of 7 fed by live features** (`health_samples`, `activity_observations`, `battle_events`, `battle_metrics`, `gameplay_events`). Remaining: `nutrition_deltas` (dish confirm) and `body_metrics` (weigh-in route — repo ready).
- **Verified:** `tsc` clean; **6/6 integration tests pass vs live Tiger Cloud** (health + gameplay + PvP battle); full suite **258 passed / 6 skipped** (integration gated on `DATABASE_URL`; only the pre-existing Windows EPERM teardown quirk remains).
- **~9 features remain** to wire; order + exact steps in [12](12-wiring-runbook.md).

## 2026-09-12 — Sync with main + schema alignment for new features

- Merged `origin/main` into `dev-db` (main advanced with casino/gambling, star economy, rank points, body metrics, coin ledger, 14-char roster, human-gate, and the merged `feat/db-alignment` SQLite runner + `fix/db-schema-enforcement` CI). Resolved the `docs/README.md` doc-index conflict keeping both sets. Merged `index.ts` retains both `readinessRouter` and main's `cauldronRouter`.
- **Re-audit of post-merge features** → only new runtime table was `cauldron_round`; the star/rank/body/coin schema landed in `backend/migrations/0012`.
- **`0012_main_feature_alignment.sql`** brings TigerData to parity: `coins` currency on `wallets`; `app.rankings.rank_points`/`rank_tier`; `app.owned_characters.star_level` (1–5); `profile_versions.body_type`; new `app.cauldron_rounds` (casino); new **`telemetry.body_metrics` hypertable** (weigh-in trend, 7th hypertable). Seeded via `0102_new_features_seed.sql`.
- **Verified:** `tsc` clean; **258/258 tests pass** (only the pre-existing Windows temp-file EPERM teardown quirk); all app/ops tables + 7 hypertables populated.

## 2026-09-12 — Planned-feature wiring plan added

- Added [11 Planned-feature wiring plan](11-planned-features-wiring-plan.md): build order and transaction design for every feature that is schema-covered but not yet implemented in application code — lore/art content, fusion, gym-photo verification + training buffs, LAN casual PvP/tournaments (`origin/dev`, not merged), ranked matchmaking/Elo/fatigue, arena stakes, seasons. Documentation only; no code, migration, or merge.
- No change to deployed schema or runtime. Depends on main-branch wiring slices 1–5 in [08](08-implementation-and-validation.md) landing first — every planned feature reuses `db/pg.ts`, `withPlayer`, and the command-receipt/event patterns those slices introduce.

## 2026-09-12 — Integration slice: lifecycle, RLS, runtime foundation, CI

- **Lifecycle** (`0010_lifecycle_policies.sql`): columnstore compression on `nutrition_deltas`/`battle_metrics` after 7 days; retention on raw health/activity (7d), gameplay (30d), battle_metrics (365d), and the hourly aggregates (365d). `battle_events` intentionally has **no** blind retention (guarded cleanup only).
- **RLS** (`0011_rls_policies.sql`): restricted `nutriquest_app` role (NOLOGIN, secret-free) + player-isolation policies keyed on the `app.current_player` transaction setting. Verified: scoped role sees only the player's rows; unset context leaks 0 rows. Skips the two columnstore hypertables (RLS unsupported there).
- **Runtime foundation** (additive, SQLite untouched): `backend/src/db/pg.ts` (bounded pool + `withPlayer` RLS transaction helper), `backend/src/db/migrate-pg.ts` (runner + `ops.schema_migrations` ledger), `backend/src/http/asyncHandler.ts`, `backend/src/routes/readiness.ts` (`/ready`). `pg` added to backend deps. Ledger backfilled for `0001`–`0011` on `db-19576`.
- **Verified end-to-end:** `npx tsc` clean; 188/188 tests pass (only the pre-existing Windows temp-file `EPERM` teardown quirk remains); the pg layer connects to Tiger Cloud over TLS and readiness returns `ready:true` (timescale 2.30, 6 hypertables, 11 migrations).
- **CI** (`.github/workflows/tigerdata-db.yml`): applies migrations to a TimescaleDB container via the runner, re-runs to prove idempotency, and smoke-checks 6 hypertables + 4 aggregates.
- **Backup rehearsal:** runbook added (`backup-rehearsal.md`); execution needs Tiger Cloud platform write (human step) — not performed by read-only tooling.
- **Still pending:** porting each existing route from synchronous `node:sqlite` to async `pg` (bulk of runtime wiring) and per-flow row-lock transactions; these proceed slice-by-slice with tests.

## 2026-09-12 — First implementation slice: schema deployed and seeded

- **Authorization changed:** the user lifted the earlier design-only restriction and asked for implementation.
- **Target service inspected:** Tiger Cloud DEV service `db-19576` (`j7s0lyqh6t`), region `us-west-2`, TimescaleDB **2.30.0** on PostgreSQL **18.6**. Service was empty (no prior schema/seed) before this slice.
- **Schema applied** from docs [03](03-relational-model.md)/[04](04-timescale-design.md). New SQL lives in `backend/migrations/`:
  - `0001_schemas_identity.sql` … `0006_ops.sql` — 4 schemas (`app`, `telemetry`, `analytics`, `ops`) + ordinary tables.
  - `0007_timeseries_hypertables.sql` — the six `telemetry` hypertables via `create_hypertable`.
  - `0008_continuous_aggregates.sql` — four `analytics` continuous aggregates (`materialized_only = false`) + refresh policies.
  - Deployed object count: **app 64 base tables, ops 10, telemetry 6 hypertables, analytics 4 continuous aggregates**.
- **Demo seed** (`backend/seed/0100_demo_seed.sql`) — three players exercising the end-to-end loop (health → activity → nutrition → gameplay → battle → economy). **Seed is demo-only; never load into production.**
- **Validation actually run** against the live service (read-only reads):
  - Row counts populated across all six hypertables.
  - Nutrition no-double-count invariant holds: corrected meal nets 450 kcal (600 intake − 600 reversal + 450 replacement), not 1050.
  - Real-time continuous aggregate returns data immediately (health_hourly bucketed by player/metric).
  - Cross-store join works: `app.battles ⋈ telemetry.battle_events` returns the ordered replay.
  - NOT run: concurrency/row-lock correctness, columnstore/retention lifecycle, backend integration (no runtime wiring yet), CI Timescale job.
- **Access/safety:** applied through `tiger db query` with a per-command `TIGER_READ_ONLY=prod` override so this DEV service was writable; the persisted CLI/MCP config remains `read_only: all`. No credentials in Git or the app. Nothing committed, pushed, or merged.
- **Feature parity audit** completed across repo + branches; see [10](10-schema-parity-audit.md). Verdict: all features covered; three minor non-blocking gaps recorded.
- **Parity cleanup applied:** `0009_presence_account_kind.sql` adds `app.players.last_seen_at`, `comeback_pending_at`, and `kind` (`guest`/`registered`), resolving audit gaps 1 and 2. Gap 3 (object-storage provider) is an external decision, not a migration.
- **Docs added:** [08 implementation and validation](08-implementation-and-validation.md), [09 decisions and sources](09-decisions-and-sources.md), [10 schema parity audit](10-schema-parity-audit.md).

## 2026-09-11 — Initial complete design

- Created `dev-db` from freshly fetched `origin/main` at `f7a9e4e`.
- Added the architecture, feature inventory, relational model, six-hypertable design, live battle workflow, retention/offline rules, security/operations plan, and staged validation gates.
- Clarified that ordinary PostgreSQL and TimescaleDB run together in one Tiger Cloud database.
- Adopted a 72-hour battle replay/device raw-cache default while preserving compact results, ownership, economy receipts, nutrition history, and progression.
- Designed guarded cleanup, idempotent commands, source-aware health ingestion, signed nutrition corrections, and versioned battle snapshots.
- Included LAN PvP/tournaments as an explicitly separate, unranked future integration based on inspected `origin/dev` source.
- Preserved prior working changes outside this folder. No runtime implementation, credentials access, cloud mutation, push, or merge.
- Documentation validation: pending final check.

## Update convention

For each implementation slice, add the date, completed scope, changed contracts, tests actually run and their results, remaining blockers, and next action. Link a commit or PR only after it exists. Never include tokens, connection strings, health payloads, or private photos.
