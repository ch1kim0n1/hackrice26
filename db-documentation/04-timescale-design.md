# 04 — TimescaleDB design and query plan

## Hypertables are for time-organized facts

A table does not need millisecond events to benefit from TimescaleDB. The useful questions are whether it grows over time, is usually queried within time ranges, needs reusable time summaries, and can have a sensible lifecycle. All six hypertables below share the same database and transactions as `app` tables.

The intervals below are **initial tuning defaults**. Measure chunk sizes, active indexes, write rates, and query plans before changing them. Do not create a separate hypertable per player, battle, metric, or day. No hash/space partitioning initially.

| Hypertable | Time partition / initial chunk | Fact stored | Primary access index in addition to required key | Lifecycle |
|---|---|---|---|---|
| `telemetry.health_samples` | `measured_at` / 1 day | One source-identified HR, resting HR, HRV, or other supported discrete reading with metric, value, unit, quality and `received_at` | `(player_id, metric, measured_at DESC)` | Raw 7 days; hourly summaries 365 days |
| `telemetry.activity_observations` | `measured_at` / 1 day | A revisioned source observation of cumulative steps/energy/rings for a stated local day and coverage interval | `(player_id, game_day_id, measured_at DESC)` | Raw 7 days; canonical daily totals retained in `app.daily_history` |
| `telemetry.nutrition_deltas` | `consumed_at` / 7 days | Positive intake and negative correction legs, with known-value counts, food group, item/meal/revision and `recorded_at` | `(player_id, consumed_at DESC)` | Account lifetime, unless food/history/account is deleted; older chunks use columnstore |
| `telemetry.battle_events` | `stream_started_at` / 6 hours | Ordered start/turn/damage/KO/floor/end events, each with `sequence`, `occurred_at`, type and bounded versioned payload | `(battle_id, stream_started_at, sequence)` | Replay 72 hours after terminal outcome; guarded chunk cleanup |
| `telemetry.battle_metrics` | `ended_at` / 7 days | One participant fact per authoritative completed battle: mode, season, win/draw, rounds, duration, damage, snapshotted nutrition/activity contribution | `(player_id, ended_at DESC)`; add mode/season index only after measuring | 365 days; columnstore after 7 days |
| `telemetry.gameplay_events` | `occurred_at` / 1 day | Bounded accepted-action facts: scan, open, quest claim, achievement, dungeon completion, verified gym event | `(player_id, occurred_at DESC)` | 30 days; summary history separate |

`battle_events.stream_started_at` is the battle's immutable stream anchor, not a claim about when an individual attack occurred. This groups a battle's events in one time chunk and enables direct replay lookup. `occurred_at` is server event time; `sequence` is authoritative order. For precomputed battles, logical turn/playback offsets are separate from wall-clock timestamps.

`battle_metrics` is not a raw turn log or reward ledger. Keeping it for a year enables efficient win/round/mode trends after raw replay detail expires. Each row includes a versioned snapshot of game-relevant nutrition/activity values, not another player's private medical readings.

## Keys and deduplication

Timescale unique keys must include the time partition column. Do not assume a UUID-only unique index on a hypertable is permitted. Global command identity belongs in the ordinary receipt tables. [Hypertable index rules](https://docs.tigerdata.com/use-timescale/latest/hypertables/hypertables-and-unique-indexes/)

Proposed keys:

- `health_samples`: `(player_id, source_system, source_sample_id, metric, measured_at)`.
- `activity_observations`: `(player_id, source_system, source_observation_id, source_revision, measured_at)`.
- `nutrition_deltas`: `(meal_id, meal_revision, item_id, leg, consumed_at)`; `leg` distinguishes reversal from replacement.
- `battle_events`: `(battle_id, stream_started_at, sequence)`; FK `(battle_id, stream_started_at)` references the matching unique key in `app.battles`.
- `battle_metrics`: `(battle_id, player_id, ended_at)`; end time is frozen once settled.
- `gameplay_events`: `(event_id, occurred_at)`; stable ID and timestamp allocated by the original transaction, reused on retry.

Keep relationships through ordinary parent records. Do not design cross-hypertable foreign keys. Check exact extension constraints on the actual service during phase 0. Changing a partition timestamp is modeled as delete-old plus insert-new within one transaction, not an upsert that moves a row between chunks. [Documented limitations](https://docs.tigerdata.com/timescaledb/latest/overview/limitations/)

## Health ingestion: correct before fast

1. Collect original HealthKit sample/workout IDs, their actual measurement times, units, source, and deletion/correction information. A time attached to an upload is not automatically the measurement time of every field in it.
2. The server derives the player from authentication. Device identity is checked against that player. Normalize units, enforce bounded batch size and plausible field ranges, and retain unknown/unsupported states rather than inventing zeros.
3. Accept raw samples within the last 7 days, with a small clock-skew tolerance (initially 5 minutes into the future). Reject/quarantine impossible timestamps and unknown units; return per-item reasons. Older data is not inserted into expiring raw chunks.
4. `ops.ingest_keys` makes retried uploads and source revisions idempotent. Its 30-day retention exceeds the raw admissible age. Tombstones prevent resurrection of deleted samples. Reusing a source revision with a different hash is a conflict, not an extra reading.
5. For a correction, update/delete the canonical source fact transactionally and schedule bounded aggregate refresh for every affected bucket. Samples arriving in the oldest seventh day need an explicit refresh because the ordinary refresh window is only six days.
6. Update `daily_activity` from a defined consolidated HealthKit source/coverage revision. Never sum watch and phone representations of the same underlying samples. A legitimate correction may decrease a total, so “always take the maximum” is also not a universal rule.
7. Preserve steps/active energy/exercise/stand as cumulative observations. Example: 2,000 steps followed by 2,600 steps means a current total of 2,600, not 4,600. Deltas are safe only within a validated source/day stream, with reset/correction handling.
8. Finalized daily summaries may accept explicitly revisioned historical day-total corrections for the last 30 days without importing discarded raw detail. They do not reopen game rewards. Older historical imports are a separately authorized backfill, not a normal ingestion loophole.

Simple HR/HRV averages are **sample averages**, not time-weighted physiological measurements. Store count, sum, min/max and quality coverage; label absent periods and do not interpolate zeros. No health-derived combat effect is refreshed mid-battle.

## Nutrition corrections that do not double-count

`nutrition_deltas` is a signed fact table, not another copy of the mutable meal row.

Example: a confirmed portion contributed 600 kcal and is corrected to 450 kcal. Keep the original +600 leg, then insert a -600 old leg and +450 new leg for the new revision. Sum = 450. Repeated delivery of the same confirmation/revision cannot add another set of legs.

Include explicit numeric columns for the nutrients used by the app, item-count deltas, micronutrient-score sum/count deltas, and per-nutrient known-value counts. An unknown nutrient is not a known zero. Never average signed rows directly; calculate a meaningful mean from corrected sums and corrected counts, with zero-denominator protection.

Reversals use the original `consumed_at`; replacements use the revised consumption time. Recompute both affected daily-state/history records and refresh both historical aggregate buckets. For changes older than the automatic seven-day window, enqueue a narrowly bounded refresh. Account-lifetime retention of these low-volume meal facts makes historical correction possible; columnstore is a space optimization, not deletion. Source meals remain the durable canonical record.

Combat caps, barcode deduplication, and diversity/objective decisions come from the canonical accepted intake/eligibility records and pinned rule code, not a raw count of all delta rows. Ordinary `daily_history` handles per-player local-day totals; UTC hourly aggregates are not mislabeled as local calendar days.

## Continuous aggregates

| Aggregate | Source / grouping | Initial refresh schedule | Automatic window | Primary consumer |
|---|---|---|---|---|
| `analytics.health_hourly` | Health samples; UTC hour/player/metric; sum/count/min/max | Every 10 minutes | Start 6 days ago, end 1 hour ago | Health/Journey history |
| `analytics.nutrition_hourly` | Nutrition deltas; UTC hour/player; corrected sums/counts | Every 15 minutes | Start 7 days ago, end 1 hour ago | Nutrition trends, bounded custom windows |
| `analytics.battle_hourly` | Battle metrics; UTC hour/player/mode/season; counts, sums, wins | Every 5 minutes | Start 2 days ago, end 1 hour ago | Battle/Journey trends |
| `analytics.gameplay_hourly` | Accepted gameplay events; UTC hour/player/event type | Every 15 minutes | Start 2 days ago, end 1 hour ago | Recent activity trends; optional in first release |

Retain health, battle and gameplay hourly summaries for 365 days. Nutrition hourly summaries follow the retained nutrition history unless explicitly deleted. Do not make a continuous aggregate over a huge join of all six hypertables. Aggregate one fact source, then join small result sets or ordinary dimensions at query time. Changes to an ordinary joined table are not automatically tracked like changes to the source hypertable; snapshot analytical dimensions that must remain historically stable. [Continuous aggregates](https://www.tigerdata.com/docs/learn/continuous-aggregates)

Explicitly choose materialized-only or real-time behavior in each migration. Real-time aggregation is not enabled by default in modern Timescale versions. It can include the newest unmaterialized raw tail; it does not make arbitrary old late-arriving data instantly refreshed. Display `asOf`, `lastMeasuredAt`, and `pendingRefresh` where useful. A 5-minute refresh schedule with an excluded current hour does NOT alone mean data is at most five minutes stale.

For current health displays either query the latest indexed sample directly or explicitly enable the bounded raw tail. For current gameplay, use `app.daily_state`. Old-day late data has a refresh job and visible status until processed.

Never refresh a historical range after its source chunks were dropped and expect the old summary to survive. Guard cleanup with completed refresh watermarks; use finite refresh windows and pause destructive cleanup on a lifecycle failure. A recovery job after a long outage must refresh surviving raw ranges explicitly before dropping them. [Retention with continuous aggregates](https://www.tigerdata.com/docs/learn/data-lifecycle/data-retention/data-retention-with-continuous-aggregates)

## Columnstore and tiering

- Enable columnstore initially for retained nutrition deltas and battle metrics after 7 days, and for older aggregate chunks after 30 days where supported and measured useful.
- Keep three-day battle streams and seven-day raw health/activity in rowstore initially. Their short lifespan gives little reason to compress just before deleting them.
- Begin with `segmentby = player_id` and time-descending order for retained personal fact tables; measure sparse-player segment sizes before adopting this blindly for every aggregate.
- Do not advertise a fixed compression ratio. Test realistic representative data, indexes, and correction workloads.
- Modern columnstore can support writes/updates, but old-chunk corrections still need load testing. Exact APIs/default policies are service-version dependent. Inspect any automatically created policies before adding custom ones. [Hypercore behavior](https://www.tigerdata.com/docs/learn/columnar-storage/understand-hypercore)
- No tiered storage, replica, or archive tier initially. Add only if retained volume and measured query patterns justify it; this is independent of application photo storage.

## SQL and polling examples

Illustrative query shapes, **not migrations**:

```sql
-- The API first authorizes the player against battle_participants.
-- Bind the immutable stream anchor read from app.battles.
SELECT sequence, occurred_at, event_type, payload
FROM telemetry.battle_events
WHERE battle_id = $1
  AND stream_started_at = $2
  AND sequence > $3
ORDER BY sequence
LIMIT $4;

-- Latest known reading: one player's bounded recent interval.
SELECT measured_at, value, unit, quality
FROM telemetry.health_samples
WHERE player_id = $1 AND metric = $2
  AND measured_at >= $3 AND measured_at < $4
ORDER BY measured_at DESC
LIMIT 1;

-- Join ordinary PostgreSQL metadata with time facts in the same database.
SELECT b.id, b.mode, e.sequence, e.event_type
FROM app.battles AS b
JOIN telemetry.battle_events AS e
  ON e.battle_id = b.id AND e.stream_started_at = b.stream_started_at
WHERE b.id = $1 AND e.stream_started_at = $2
ORDER BY e.sequence
LIMIT $3;
```

All list queries require owner/participant scope, a range or exact partition anchor, stable pagination, and a bounded limit. Paginate series by `(time, stable_id)` and events by sequence; avoid large offsets.

| Situation | Query/delivery policy |
|---|---|
| Automatic battle start | Persist and return/stream committed bounded event pages once; local playback afterwards |
| Interactive accepted turn | One domain transaction per accepted action; publish committed events; no per-frame writes |
| Battle reconnect | One result/checkpoint read plus missing event pages using the last acknowledged sequence |
| Health dashboard visible | Fetch on open; coalesce refreshes, initially at most once per minute while visible; background uploads can signal invalidation |
| Journey visible | Fetch on open; revalidate after relevant actions or roughly every 5 minutes while visible |
| Hourly/end-of-battle analytics | Query summaries/compact results; no need to rescan every turn or reading |
| App background/offline | No constant dashboard polling; queue permitted uploads and use cache |

Refresh jobs run per aggregate, not per user. SQL does execute in Tiger Cloud for data hosted there, but the above patterns reduce repeated work substantially without adding a second cloud database.
