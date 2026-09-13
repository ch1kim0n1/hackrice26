-- 0020_telemetry_expansion.sql -- three streams the product generates and never recorded.
--
-- Each one is a question the game already asks the player to care about and
-- that the schema currently cannot answer over time:
--
--   streaks       "how consistent have I actually been" -- the product's whole
--                 pitch, and there is no time series behind it. app.streak_state
--                 holds a single current number; the shape of the last 90 days
--                 is nowhere.
--   pull luck     "am I getting good pulls" -- app.character_acquisitions is an
--                 ordinary table keyed by uuid, fine for ownership history,
--                 useless for a rarity-mix-over-time query.
--   dungeon depth "am I getting deeper" -- app.dungeon_runs holds best_floor for
--                 the current run only.
--
-- These are new *telemetry* tables rather than conversions of the app tables.
-- That is the pattern the schema already uses (app.battles alongside
-- telemetry.battle_events) and it avoids the real blocker: a hypertable needs
-- the partition column in every unique index, and app.character_acquisitions is
-- keyed on a bare uuid. Converting it would mean rewriting its primary key
-- under live data for no gain -- the transactional row and the event stream
-- want different shapes.
--
-- None of the three is compressed, for the reason 0019 sets out: they all carry
-- player_id, they all get RLS, and RLS is not supported on columnstore chunks.
-- All three are small per player. Retention is set where the raw row stops
-- being worth keeping and the rollup carries the history instead.

-- ---------------------------------------------------------------------------
-- 1. telemetry.streak_events -- one row per game day resolved.
-- ---------------------------------------------------------------------------
create table if not exists telemetry.streak_events (
  event_id      uuid not null default gen_random_uuid(),
  occurred_at   timestamptz not null default now(),
  player_id     text not null references app.players(id) on delete cascade,
  game_day      date not null,
  streak_length integer not null check (streak_length >= 0),
  best_streak   integer not null check (best_streak >= 0),
  qualified     boolean not null,          -- did the day meet the bar
  freeze_used   boolean not null default false,
  primary key (event_id, occurred_at)
);
select create_hypertable('telemetry.streak_events', 'occurred_at',
       chunk_time_interval => interval '30 days', if_not_exists => true);
create index if not exists streak_events_player_idx
  on telemetry.streak_events (player_id, occurred_at desc);
-- One resolution per player per game day; a re-resolve overwrites nothing, it
-- is simply refused, so a retry cannot inflate a streak history.
create unique index if not exists streak_events_player_day_uq
  on telemetry.streak_events (player_id, game_day, occurred_at);

-- ---------------------------------------------------------------------------
-- 2. telemetry.acquisition_events -- one row per monster obtained.
-- ---------------------------------------------------------------------------
create table if not exists telemetry.acquisition_events (
  event_id     uuid not null default gen_random_uuid(),
  occurred_at  timestamptz not null default now(),
  player_id    text not null references app.players(id) on delete cascade,
  source_kind  text not null check (source_kind in
                 ('scan','dish','lootbox','fusion','promo','reward','merge')),
  rarity       text not null references app.rarity_bands(rarity),
  net_worth    bigint not null default 0 check (net_worth >= 0),
  star_level   integer not null default 1 check (star_level between 1 and 5),
  character_ref text,                      -- drop id / owned_character id, not an FK:
                                           -- the row it points at can be sold away.
  primary key (event_id, occurred_at)
);
select create_hypertable('telemetry.acquisition_events', 'occurred_at',
       chunk_time_interval => interval '30 days', if_not_exists => true);
create index if not exists acquisition_events_player_idx
  on telemetry.acquisition_events (player_id, occurred_at desc);
create index if not exists acquisition_events_rarity_idx
  on telemetry.acquisition_events (rarity, occurred_at desc);

-- ---------------------------------------------------------------------------
-- 3. telemetry.dungeon_progress -- one row per floor resolved.
-- ---------------------------------------------------------------------------
create table if not exists telemetry.dungeon_progress (
  event_id    uuid not null default gen_random_uuid(),
  occurred_at timestamptz not null default now(),
  player_id   text not null references app.players(id) on delete cascade,
  run_ref     text,                        -- dungeon run id, not an FK: runs are prunable
  floor       integer not null check (floor >= 0),
  outcome     text not null check (outcome in ('cleared','failed','retreated')),
  squad_power integer,                     -- what the squad was worth going in
  primary key (event_id, occurred_at)
);
select create_hypertable('telemetry.dungeon_progress', 'occurred_at',
       chunk_time_interval => interval '30 days', if_not_exists => true);
create index if not exists dungeon_progress_player_idx
  on telemetry.dungeon_progress (player_id, occurred_at desc);

-- ---------------------------------------------------------------------------
-- Rollups. Real-time (materialized_only = false) like every other aggregate
-- here, so a route reading them never has to explain refresh lag.
-- ---------------------------------------------------------------------------
create materialized view analytics.streak_daily
  with (timescaledb.continuous, timescaledb.materialized_only = false) as
select
  time_bucket(interval '1 day', occurred_at) as bucket,
  player_id,
  max(streak_length)                             as streak_end,
  max(best_streak)                               as best_streak,
  count(*) filter (where qualified)              as qualified_days,
  count(*) filter (where freeze_used)            as freezes_used,
  count(*)                                       as days_resolved
from telemetry.streak_events
group by 1, 2
with no data;

create materialized view analytics.acquisition_hourly
  with (timescaledb.continuous, timescaledb.materialized_only = false) as
select
  time_bucket(interval '1 hour', occurred_at) as bucket,
  player_id,
  rarity,
  count(*)              as pulls,
  sum(net_worth)        as worth_gained,
  max(star_level)       as best_star
from telemetry.acquisition_events
group by 1, 2, 3
with no data;

create materialized view analytics.dungeon_daily
  with (timescaledb.continuous, timescaledb.materialized_only = false) as
select
  time_bucket(interval '1 day', occurred_at) as bucket,
  player_id,
  max(floor)                                  as deepest_floor,
  count(*)                                    as floors_attempted,
  count(*) filter (where outcome = 'cleared') as floors_cleared
from telemetry.dungeon_progress
group by 1, 2
with no data;

-- ---------------------------------------------------------------------------
-- Refresh policies. Without one a continuous aggregate only ever shows what
-- the real-time layer computes on the fly, and never materialises -- which is
-- the slow path the aggregate exists to avoid.
-- ---------------------------------------------------------------------------
select add_continuous_aggregate_policy('analytics.streak_daily',
  start_offset => interval '30 days', end_offset => interval '1 hour',
  schedule_interval => interval '1 hour', if_not_exists => true);
select add_continuous_aggregate_policy('analytics.acquisition_hourly',
  start_offset => interval '7 days', end_offset => interval '10 minutes',
  schedule_interval => interval '30 minutes', if_not_exists => true);
select add_continuous_aggregate_policy('analytics.dungeon_daily',
  start_offset => interval '30 days', end_offset => interval '1 hour',
  schedule_interval => interval '1 hour', if_not_exists => true);

-- ---------------------------------------------------------------------------
-- Retention. Raw rows age out; the rollups carry the history the UI shows.
-- streak_events is exempt: one row per player per day is nothing, and a streak
-- history with a hole in it is worse than useless.
-- ---------------------------------------------------------------------------
select add_retention_policy('telemetry.acquisition_events', interval '365 days', if_not_exists => true);
select add_retention_policy('telemetry.dungeon_progress',   interval '90 days',  if_not_exists => true);

-- ---------------------------------------------------------------------------
-- RLS. These are player-owned, and 0011's sweep is long past -- each new table
-- enrols itself, which is the rule CLAUDE.md states and 0012 and 0015 both
-- broke.
-- ---------------------------------------------------------------------------
do $rls$
declare t text;
begin
  foreach t in array array['streak_events','acquisition_events','dungeon_progress'] loop
    execute format('alter table telemetry.%I enable row level security', t);
    execute format('drop policy if exists player_isolation on telemetry.%I', t);
    execute format(
      $p$create policy player_isolation on telemetry.%I for all
         using (player_id = current_setting('app.current_player', true))
         with check (player_id = current_setting('app.current_player', true))$p$, t);
    execute format('grant select, insert on telemetry.%I to nutriquest_app', t);
  end loop;
end
$rls$;

grant select on analytics.streak_daily, analytics.acquisition_hourly,
                analytics.dungeon_daily to nutriquest_app;

-- No ledger row is written here: the runner (backend/src/db/migrate-pg.ts)
-- records every file it applies, in the same transaction.
