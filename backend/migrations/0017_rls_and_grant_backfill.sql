-- 0017_rls_and_grant_backfill.sql — close two gaps left by 0012 and 0015.
--
-- Both are corrected here rather than in place: 0012 and 0015 are applied on the
-- live service and the ledger (ops.schema_migrations) is append-only, so an edit
-- to either file would never re-run.
--
-- 1. RLS on the two tables 0012 added.
--    0011 swept every table that had a `player_id` column *at the time it ran*.
--    app.cauldron_rounds and telemetry.body_metrics arrived one migration later
--    and so were never enrolled, leaving them the only uncompressed player-owned
--    tables in app/telemetry without row-level security. 0015 and 0016 each
--    enabled RLS on their own new tables; these two were missed.
--
--    telemetry.battle_metrics and telemetry.nutrition_deltas stay exempt on
--    purpose — they are columnstore hypertables, where RLS is not supported, and
--    0011 documents that skip.
--
-- 2. Write privileges on app.mines_rounds.
--    0015 revoked the inherited table-wide grant so the secret mine `layout`
--    could never be selected by the restricted role, then re-granted only
--    column-level SELECT. It never restored INSERT or UPDATE, so
--    mirrorMinesRound() (backend/src/db/repositories/gambleRepo.ts) cannot write
--    at all once the app connects as nutriquest_app: its insert .. on conflict
--    do update needs INSERT plus UPDATE on the six mutable columns. The mirror
--    is best-effort and its rejection is only console.warn'd, so every Kitchen
--    Mines round would be dropped from TigerData in silence — including from
--    telemetry.gamble_events' trend surface.
--
--    INSERT must cover `layout` (it is NOT NULL and the server authors it), and
--    that leaks nothing: INSERT conveys no read access. UPDATE is granted per
--    column and deliberately excludes `layout`, so a board cannot be rewritten
--    after the round has started. SELECT is left exactly as 0015 set it.

-- ---------------------------------------------------------------------------
-- 1. Player isolation on 0012's tables.
-- ---------------------------------------------------------------------------
alter table app.cauldron_rounds enable row level security;
drop policy if exists player_isolation on app.cauldron_rounds;
create policy player_isolation on app.cauldron_rounds for all
  using (player_id = current_setting('app.current_player', true))
  with check (player_id = current_setting('app.current_player', true));

alter table telemetry.body_metrics enable row level security;
drop policy if exists player_isolation on telemetry.body_metrics;
create policy player_isolation on telemetry.body_metrics for all
  using (player_id = current_setting('app.current_player', true))
  with check (player_id = current_setting('app.current_player', true));

-- ---------------------------------------------------------------------------
-- 2. Let the restricted role write a mines round without being able to read
--    the board.
-- ---------------------------------------------------------------------------
grant insert on app.mines_rounds to nutriquest_app;
grant update (revealed, status, cash_out_multiplier, final_net_worth, reward, completed_at)
  on app.mines_rounds to nutriquest_app;

-- No ledger row is written here: the runner (backend/src/db/migrate-pg.ts)
-- records every file it applies, in the same transaction.
