# 12 — Wiring runbook (how to connect features to TigerData)

Purpose: exact, repeatable instructions to wire every feature to the Tiger Cloud database, so anyone (or any model) can continue from where this left off. Read [08](08-implementation-and-validation.md) and [CHANGELOG](CHANGELOG.md) first for state.

## Strategy: additive best-effort mirror (NOT a rewrite)

The app runs on SQLite and has a large SQLite test suite. We do **not** rip that out. Instead each feature **also** writes normalized data into TigerData when `DATABASE_URL` is set:

- SQLite stays the source of truth for the running app.
- A `pg` "repository" writes the normalized rows into TigerData tables/hypertables.
- The route calls the repository **best-effort**: guarded by `hasDatabaseUrl()`, fire-and-forget, and a failure only logs — it never breaks the request.
- With no `DATABASE_URL` (normal local/CI), the mirror is a no-op, so the SQLite tests are unaffected.

This gives the "best use of TigerData" (all hypertables fed by real features) without destabilizing the app. A full cutover to `pg`-only can happen later per [08](08-implementation-and-validation.md).

## The recipe (copy this for each feature)

1. **Repository** in `backend/src/db/repositories/<feature>Repo.ts`:
   - Import `getPool`, `withPlayer` (or `withTransaction` for multi-player/system writes) from `../pg`, and `ensurePlayer` from `./players`.
   - First line inside the transaction: `await ensurePlayer(client, playerId)` — runtime player ids don't exist in `app.players` until first write.
   - Write with parameterized SQL. Use `on conflict ... do nothing` for idempotency on natural keys.
   - Player-owned writes → `withPlayer(playerId, ...)` (sets `app.current_player` for RLS). System/multi-player writes (e.g. battles) → `withTransaction(...)`.
2. **Route wiring**: after the existing SQLite write succeeds, add
   ```ts
   if (hasDatabaseUrl()) {
     void <feature>Mirror(...).catch((e) => console.warn(`[<feature>->tigerdata] ${(e as Error).message}`));
   }
   ```
3. **Integration test** `*.integration.test.ts`: gate with `const suite = process.env.DATABASE_URL ? describe : describe.skip;`. Create a throwaway `p_ittest_*` player, exercise the repo, assert rows, then delete the player (cascade) in `afterAll`.
4. **Verify** (writable connection string, password stays out of shell history):
   ```bash
   cd backend
   DATABASE_URL="$(TIGER_READ_ONLY=prod tiger db connection-string j7s0lyqh6t --with-password)" \
     npx vitest run src/db/repositories/<feature>.integration.test.ts
   npx vitest run   # full suite must stay green (mirror skipped without DATABASE_URL)
   npx tsc -p tsconfig.json --noEmit
   ```

## Reference implementations (already wired — copy these)

- `db/repositories/healthRepo.ts` + `vitals/vitalsRoutes.ts` — hypertable writes (health_samples, activity_observations) + workouts + continuous-aggregate reads.
- `db/repositories/battleRepo.ts` + `routes/battle.ts` (`/async/challenge`) — the PvP marquee: battles + battle_events + battle_metrics.
- `db/repositories/gameEventsRepo.ts` + scan/lootbox/user routes — gameplay_events stream.
- `db/repositories/players.ts` — `ensurePlayer` upsert.

## Feature wiring status

| # | Feature | Target tables / hypertables | Status |
|---|---|---|---|
| 1 | Vitals / health | `health_samples`⛰, `activity_observations`⛰, `workouts` | ✅ wired (`vitalsRoutes`) |
| 2 | PvP friend battle | `battles`, `battle_participants`, `battle_events`⛰, `battle_metrics`⛰ | ✅ wired (`battle.ts /async/challenge`) |
| 3 | Barcode scan / collect | `gameplay_events`⛰ | ✅ wired (`scan.ts`) |
| 4 | Lootbox open | `gameplay_events`⛰ | ✅ wired (`lootbox.ts`) |
| 5 | Quest claim | `gameplay_events`⛰ | ✅ wired (`user.ts`) |
| 6 | Food photo / nutrition confirm | `nutrition_deltas`⛰ (intake leg) | ✅ wired (`scan.ts` `/photo/confirm` → `nutritionRepo`) |
| 7 | Body weigh-ins | `body_metrics`⛰ | ✅ wired (`user.ts` `PUT /user/:id` weight → `recordBodyMetric`) |
| 8 | Casino: mines / plinko / crash | `mines_rounds`, `plinko_drops`, `cauldron_rounds`, `gamble_events`⛰ | ✅ wired (`gambleRepo`) |
| 9 | Dungeon | `gameplay_events`⛰ (+ SQLite `dungeon_state`) | ✅ event wired (`battle.ts /dungeon/run`) |
| 10 | Sell / merge (economy) | `gameplay_events`⛰ | ✅ event wired (`characters.ts`) |
| 11 | Achievements / streaks | `achievement_unlocks`, `streak_state` | ⏳ ordinary-table mirror (event via achievements when unlocked) |
| 12 | Gym-photo verification | `gym_checks`, `training_buffs` | ⏳ ordinary-table mirror |
| 13 | Accounts / sessions / devices | `players`, `credentials`, `sessions` | ⏳ identity mirror (players auto-created via `ensurePlayer`) |
| 14 | Rankings / seasons / arena | `rankings`, `seasons`, `arena_escrows` | ⏳ ordinary-table mirror |

⛰ = TimescaleDB hypertable.

**Hypertable coverage: 8 of 8 fed by live features** — `health_samples`, `activity_observations`, `nutrition_deltas`, `battle_events`, `battle_metrics`, `gameplay_events`, `body_metrics`, `gamble_events`. Every hypertable has a live write path; the remaining ⏳ items (#11–14) are ordinary-table mirrors (analytics-optional), not hypertable gaps.

**DB readiness (verified on `db-19576`):** 8 hypertables, 5 continuous aggregates (`health_hourly`, `nutrition_hourly`, `battle_hourly`, `gameplay_hourly`, `gamble_hourly`), 82 ordinary tables, 53 RLS-enabled tables, TimescaleDB 2.30, migration 0015. The bounded `pg.Pool` + `withPlayer` RLS context + `/ready` probe make the service ready to serve every feature's requests when `DATABASE_URL` is configured.

## Suggested next order
6 (nutrition_deltas — completes hypertable coverage), then 7 (weigh-in route), 9 (casino), 8 (economy), 10, 11, 12, 13, 14.

## Guardrails
- Never let a mirror failure break the request (best-effort only).
- Always `ensurePlayer` before any player-scoped write.
- Idempotency: use `on conflict do nothing` on natural keys.
- Nutrition (#6) must write signed legs (intake / reversal / replacement) — never re-sum; see [04](04-timescale-design.md) §Nutrition.
- Battles are server-authoritative → `withTransaction`, not `withPlayer`.
- Don't add blind retention to `battle_events` (guarded cleanup only).
