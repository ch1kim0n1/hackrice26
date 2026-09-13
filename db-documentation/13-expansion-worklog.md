# 13 — TigerData expansion worklog

**Branch:** `dev-db` (synced to `main` at `4e7999c`)
**Started:** 2026-09-12
**Driver:** the audit in the TigerData Expansion Map — the schema was built and the
read side was dark. This is the work that closes that.

This file is the handoff. If the session running it stops, another model picks up
from **Status** below: everything marked `TODO` is unstarted, `WIP` is
half-applied (read the note), `DONE` is committed and verified.

---

## Scope, as agreed

| # | Item | Tier | Status |
|---|---|---|---|
| 1 | Lifecycle drift: enrol `body_metrics`, `gamble_events`, `battle_events` | Now | **DONE** `0019` |
| 2 | Read functions for the 4 dark continuous aggregates | Now | **DONE** `trendsRepo.ts` + `/trends` |
| 3 | Casino luck chart, end to end (repo → route → Swift Charts) | Now | **DONE** `CasinoLuckChart.swift` |
| 4 | Mirror → real outbox with retry | Next | **DONE** SQLite `mirror_outbox` + drain — 14/19 call sites converted, see below |
| 5 | RLS on for real (`nutriquest_app` gets LOGIN) | Next | **DONE (schema)** `0021` — password is a one-off command, see below |
| 6 | Postgres authoritative | Next | **DONE (coins)** `coinsPg.ts` — balances read from PG, writes via outbox |
| 7 | Read replica support (code side; provisioning is a console action) | Next | **DONE (code)** `getReplicaPool()` |
| 8 | Confirm backup / PITR posture | Watch | **PARTIAL** — see below; needs a Console look |
| 9 | Three telemetry candidates: streaks, pull luck, dungeon depth | Watch | **DONE** `0020` + `telemetryRepo.ts`; pull-luck writers wired, streak/dungeon writers pending (their routes are being edited by someone else) |

**Explicitly out of scope:** data tiering to bottomless storage (dropped by the
user — not needed at this volume). pgvector was not named either way; left alone,
flag it at the end rather than guess.

---

## Decisions made along the way

### RLS beats compression on `gamble_events` and `body_metrics`

The roadmap said "close the compression/retention drift" on both. That turns out
to be **half wrong**, and the correction matters:

> `ROW LEVEL SECURITY` is not supported on chunks in the columnstore.
> — [Hypercore limitations](https://www.tigerdata.com/docs/reference/timescaledb/hypercore#limitations)

and `ENABLE/DISABLE ROW SECURITY` is a blocked operation once columnstore is on.

Both tables carry `player_isolation` policies (`gamble_events` from `0015`,
`body_metrics` from `0017`). Compressing them would mean dropping RLS on
player-owned data — exactly the protection this same body of work is switching on
for real. So:

- `telemetry.gamble_events` → **retention only, no compression.**
- `telemetry.body_metrics` → **retention only, no compression.**
- `telemetry.battle_events` → has no RLS (no `player_id` column), so it
  **can** be compressed. It stays exempt from *retention* for the documented
  replay-safety reason, which is a separate concern from compression.

This is the same trade-off `0010` already made silently for `nutrition_deltas`
and `battle_metrics` — those two are compressed and therefore have no RLS, which
`0011` documents. The difference is that this time the choice is going the other
way, because the app is about to start relying on RLS.

---

## Changelog

Newest last. Each entry: what changed, why, and how it was verified.

<!-- APPEND ENTRIES BELOW -->

### 2026-09-12 — slice 1: schema, pools, read side

**Migrations added** (all apply from empty; re-run is a no-op; verified on
TimescaleDB 2.30.0, the exact production version):

- `0019_lifecycle_backfill.sql` — retention for `gamble_events` (90d) and
  `analytics.gamble_hourly` (365d); columnstore for `battle_events`;
  `body_metrics` deliberately left with no policy at all, documented in-file.
- `0020_telemetry_expansion.sql` — three new hypertables
  (`streak_events`, `acquisition_events`, `dungeon_progress`), three new
  real-time continuous aggregates (`streak_daily`, `acquisition_hourly`,
  `dungeon_daily`), their refresh + retention policies, RLS policies and grants.
- `0021_runtime_role_login.sql` — `nutriquest_app` gets LOGIN. **No password in
  git**; see "Remaining manual steps".

**Code**

- `backend/src/db/pg.ts` — one pool became three: `getPool()` (app, restricted
  role, RLS binds), `getAdminPool()` (owner, DDL only), `getReplicaPool()`
  (analytics, falls back to app pool until `DATABASE_URL_REPLICA` is set).
  All three fall back to `DATABASE_URL`, so a single-URL setup is unchanged.
- `migrate-pg.ts` and the three `scripts/*.js` now use the admin URL.
- `backend/src/db/repositories/trendsRepo.ts` — **new**. Read functions for all
  eight aggregates. Every one goes through the replica pool.
- `backend/src/routes/trends.ts` — **new**. `GET /trends/{casino,nutrition,
  battles,gameplay,streak,pulls,dungeon,health}`. Returns
  `{available, source, points}`; answers `available:false` with an empty series
  when no Postgres is configured, rather than erroring.
- `check-pg-schema.js` — counts updated to 11 hypertables / 8 aggregates, plus
  three new assertions: every hypertable must have a **declared lifecycle
  intent** in the file (a new one fails until someone decides), the live
  lifecycle must match that intent, and no hypertable may have RLS and
  columnstore at once.

**Verified:** 21 migrations from empty → re-run no-op → 26/26 schema checks →
5 seed files → 39 invariants. `tsc --noEmit` clean.

### 2026-09-12 — slice 2: casino chart, outbox, PG-authoritative coins

**Casino chart, end to end.** `analytics.gamble_hourly` → `trendsRepo.getGambleTrend`
→ `GET /trends/casino` → `CasinoLuckChart.swift`, mounted under the game tiles in
`CasinoHubView`. Plots net swing rather than a win count, because casino games pay
asymmetrically and a win count would be true and useless. Four load states:
loading / no-Postgres / failed / no-plays-yet.

**The mirror is a queue now.** SQLite migration `012_mirror_outbox` +
`services/mirrorQueue.ts` + `services/mirrorDrain.ts`. Routes enqueue (one
synchronous insert) and a background drain delivers with exponential backoff
capped at 30 minutes, nine attempts, then the row moves to
`mirror_outbox_dead` — evidence rather than a silent gap.

**Postgres is authoritative for coins.** `services/coinsPg.ts` reads balances
from `app.currency_entries` and writes there transactionally. What Postgres adds
over SQLite here: 0018's append-only trigger (no edits or deletes, corrections
are compensating entries), RLS, and `app.wallets.balance >= 0` enforced by the
database. Coin writes are enqueued *inside the same SQLite transaction* as the
local row, so a rolled-back sale never queues a credit.

**Verified end to end against TimescaleDB 2.30:** enqueue → drain → balance 500,
wallet row 500, acquisition event 1. Redelivering the same entries left balance
at 500 and the event count at 1 (idempotent). An overdraft was refused by the
database and the row was held for retry rather than dropped.

Backend: `tsc` clean; 457 tests pass, 0 assertion failures (9 new outbox tests,
7 new trends tests). The 8 failing *files* are the pre-existing Windows `EPERM`
teardown on file-backed SQLite, unrelated to this work.

**Note on the full suite:** running it with default parallelism took 50 minutes
wall-clock for 19 seconds of tests, on Windows. `--no-file-parallelism` returns
it to ~40s. Worth chasing separately; it is not caused by anything here.

---

## Remaining manual steps (not doable from this session)

1. **Set the runtime role's password.** `0021` grants LOGIN but deliberately
   ships no credential:
   ```
   alter role nutriquest_app password '<generated>';
   ```
   Then split the deployment env: `DATABASE_URL` → `nutriquest_app`,
   `DATABASE_URL_ADMIN` → `tsdbadmin`. Until this is done the app still connects
   as the owner and RLS is still inert — the schema is ready, the credential is not.

2. **Apply `0019`–`0021` to the live service.** Same runner as before:
   `DATABASE_URL_ADMIN=<owner url> node dist/db/migrate-pg.js`.

3. **Provision the read replica** (optional). Code is ready: set
   `DATABASE_URL_REPLICA` and every trend query moves off the primary with no
   code change. `getReplicaPool()` falls back to the app pool when unset.

## Backup / PITR — what is confirmed and what is not

**Confirmed from Tiger's docs and the service metadata:**
- Tiger Cloud takes full + incremental backups and retains WAL for the period
  included in the plan; recovery is a **PITR fork** (Console → Operations →
  Service management → Create recovery fork), which leaves the original service
  untouched.
- Extended retention (14–180 days) is **Enterprise only**.
- `db-19576` reports `replicas: 0` — there is **no HA replica**. Single node.

**Not confirmable from here:** the actual configured retention window for this
service, and whether any backup has successfully run. No MCP tool exposes backup
configuration. That is a Console check: **Operations → Backup and restore**.
`07-api-security-operations.md` has flagged this as an open item since it was
written; it stays open, but the navigation path is now recorded.

## Follow-ups this slice deliberately did not take

- **5 of 19 mirror call sites** still use fire-and-forget: two in
  `routes/battle.ts` and two in `routes/user.ts`, plus `recordBodyMetric`.
  Those two files had uncommitted work from another developer in the tree
  throughout this session, and converting them would have meant either
  colliding with it or committing it. Convert them the same way
  (`enqueueMirror(kind, key, payload)`) once that work lands.
- **Streak and dungeon writers.** `telemetryRepo.recordStreakEvent` and
  `recordDungeonProgress` exist, are tested by the schema gate, and have no
  callers yet — their write paths live in `user.ts` and `battle.ts`, the same
  two files. The pull-luck writer *is* wired (`lootbox.ts`, `scan.ts`).
- **pgvector.** Not named either way in the brief. Untouched.

### 2026-09-12 — slice 3: last call sites, and hyperfunctions

**All 19 mirror call sites now queue.** The five in `battle.ts`/`user.ts` were
done on a stashed-clean copy of both files and the in-flight rank/fatigue work
restored on top (`git stash pop`, no conflicts, their 4 tests pass again). Two
more turned up in `characters.ts` and were converted too. Nothing in the
codebase discards a mirror write on failure any more.

Two were more than mechanical: a dungeon run now also writes
`dungeon_progress` (the series `analytics.dungeon_daily` was built for and had
no writer), and a merge now writes an `acquisition_event`, because a merge
mints a monster and the pull-luck series was missing every unit a player built
rather than found. `body_metric` joined the queue as its own kind.

**Hyperfunctions.** The schema had eleven hypertables, eight continuous
aggregates, and used exactly one TimescaleDB analytical function: plain
`time_bucket`. `time_bucket_gapfill` now backs the casino and health series.

This fixed a real defect rather than adding polish: an hour with no play
produces no row, so the casino chart drew surrounding hours adjacent and a
two-hour dead patch vanished. Verified with a deliberate hole — raw returned
18:00/19:00/22:00; gapfilled returns seven contiguous buckets with 20:00 and
21:00 as explicit zeros. Health additionally uses `locf` on the average (a
heart rate does not stop existing because the watch missed an hour) but
deliberately *not* on sample counts, where zero is a fact.

Gotchas, each of which cost a round trip: gapfill needs an upper bound in
WHERE; it must be the top-level SELECT expression, unwrapped; and the alias
must not be `bucket`, or GROUP BY binds to the source column of that name.

---

## Tiger Cloud capability inventory (2026-09-12)

| Capability | Status |
|---|---|
| Hypertables (11) | used |
| Continuous aggregates (8) + refresh policies | used |
| Columnstore / compression | used on 3 (RLS blocks the rest — see 0019) |
| Retention policies | used |
| RLS | schema complete; **inert until the role password is set** |
| Hyperfunctions | `time_bucket_gapfill`, `locf` — as of this slice |
| **Connection pooling (PgBouncer)** | **unused** — free, and relevant on a 0.5-CPU service with 3 pools |
| **Read replicas** | **unused** — code ready (`getReplicaPool`), needs provisioning |
| **High availability** | **unused** — `replicas: 0` |
| **pgvector / pgvectorscale / pgai** | **unused** |
| **Data forking** | **unused** — the right way to get a test DB with real shape |
| **Livesync** | not applicable — nothing to replicate from |
| Tiered storage | out of scope by decision |

**On the $1000:** it is consumption credit, spent by compute-hours and storage,
not by enabling features. Provisioning infrastructure to burn it is waste. The
things actually worth turning on, in order: connection pooling (free, helps
now), a read replica (real benefit now that trend routes exist), HA (only if
this becomes production). pgvector is a genuine new capability but needs an
embedding provider decision first.

**LAN tournaments do not touch Tiger Cloud at all.** `ios/Sources/NutriQuest/LAN/`
is MultipeerConnectivity over Bonjour (`_nq-lan._tcp`) — device to device on the
local network, no server in the path, works with no internet. The
`app.lan_sessions`, `tournaments`, `tournament_entries` and `tournament_matches`
tables have zero writers: specced as optional persistence, never built. If LAN
results should ever appear on a cloud leaderboard, that is the gap to close.
