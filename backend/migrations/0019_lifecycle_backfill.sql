-- 0019_lifecycle_backfill.sql -- lifecycle for the hypertables 0010 never saw.
--
-- 0010 set columnstore + retention for the hypertables that existed when it
-- ran. Three arrived later and were never enrolled:
--
--   telemetry.body_metrics   (0012)
--   telemetry.gamble_events  (0015)
--   telemetry.battle_events  (0007, but deliberately skipped by 0010)
--
-- Same shape of drift as the RLS gap 0017 closed. The fix is NOT "compress
-- everything", because two of the three cannot be compressed at all:
--
--   > ROW LEVEL SECURITY is not supported on chunks in the columnstore.
--   https://www.tigerdata.com/docs/reference/timescaledb/hypercore#limitations
--
-- and ENABLE/DISABLE ROW SECURITY is itself a blocked operation once
-- columnstore is on. app.gamble_events carries player_isolation from 0015 and
-- body_metrics from 0017, and the app is in the process of switching to the
-- restricted role that makes those policies load-bearing. Dropping RLS to save
-- disk on two small tables would trade the security boundary for nothing.
--
-- 0010 already made this same trade in the other direction, quietly:
-- nutrition_deltas and battle_metrics are compressed and therefore carry no
-- RLS, which 0011 documents as a deliberate skip. This file makes the opposite
-- call for these two, and says so out loud.

-- ---------------------------------------------------------------------------
-- telemetry.gamble_events -- retention only.
--
-- The raw row is what a disputed wager is replayed against, so 90 days is the
-- window a player could plausibly argue over. analytics.gamble_hourly keeps
-- the trend for a year, so the casino chart does not lose history when the raw
-- rows age out.
-- ---------------------------------------------------------------------------
select add_retention_policy('telemetry.gamble_events', interval '90 days', if_not_exists => true);
select add_retention_policy('analytics.gamble_hourly', interval '365 days', if_not_exists => true);

-- ---------------------------------------------------------------------------
-- telemetry.body_metrics -- deliberately no policy at all.
--
-- A weigh-in history is the feature. Dropping it after N days would delete the
-- thing the user opened the screen to see, so no retention. And it is a handful
-- of rows per player per month, so compression would buy nothing even if RLS
-- allowed it. Recorded here so the next person reads a decision instead of
-- finding another gap.
-- ---------------------------------------------------------------------------

-- ---------------------------------------------------------------------------
-- telemetry.battle_events -- columnstore, still no retention.
--
-- No player_id column, so no RLS policy, so nothing blocks columnstore. Replay
-- events are the bulkiest stream in the schema and the least often read once a
-- battle is settled, which is exactly the columnstore's case.
--
-- Retention stays off for the reason 0010 gives: replay cleanup has to be a
-- guarded job that protects active/unsettled battles, not a blind age policy.
-- Compression is a different question from deletion and is safe here.
-- ---------------------------------------------------------------------------
alter table telemetry.battle_events
  set (timescaledb.compress,
       timescaledb.compress_segmentby = 'battle_id',
       timescaledb.compress_orderby   = 'stream_started_at desc, sequence');
select add_compression_policy('telemetry.battle_events', interval '30 days', if_not_exists => true);

-- No ledger row is written here: the runner (backend/src/db/migrate-pg.ts)
-- records every file it applies, in the same transaction.
