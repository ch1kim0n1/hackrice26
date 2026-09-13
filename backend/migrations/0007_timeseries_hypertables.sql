-- 0007_timeseries_hypertables.sql
-- TimescaleDB hypertables (telemetry schema).
-- Source: db-documentation/04-timescale-design.md.
-- Hypertable unique/primary keys MUST include the time partition column.
-- Chunk intervals are initial tuning defaults, not game rules.

-- ---------------------------------------------------------------------------
-- telemetry.health_samples : one source-identified discrete reading.
--   partition measured_at, chunk 1 day; raw 7 days; hourly summaries 365 days.
-- ---------------------------------------------------------------------------
create table if not exists telemetry.health_samples (
  player_id        text not null references app.players(id) on delete cascade,
  source_system    text not null,
  source_sample_id text not null,
  metric           text not null,        -- heart_rate | resting_hr | hrv | ...
  measured_at      timestamptz not null,
  received_at      timestamptz not null default now(),
  value            double precision,
  unit             text,
  quality          text,
  primary key (player_id, source_system, source_sample_id, metric, measured_at)
);
select create_hypertable('telemetry.health_samples', 'measured_at',
       chunk_time_interval => interval '1 day', if_not_exists => true);
create index if not exists health_samples_player_metric_idx
  on telemetry.health_samples (player_id, metric, measured_at desc);

-- ---------------------------------------------------------------------------
-- telemetry.activity_observations : revisioned cumulative steps/energy/rings.
--   partition measured_at, chunk 1 day; raw 7 days.
-- ---------------------------------------------------------------------------
create table if not exists telemetry.activity_observations (
  player_id             text not null references app.players(id) on delete cascade,
  source_system         text not null,
  source_observation_id text not null,
  source_revision       integer not null,
  game_day_id           uuid,
  metric                text not null,     -- steps | active_energy | exercise | stand
  cumulative_value      double precision,  -- CUMULATIVE for the local day (never summed)
  coverage_interval     tstzrange,
  measured_at           timestamptz not null,
  received_at           timestamptz not null default now(),
  primary key (player_id, source_system, source_observation_id, source_revision, measured_at)
);
select create_hypertable('telemetry.activity_observations', 'measured_at',
       chunk_time_interval => interval '1 day', if_not_exists => true);
create index if not exists activity_obs_player_day_idx
  on telemetry.activity_observations (player_id, game_day_id, measured_at desc);

-- ---------------------------------------------------------------------------
-- telemetry.nutrition_deltas : signed fact legs (intake / reversal / replacement).
--   partition consumed_at, chunk 7 days; account-lifetime retention.
-- ---------------------------------------------------------------------------
create table if not exists telemetry.nutrition_deltas (
  meal_id        uuid not null,
  meal_revision  integer not null,
  item_id        uuid not null,
  leg            text not null check (leg in ('intake','reversal','replacement')),
  consumed_at    timestamptz not null,
  recorded_at    timestamptz not null default now(),
  player_id      text not null references app.players(id) on delete cascade,
  food_group     text,
  calories       double precision,        -- signed
  protein_g      double precision,
  carbs_g        double precision,
  fat_g          double precision,
  sodium_mg      double precision,
  known_value_counts jsonb not null default '{}'::jsonb,
  micronutrient_sum  jsonb not null default '{}'::jsonb,
  primary key (meal_id, meal_revision, item_id, leg, consumed_at)
);
select create_hypertable('telemetry.nutrition_deltas', 'consumed_at',
       chunk_time_interval => interval '7 days', if_not_exists => true);
create index if not exists nutrition_deltas_player_idx
  on telemetry.nutrition_deltas (player_id, consumed_at desc);

-- ---------------------------------------------------------------------------
-- telemetry.battle_events : ordered replay events.
--   partition stream_started_at, chunk 6 hours; replay 72h after terminal outcome.
-- ---------------------------------------------------------------------------
create table if not exists telemetry.battle_events (
  battle_id         uuid not null,
  stream_started_at timestamptz not null,   -- immutable stream anchor (groups a battle)
  sequence          bigint not null,        -- authoritative order
  occurred_at       timestamptz not null,   -- server event time
  event_type        text not null,          -- start | turn | damage | ko | floor | end
  payload           jsonb not null default '{}'::jsonb,
  payload_version   text not null,
  primary key (battle_id, stream_started_at, sequence)
);
select create_hypertable('telemetry.battle_events', 'stream_started_at',
       chunk_time_interval => interval '6 hours', if_not_exists => true);

-- ---------------------------------------------------------------------------
-- telemetry.battle_metrics : one participant fact per completed battle.
--   partition ended_at, chunk 7 days; 365 days; columnstore after 7 days.
-- ---------------------------------------------------------------------------
create table if not exists telemetry.battle_metrics (
  battle_id     uuid not null,
  player_id     text not null references app.players(id) on delete cascade,
  ended_at      timestamptz not null,       -- frozen once settled
  mode          text not null,
  season_id     uuid,
  result        text not null check (result in ('win','draw','loss')),
  rounds        integer,
  duration_s    integer,
  damage        double precision,
  contribution_snapshot jsonb not null default '{}'::jsonb,  -- versioned nutrition/activity inputs
  primary key (battle_id, player_id, ended_at)
);
select create_hypertable('telemetry.battle_metrics', 'ended_at',
       chunk_time_interval => interval '7 days', if_not_exists => true);
create index if not exists battle_metrics_player_idx
  on telemetry.battle_metrics (player_id, ended_at desc);

-- ---------------------------------------------------------------------------
-- telemetry.gameplay_events : bounded accepted-action facts.
--   partition occurred_at, chunk 1 day; 30 days.
-- ---------------------------------------------------------------------------
create table if not exists telemetry.gameplay_events (
  event_id      uuid not null,
  occurred_at   timestamptz not null,
  player_id     text not null references app.players(id) on delete cascade,
  event_type    text not null,      -- scan | open | quest_claim | achievement | dungeon | gym
  payload       jsonb not null default '{}'::jsonb,
  primary key (event_id, occurred_at)
);
select create_hypertable('telemetry.gameplay_events', 'occurred_at',
       chunk_time_interval => interval '1 day', if_not_exists => true);
create index if not exists gameplay_events_player_idx
  on telemetry.gameplay_events (player_id, occurred_at desc);
