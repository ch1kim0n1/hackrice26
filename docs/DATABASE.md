# NutriQuest — the database system

One domain model, implemented for two deployment modes.

- **SQLite** (`node:sqlite`, `backend/src/db/`) — what runs today, on Railway and
  on a laptop. Single file, no server, no network.
- **TigerData** (`backend/migrations/`) — the production target: Tiger Cloud
  Postgres with TimescaleDB. It models the complete game and adds the `telemetry`
  hypertables, `analytics` continuous aggregates, database-level rule enforcement
  and row-level security.

SQLite deliberately keeps several runtime documents as validated JSON while
Postgres normalizes the same production concepts. The migration and invariant
tests are the executable contracts for their respective engines.

## Why this exists

The two halves had grown apart to the point of describing different games:

| | SQLite (live) | Postgres (canonical) |
|---|---|---|
| Identity | `player_id` — any 6–64 char string, self-asserted | `players.id uuid` → `auth.users`, enforced |
| Nutrition profile | *nothing* | `profiles` + server-derived targets |
| Daily multiplier | *nothing* | `day_logs`, `daily_state` |
| Economy | `lootbox_*`, `promo_*`, `quest_claim` | `capsule_ledger`, `capsule_pity` |
| Loot boxes, vitals, dungeon, async PvP | shipped | *nothing* |

`backend/src/game/targets.ts` and `multiplier.ts` — the Daily Party Multiplier
the README leads with — were dead code, imported by nothing but their own tests,
because no table anywhere stored a nutrition profile.

## The rules

1. **One identity concept.** `players` is the ownership anchor in both engines;
   child records use `player_id`.
2. **Postgres is canonical; SQLite is the local adapter.** SQLite stores only
   features the current Express backend serves and may keep API payloads as
   JSON. Postgres contains the normalized production model.
3. **`players` is the anchor.** Every player-scoped row references it and dies
   with it (`ON DELETE CASCADE`). Deleting a player deletes that player.
4. **Enforce rules at the database boundary.** SQLite validates JSON and
   booleans/ranges and enforces foreign keys. Postgres adds richer checks,
   triggers, functions, and RLS.
5. **Every schema change is a numbered migration.** On both engines. No
   `CREATE TABLE IF NOT EXISTS` as an import side effect.

## Identity, and the one place the engines genuinely differ

Postgres keys players by `uuid` and derives the caller from a verified JWT
(`auth.uid()`), which is what makes RLS work. SQLite accepts a client-supplied
`X-Player-Id` header of arbitrary text, which is what makes the hackathon demo
work without a login.

These cannot be made identical without breaking one of them, so the bridge is
explicit rather than pretended away:

- `player_id` is **TEXT** in SQLite, **uuid** in Postgres.
- New accounts are issued **UUIDs** as their `player_id`. A UUID is valid under
  the existing `^[A-Za-z0-9_-]{6,64}$` header pattern, so nothing breaks and new
  rows are natively portable.
- Legacy ids (`p_…`, or anything a client asserted) keep working. They are
  non-portable, and `players.is_portable` records that, so the eventual copy
  into Postgres knows which rows need a generated UUID.

Header-asserted identity is a demo affordance, not a security boundary. The
backend is the gate; in Postgres, RLS is the backstop behind it.

## Layout

```
backend/src/
├─ db.ts             opens the file, applies migrations, exports `db`
└─ db/
   ├─ migrate.ts     PRAGMA user_version runner; one transaction per migration
   ├─ migrate.test.ts fresh, upgrade, rollback, FK and constraint tests
   ├─ migrations/    numbered, append-only TypeScript migrations
   ├─ pg.ts          Tiger Cloud pool; withPlayer() sets the RLS player context
   └─ migrate-pg.ts  Postgres runner, ledgered in ops.schema_migrations

backend/migrations/  0001–0018 canonical production model (Postgres)
backend/seed/        0100–0104 demo fixtures
backend/tests/db/    invariants.sql — the game's rules, asserted in SQL
backend/scripts/     check-pg-schema.js, run-db-invariants.js, apply-sql-dir.js
```

## Migrations

**SQLite.** `PRAGMA user_version` holds the last applied number. Each migration
runs inside a transaction with foreign keys deferred, and the version bumps only
if it commits. A database that already has today's tables migrates in place —
the runner never assumes an empty file.

Adding a constraint to an existing SQLite table means rebuilding it (SQLite has
no `ALTER TABLE ADD CONSTRAINT`). `002_integrity.ts` does that for every
player-scoped table, first creating parent `players` rows for legacy data so the
upgrade is lossless. Header-based demo users are materialized by insert triggers;
new accounts use portable UUID player IDs.

**Postgres.** Files in `backend/migrations/`, applied in filename order by
`backend/src/db/migrate-pg.ts`, each exactly once, recorded in
`ops.schema_migrations`. Run it with `node dist/db/migrate-pg.js`.

Both are append-only. An applied migration is history; correct it with a new one.

## Verification

`npm test` exercises fresh SQLite creation, upgrade from the legacy schema,
idempotency, rollback, JSON checks, foreign keys, cascading deletes, and every
backend store/route.

For Postgres, `.github/workflows/tigerdata-db.yml` applies the complete migration
chain to a throwaway TimescaleDB, proves a re-run is a no-op, then runs two
gates: `scripts/check-pg-schema.js` for shape (ledger parity in both directions,
contiguous versions, RLS and policy coverage, the grants each mirror needs, the
rarity and rank ladders against their TypeScript sources, the time-series
surface) and `scripts/run-db-invariants.js` for behaviour — `tests/db/invariants.sql`
asserts the append-only ledger, lock integrity, derived rarity and rank tiers,
onboarding sanity, casino payout rules, and that RLS actually isolates when read
as the app's own role. Each refusal names the constraint or trigger it expects,
so an assertion cannot pass on an unrelated error. CI runs both paths.

## Operational notes

- **Foreign keys are ON.** SQLite disables them per-connection by default, so
  the one FK the schema already declared was decorative until now.
- **WAL + `busy_timeout=5000`**, so a reader and a writer coexist and a second
  writer waits instead of failing the request.
- **The handle is closed on shutdown** (`SIGINT`/`SIGTERM`/`beforeExit`). Without
  it the file stays locked, which is why the persistence test could not delete
  its own fixture on Windows.
- **Railway's filesystem is ephemeral.** Set `NUTRIQUEST_DB=/data/nutriquest.db`
  and attach a volume, or every deploy starts empty. The app warns on boot.
- `NUTRIQUEST_DB=memory` gives an in-memory database for tests.
