-- 0015_casino.sql — casino / gambling on TigerData
--
-- Runtime games (SQLite: 003_cauldron, 005_mines, 006_plinko, 007_coins_and_locks):
--   * Cauldron Crash -> app.cauldron_rounds already exists (migration 0012).
--   * Kitchen Mines  -> app.mines_rounds (this file). layout is withheld from the
--                       restricted app role (a column grant that excludes it), so
--                       the mine positions can never leak, active or not.
--   * Plinko         -> app.plinko_drops (this file). One immutable row per drop.
-- Coins use the existing ledger model (app.currency_entries, currency='coins',
--   added in 0012) — no separate coin table needed.
-- Analytics: telemetry.gamble_events (HYPERTABLE) is the append-only outcome
--   stream across all three games — the "best use of TigerData" gambling trend
--   surface, rolled up by analytics.gamble_hourly.
--
-- Invariant reminder (enforced in app code, mirrored here as records): a wagered
-- monster leaves the inventory when a round starts and never returns; the round
-- row is the only surviving copy of what was risked.

-- Safety: these economy columns arrived via the phase-2 milestone (already applied
-- to the live service); re-assert idempotently so a fresh database is consistent.
alter table app.owned_characters add column if not exists net_worth integer not null default 0;
alter table app.owned_characters add column if not exists locked boolean not null default false;

-- ---------------------------------------------------------------------------
-- Kitchen Mines — authoritative round state (mutable while ACTIVE).
-- ---------------------------------------------------------------------------
create table if not exists app.mines_rounds (
  round_id            uuid primary key default gen_random_uuid(),
  player_id           text not null references app.players(id) on delete cascade,
  wager               jsonb not null,                 -- full copy of the wagered monster
  wager_value         bigint not null check (wager_value >= 0),
  mines               integer not null check (mines between 1 and 24),
  layout              integer[] not null,             -- mine tile indices 0..24 — SECRET
  revealed            integer[] not null default '{}',-- safe tiles turned over, in order
  status              text not null check (status in ('ACTIVE','SERVED','BURNT')),
  started_at          timestamptz not null default now(),
  cash_out_multiplier numeric,
  final_net_worth     bigint,
  reward              jsonb,                           -- null when burnt
  completed_at        timestamptz,
  fairness            jsonb not null
);
create index if not exists mines_rounds_player_idx on app.mines_rounds(player_id, started_at desc);

alter table app.mines_rounds enable row level security;
drop policy if exists player_isolation on app.mines_rounds;
create policy player_isolation on app.mines_rounds for all
  using (player_id = current_setting('app.current_player', true))
  with check (player_id = current_setting('app.current_player', true));
-- The default-privilege grant (migration 0011) hands every new app table a
-- table-wide SELECT (all columns). Revoke it so the COLUMN grant below is the
-- only read path — the mine `layout` is never selectable by the app role.
revoke all on app.mines_rounds from nutriquest_app;
grant select (round_id, player_id, wager, wager_value, mines, revealed, status,
              started_at, cash_out_multiplier, final_net_worth, reward, completed_at, fairness)
  on app.mines_rounds to nutriquest_app;

-- ---------------------------------------------------------------------------
-- Plinko — one immutable row per drop (no active state). path is safe to expose.
-- ---------------------------------------------------------------------------
create table if not exists app.plinko_drops (
  drop_id         uuid primary key default gen_random_uuid(),
  player_id       text not null references app.players(id) on delete cascade,
  wager           jsonb not null,
  wager_value     bigint not null check (wager_value >= 0),
  path            boolean[] not null,                 -- 12 left/right decisions
  slot            integer not null check (slot between 0 and 12),
  multiplier      numeric not null check (multiplier >= 0),
  final_net_worth bigint not null default 0,          -- 0 on a bust
  reward          jsonb,                              -- null on a bust
  created_at      timestamptz not null default now(),
  fairness        jsonb not null
);
create index if not exists plinko_drops_player_idx on app.plinko_drops(player_id, created_at desc);

alter table app.plinko_drops enable row level security;
drop policy if exists player_isolation on app.plinko_drops;
create policy player_isolation on app.plinko_drops for all
  using (player_id = current_setting('app.current_player', true))
  with check (player_id = current_setting('app.current_player', true));
grant select, insert on app.plinko_drops to nutriquest_app;

-- ---------------------------------------------------------------------------
-- telemetry.gamble_events — append-only outcome stream across all games.
-- ---------------------------------------------------------------------------
create table if not exists telemetry.gamble_events (
  event_id         uuid not null default gen_random_uuid(),
  occurred_at      timestamptz not null default now(),
  player_id        text not null references app.players(id) on delete cascade,
  mode             text not null check (mode in ('crash','mines','plinko')),
  outcome          text not null,          -- served | burnt | cashed_out | crashed | dropped | busted
  wager_value      bigint not null default 0,
  multiplier       numeric,
  net_worth_change bigint not null default 0,  -- reward value - wager value (negative on a loss)
  ref_id           uuid,                       -- round_id / drop_id
  primary key (event_id, occurred_at)
);
select create_hypertable('telemetry.gamble_events', 'occurred_at',
       chunk_time_interval => interval '1 day', if_not_exists => true);
create index if not exists gamble_events_player_idx on telemetry.gamble_events(player_id, occurred_at desc);
create index if not exists gamble_events_mode_idx on telemetry.gamble_events(mode, occurred_at desc);

-- ---------------------------------------------------------------------------
-- analytics.gamble_hourly — trend rollup (real-time). Created BEFORE RLS: a
-- continuous aggregate cannot be created on a hypertable that already has RLS.
-- ---------------------------------------------------------------------------
create materialized view analytics.gamble_hourly
  with (timescaledb.continuous, timescaledb.materialized_only = false) as
select
  time_bucket(interval '1 hour', occurred_at) as bucket,
  player_id,
  mode,
  count(*)                                        as plays,
  sum(wager_value)                                as wagered,
  sum(net_worth_change)                           as net_change,
  count(*) filter (where net_worth_change > 0)    as wins
from telemetry.gamble_events
group by 1, 2, 3
with no data;

select add_continuous_aggregate_policy('analytics.gamble_hourly',
  start_offset => interval '7 days',
  end_offset   => interval '1 hour',
  schedule_interval => interval '15 minutes');

-- RLS enabled after the aggregate exists (matches the 0008 -> 0011 ordering).
alter table telemetry.gamble_events enable row level security;
drop policy if exists player_isolation on telemetry.gamble_events;
create policy player_isolation on telemetry.gamble_events for all
  using (player_id = current_setting('app.current_player', true))
  with check (player_id = current_setting('app.current_player', true));
grant select, insert on telemetry.gamble_events to nutriquest_app;

insert into ops.schema_migrations(version, name)
values ('0015','0015_casino.sql') on conflict do nothing;
