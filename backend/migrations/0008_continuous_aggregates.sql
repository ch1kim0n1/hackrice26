-- 0008_continuous_aggregates.sql
-- Continuous aggregates (analytics schema) + refresh policies.
-- Source: db-documentation/04-timescale-design.md (Continuous aggregates).
-- Each aggregate reads ONE hypertable (no cross-hypertable joins).
-- materialized_only = false enables real-time aggregation: the newest raw tail is
-- included on read, so trends are visible without waiting for the background job.

-- analytics.health_hourly : UTC hour / player / metric ; sum/count/min/max.
create materialized view analytics.health_hourly
  with (timescaledb.continuous, timescaledb.materialized_only = false) as
select
  time_bucket(interval '1 hour', measured_at) as bucket,
  player_id,
  metric,
  count(value)              as sample_count,
  sum(value)                as value_sum,
  min(value)                as value_min,
  max(value)                as value_max
from telemetry.health_samples
group by 1, 2, 3
with no data;

select add_continuous_aggregate_policy('analytics.health_hourly',
  start_offset => interval '6 days',
  end_offset   => interval '1 hour',
  schedule_interval => interval '10 minutes');

-- analytics.nutrition_hourly : UTC hour / player ; corrected (signed) sums/counts.
create materialized view analytics.nutrition_hourly
  with (timescaledb.continuous, timescaledb.materialized_only = false) as
select
  time_bucket(interval '1 hour', consumed_at) as bucket,
  player_id,
  count(*)          as leg_count,
  sum(calories)     as calories_sum,
  sum(protein_g)    as protein_sum,
  sum(carbs_g)      as carbs_sum,
  sum(fat_g)        as fat_sum,
  sum(sodium_mg)    as sodium_sum
from telemetry.nutrition_deltas
group by 1, 2
with no data;

select add_continuous_aggregate_policy('analytics.nutrition_hourly',
  start_offset => interval '7 days',
  end_offset   => interval '1 hour',
  schedule_interval => interval '15 minutes');

-- analytics.battle_hourly : UTC hour / player / mode / season ; counts, sums, wins.
create materialized view analytics.battle_hourly
  with (timescaledb.continuous, timescaledb.materialized_only = false) as
select
  time_bucket(interval '1 hour', ended_at) as bucket,
  player_id,
  mode,
  season_id,
  count(*)                                    as battles,
  count(*) filter (where result = 'win')      as wins,
  count(*) filter (where result = 'draw')     as draws,
  sum(damage)                                 as damage_sum,
  sum(rounds)                                 as rounds_sum
from telemetry.battle_metrics
group by 1, 2, 3, 4
with no data;

select add_continuous_aggregate_policy('analytics.battle_hourly',
  start_offset => interval '2 days',
  end_offset   => interval '1 hour',
  schedule_interval => interval '5 minutes');

-- analytics.gameplay_hourly : UTC hour / player / event type.
create materialized view analytics.gameplay_hourly
  with (timescaledb.continuous, timescaledb.materialized_only = false) as
select
  time_bucket(interval '1 hour', occurred_at) as bucket,
  player_id,
  event_type,
  count(*) as events
from telemetry.gameplay_events
group by 1, 2, 3
with no data;

select add_continuous_aggregate_policy('analytics.gameplay_hourly',
  start_offset => interval '2 days',
  end_offset   => interval '1 hour',
  schedule_interval => interval '15 minutes');
