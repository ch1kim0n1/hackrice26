// Health repository — the TigerData wiring TEMPLATE for the hypertable path.
//
// This is what "wiring a feature to the database" looks like: a typed module
// that owns the SQL for one domain, writes to hypertables inside a per-player
// transaction (so RLS applies once the app connects as the restricted role),
// and reads trends from a continuous aggregate. Routes call these functions;
// no SQL lives in route handlers. Every other feature follows this shape.
import { PoolClient } from "pg";
import { getReplicaPool, getPool, withPlayer } from "../pg";
import { ensurePlayer } from "./players";
import { HealthSnapshot } from "../../types";

export interface HealthSampleInput {
  sourceSystem: string;     // e.g. "watch"
  sourceSampleId: string;   // stable id from HealthKit (dedupe key)
  metric: string;           // "heart_rate" | "hrv" | "resting_heart_rate" | ...
  measuredAt: string;       // ISO 8601 instant the reading was taken
  value: number;
  unit: string;
  quality?: string;
}

export interface BodyMetricInput {
  loggedAt: string;         // ISO 8601
  weightKg: number;
  bodyFatPct?: number;
  source?: "manual" | "healthkit" | "onboarding";
}

export interface HourlyHealthPoint {
  bucket: string;
  metric: string;
  sampleCount: number;
  valueMin: number | null;
  valueMax: number | null;
  valueAvg: number | null;
}

/** Insert normalized health samples into the hypertable. Idempotent on the
 *  natural key (player, source system, source sample id, metric, time) so a
 *  retried upload does not create duplicate readings. */
export async function recordHealthSamples(
  playerId: string,
  samples: HealthSampleInput[]
): Promise<number> {
  if (samples.length === 0) return 0;
  return withPlayer(playerId, async (client: PoolClient) => {
    await ensurePlayer(client, playerId);
    let written = 0;
    for (const s of samples) {
      const r = await client.query(
        `insert into telemetry.health_samples
           (player_id, source_system, source_sample_id, metric, measured_at, value, unit, quality)
         values ($1,$2,$3,$4,$5,$6,$7,$8)
         on conflict (player_id, source_system, source_sample_id, metric, measured_at) do nothing`,
        [playerId, s.sourceSystem, s.sourceSampleId, s.metric, s.measuredAt, s.value, s.unit, s.quality ?? null]
      );
      written += r.rowCount ?? 0;
    }
    return written;
  });
}

/** Append a weigh-in to the body_metrics hypertable. */
export async function recordBodyMetric(playerId: string, m: BodyMetricInput): Promise<void> {
  await withPlayer(playerId, async (client) => {
    await ensurePlayer(client, playerId);
    await client.query(
      `insert into telemetry.body_metrics (player_id, logged_at, weight_kg, body_fat_pct, source)
       values ($1,$2,$3,$4,$5)
       on conflict (player_id, logged_at) do update
         set weight_kg = excluded.weight_kg,
             body_fat_pct = excluded.body_fat_pct,
             source = excluded.source`,
      [playerId, m.loggedAt, m.weightKg, m.bodyFatPct ?? null, m.source ?? "manual"]
    );
  });
}

// Snapshot field -> (hypertable metric name, unit) for discrete instantaneous readings.
const DISCRETE_METRICS: Array<[keyof HealthSnapshot, string, string]> = [
  ["heartRateBpm", "heart_rate", "bpm"],
  ["restingHeartRateBpm", "resting_heart_rate", "bpm"],
  ["hrvMs", "hrv", "ms"],
];
// Snapshot field -> activity metric name for CUMULATIVE ring/day totals.
const CUMULATIVE_METRICS: Array<[keyof HealthSnapshot, string]> = [
  ["stepsToday", "steps"],
  ["activeCaloriesToday", "active_energy"],
  ["exerciseMinutesToday", "exercise"],
  ["standHoursToday", "stand"],
];

/** Mirror one validated HealthKit snapshot into the TigerData hypertables:
 *  discrete readings -> telemetry.health_samples, cumulative rings ->
 *  telemetry.activity_observations, workouts -> app.workouts. One transaction,
 *  idempotent on natural keys so a resent snapshot never double-writes. Returns
 *  a count of rows actually inserted (for logging/tests). */
export async function mirrorSnapshot(
  playerId: string,
  snapshot: HealthSnapshot
): Promise<{ samples: number; activity: number; workouts: number }> {
  return withPlayer(playerId, async (client: PoolClient) => {
    await ensurePlayer(client, playerId);
    const at = snapshot.timestamp;
    let samples = 0;
    let activity = 0;
    let workouts = 0;

    for (const [field, metric, unit] of DISCRETE_METRICS) {
      const value = snapshot[field] as number | null;
      if (value === null || value === undefined) continue;
      const r = await client.query(
        `insert into telemetry.health_samples
           (player_id, source_system, source_sample_id, metric, measured_at, value, unit, quality)
         values ($1,'ios_snapshot',$2,$3,$4,$5,$6,'reported')
         on conflict (player_id, source_system, source_sample_id, metric, measured_at) do nothing`,
        [playerId, `${at}:${metric}`, metric, at, value, unit]
      );
      samples += r.rowCount ?? 0;
    }

    for (const [field, metric] of CUMULATIVE_METRICS) {
      const value = snapshot[field] as number | null;
      if (value === null || value === undefined) continue;
      const r = await client.query(
        `insert into telemetry.activity_observations
           (player_id, source_system, source_observation_id, source_revision, metric, cumulative_value, measured_at)
         values ($1,'ios_snapshot',$2,1,$3,$4,$5)
         on conflict do nothing`,
        [playerId, `${at}:${metric}`, metric, value, at]
      );
      activity += r.rowCount ?? 0;
    }

    for (const w of snapshot.recentWorkouts ?? []) {
      const r = await client.query(
        `insert into app.workouts
           (player_id, source_system, source_workout_id, workout_type, started_at, ended_at, duration_s, energy_kcal)
         values ($1,'healthkit',$2,$3,$4,$5,$6,$7)
         on conflict (player_id, source_system, source_workout_id) do nothing`,
        [playerId, `${w.start}:${w.activityType}`, w.activityType, w.start, w.end,
         Math.round((w.durationMinutes ?? 0) * 60), w.activeCalories ?? null]
      );
      workouts += r.rowCount ?? 0;
    }

    return { samples, activity, workouts };
  });
}

/** Read hourly trend for one metric from the continuous aggregate (real-time). */
export async function getHourlyHealth(
  playerId: string,
  metric: string,
  sinceHours = 24
): Promise<HourlyHealthPoint[]> {
  const { rows } = await getReplicaPool().query(
    `select bucket, metric, sample_count,
            value_min, value_max,
            case when sample_count > 0 then value_sum / sample_count end as value_avg
       from analytics.health_hourly
      where player_id = $1 and metric = $2
        and bucket >= now() - ($3 || ' hours')::interval
      order by bucket desc`,
    [playerId, metric, String(sinceHours)]
  );
  return rows.map((r) => ({
    bucket: r.bucket,
    metric: r.metric,
    sampleCount: Number(r.sample_count),
    valueMin: r.value_min === null ? null : Number(r.value_min),
    valueMax: r.value_max === null ? null : Number(r.value_max),
    valueAvg: r.value_avg === null ? null : Number(r.value_avg),
  }));
}
