-- 0010_lifecycle_policies.sql
-- Columnstore (compression) + retention lifecycle. Source: 04-timescale-design.md §Columnstore.
-- Windows are chosen so current demo/seed data (recent) is NOT dropped or compressed yet.
-- NOTE: battle_events gets NO blind retention policy on purpose — replay cleanup must be a
-- guarded job (ops.lifecycle_checkpoints) that protects active/unsettled battles.

-- ---- Columnstore compression for retained fact tables --------------------
-- nutrition_deltas: account-lifetime retention, compress old chunks for space.
alter table telemetry.nutrition_deltas
  set (timescaledb.compress,
       timescaledb.compress_segmentby = 'player_id',
       timescaledb.compress_orderby   = 'consumed_at desc');
select add_compression_policy('telemetry.nutrition_deltas', interval '7 days', if_not_exists => true);

-- battle_metrics: kept 365 days, compress after 7 days.
alter table telemetry.battle_metrics
  set (timescaledb.compress,
       timescaledb.compress_segmentby = 'player_id',
       timescaledb.compress_orderby   = 'ended_at desc');
select add_compression_policy('telemetry.battle_metrics', interval '7 days', if_not_exists => true);

-- ---- Retention (raw data lifecycle) --------------------------------------
-- Raw health/activity: 7-day rowstore window (hourly summaries live in analytics).
select add_retention_policy('telemetry.health_samples',       interval '7 days',  if_not_exists => true);
select add_retention_policy('telemetry.activity_observations', interval '7 days',  if_not_exists => true);
-- Gameplay events: 30 days.
select add_retention_policy('telemetry.gameplay_events',       interval '30 days', if_not_exists => true);
-- battle_metrics: 365 days (compressed after 7).
select add_retention_policy('telemetry.battle_metrics',        interval '365 days', if_not_exists => true);

-- ---- Retention for the hourly continuous aggregates (365 days) -----------
select add_retention_policy('analytics.health_hourly',   interval '365 days', if_not_exists => true);
select add_retention_policy('analytics.battle_hourly',   interval '365 days', if_not_exists => true);
select add_retention_policy('analytics.gameplay_hourly', interval '365 days', if_not_exists => true);
-- nutrition_hourly follows nutrition history (account lifetime): no retention policy.
