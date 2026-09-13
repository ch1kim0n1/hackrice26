// Read side for the continuous aggregates (analytics.*).
//
// Until this file existed, every rollup in the schema was write-only: the
// hypertables filled, the aggregates refreshed on schedule, and nothing ever
// selected from them. healthRepo.getHourlyHealth was the single read function
// in the codebase and no route called it. That is the gap this closes.
//
// Everything here goes through getReplicaPool(), which is the app pool until
// DATABASE_URL_REPLICA is set and a Tiger Cloud read replica behind it
// afterwards -- so a dashboard query stops competing with the write path the
// moment a replica is provisioned, with no code change.
//
// These read as the restricted role, so RLS confines every row to the player
// in `app.current_player`. The explicit `player_id = $1` predicate is still
// there: it is what lets the index do the work, and it keeps the query correct
// if it is ever run as the owner (which bypasses RLS).
// Gapfilled series use `time_bucket_gapfill`, which is the reason a chart of
// these is honest. Without it an hour with no play is simply absent from the
// result, so a bar chart draws the surrounding hours adjacent and a two-hour
// dead patch disappears rather than showing as a flat run. Three rules it
// imposes, all of which cost a query if you miss them:
//   - the WHERE clause needs an UPPER bound as well as a lower one, or the
//     function has no end to fill up to;
//   - the call must be the top-level SELECT expression, not wrapped in
//     anything, and referenced in GROUP BY by its alias;
//   - exactly one call per query.
import { getReplicaPool } from "../pg";

/** Hours of history a trend query will look back over, clamped. */
const MAX_WINDOW_HOURS = 24 * 90;

function windowHours(requested: number, fallback: number): number {
  if (!Number.isFinite(requested) || requested <= 0) return fallback;
  return Math.min(Math.floor(requested), MAX_WINDOW_HOURS);
}

async function bucketQuery<T>(
  sql: string,
  params: unknown[],
  map: (row: Record<string, unknown>) => T
): Promise<T[]> {
  const { rows } = await getReplicaPool().query(sql, params as never[]);
  return rows.map(map);
}

const num = (v: unknown): number => (v === null || v === undefined ? 0 : Number(v));
const maybeNum = (v: unknown): number | null => (v === null || v === undefined ? null : Number(v));

// --- Casino -----------------------------------------------------------------

export interface GambleTrendPoint {
  bucket: string;
  mode: string;
  plays: number;
  wagered: number;
  netChange: number;
  wins: number;
}

/** Hourly casino outcomes per game mode -- the "how has my luck actually run"
 *  series behind the casino chart. */
export async function getGambleTrend(
  playerId: string,
  sinceHours = 72
): Promise<GambleTrendPoint[]> {
  return bucketQuery(
    // Aliased gf_bucket, not bucket: the source column is also called bucket,
    // and GROUP BY would bind to that instead of to the gapfill call, which
    // fails with "no top level time_bucket_gapfill in group by clause".
    `select time_bucket_gapfill('1 hour', bucket) as gf_bucket,
            mode,
            coalesce(sum(plays), 0)       as plays,
            coalesce(sum(wagered), 0)     as wagered,
            coalesce(sum(net_change), 0)  as net_change,
            coalesce(sum(wins), 0)        as wins
       from analytics.gamble_hourly
      where player_id = $1
        and bucket >= time_bucket('1 hour', now() - ($2 || ' hours')::interval)
        and bucket <  time_bucket('1 hour', now() + interval '1 hour')
      group by gf_bucket, mode
      order by gf_bucket asc, mode asc`,
    [playerId, String(windowHours(sinceHours, 72))],
    (r) => ({
      bucket: String(r.gf_bucket instanceof Date ? r.gf_bucket.toISOString() : r.gf_bucket),
      mode: String(r.mode),
      plays: num(r.plays),
      wagered: num(r.wagered),
      netChange: num(r.net_change),
      wins: num(r.wins),
    })
  );
}

// --- Nutrition --------------------------------------------------------------

export interface NutritionTrendPoint {
  bucket: string;
  legCount: number;
  calories: number;
  protein: number;
  carbs: number;
  fat: number;
  sodium: number;
}

/** Hourly intake. Signed legs, already netted by the aggregate -- a correction
 *  reverses its original rather than being subtracted twice. */
export async function getNutritionTrend(
  playerId: string,
  sinceHours = 24 * 7
): Promise<NutritionTrendPoint[]> {
  return bucketQuery(
    `select bucket, leg_count, calories_sum, protein_sum, carbs_sum, fat_sum, sodium_sum
       from analytics.nutrition_hourly
      where player_id = $1
        and bucket >= now() - ($2 || ' hours')::interval
      order by bucket asc`,
    [playerId, String(windowHours(sinceHours, 24 * 7))],
    (r) => ({
      bucket: String(r.bucket instanceof Date ? r.bucket.toISOString() : r.bucket),
      legCount: num(r.leg_count),
      calories: num(r.calories_sum),
      protein: num(r.protein_sum),
      carbs: num(r.carbs_sum),
      fat: num(r.fat_sum),
      sodium: num(r.sodium_sum),
    })
  );
}

// --- Battles ----------------------------------------------------------------

export interface BattleTrendPoint {
  bucket: string;
  mode: string;
  battles: number;
  wins: number;
  draws: number;
  damage: number;
  rounds: number;
}

export async function getBattleTrend(
  playerId: string,
  sinceHours = 24 * 14
): Promise<BattleTrendPoint[]> {
  return bucketQuery(
    `select bucket, mode, battles, wins, draws, damage_sum, rounds_sum
       from analytics.battle_hourly
      where player_id = $1
        and bucket >= now() - ($2 || ' hours')::interval
      order by bucket asc, mode asc`,
    [playerId, String(windowHours(sinceHours, 24 * 14))],
    (r) => ({
      bucket: String(r.bucket instanceof Date ? r.bucket.toISOString() : r.bucket),
      mode: String(r.mode),
      battles: num(r.battles),
      wins: num(r.wins),
      draws: num(r.draws),
      damage: num(r.damage_sum),
      rounds: num(r.rounds_sum),
    })
  );
}

// --- Gameplay ---------------------------------------------------------------

export interface GameplayTrendPoint {
  bucket: string;
  eventType: string;
  events: number;
}

export async function getGameplayTrend(
  playerId: string,
  sinceHours = 24 * 7
): Promise<GameplayTrendPoint[]> {
  return bucketQuery(
    `select bucket, event_type, events
       from analytics.gameplay_hourly
      where player_id = $1
        and bucket >= now() - ($2 || ' hours')::interval
      order by bucket asc, event_type asc`,
    [playerId, String(windowHours(sinceHours, 24 * 7))],
    (r) => ({
      bucket: String(r.bucket instanceof Date ? r.bucket.toISOString() : r.bucket),
      eventType: String(r.event_type),
      events: num(r.events),
    })
  );
}

// --- Streaks (0020) ---------------------------------------------------------

export interface StreakTrendPoint {
  bucket: string;
  streakEnd: number;
  bestStreak: number;
  qualifiedDays: number;
  freezesUsed: number;
}

/** Daily consistency. The product's own pitch is that consistency is the
 *  power; this is the only place that claim has a time series behind it. */
export async function getStreakTrend(
  playerId: string,
  sinceHours = 24 * 90
): Promise<StreakTrendPoint[]> {
  return bucketQuery(
    `select bucket, streak_end, best_streak, qualified_days, freezes_used
       from analytics.streak_daily
      where player_id = $1
        and bucket >= now() - ($2 || ' hours')::interval
      order by bucket asc`,
    [playerId, String(windowHours(sinceHours, 24 * 90))],
    (r) => ({
      bucket: String(r.bucket instanceof Date ? r.bucket.toISOString() : r.bucket),
      streakEnd: num(r.streak_end),
      bestStreak: num(r.best_streak),
      qualifiedDays: num(r.qualified_days),
      freezesUsed: num(r.freezes_used),
    })
  );
}

// --- Pull luck (0020) -------------------------------------------------------

export interface AcquisitionTrendPoint {
  bucket: string;
  rarity: string;
  pulls: number;
  worthGained: number;
  bestStar: number;
}

/** Rarity mix over time. app.character_acquisitions can say what you own; only
 *  this can say whether the last week pulled better than the one before. */
export async function getAcquisitionTrend(
  playerId: string,
  sinceHours = 24 * 30
): Promise<AcquisitionTrendPoint[]> {
  return bucketQuery(
    `select bucket, rarity, pulls, worth_gained, best_star
       from analytics.acquisition_hourly
      where player_id = $1
        and bucket >= now() - ($2 || ' hours')::interval
      order by bucket asc, rarity asc`,
    [playerId, String(windowHours(sinceHours, 24 * 30))],
    (r) => ({
      bucket: String(r.bucket instanceof Date ? r.bucket.toISOString() : r.bucket),
      rarity: String(r.rarity),
      pulls: num(r.pulls),
      worthGained: num(r.worth_gained),
      bestStar: num(r.best_star),
    })
  );
}

// --- Dungeon depth (0020) ---------------------------------------------------

export interface DungeonTrendPoint {
  bucket: string;
  deepestFloor: number;
  floorsAttempted: number;
  floorsCleared: number;
}

export async function getDungeonTrend(
  playerId: string,
  sinceHours = 24 * 30
): Promise<DungeonTrendPoint[]> {
  return bucketQuery(
    `select bucket, deepest_floor, floors_attempted, floors_cleared
       from analytics.dungeon_daily
      where player_id = $1
        and bucket >= now() - ($2 || ' hours')::interval
      order by bucket asc`,
    [playerId, String(windowHours(sinceHours, 24 * 30))],
    (r) => ({
      bucket: String(r.bucket instanceof Date ? r.bucket.toISOString() : r.bucket),
      deepestFloor: num(r.deepest_floor),
      floorsAttempted: num(r.floors_attempted),
      floorsCleared: num(r.floors_cleared),
    })
  );
}

// --- Health (kept alongside healthRepo's own reader) ------------------------

export interface HealthTrendPoint {
  bucket: string;
  metric: string;
  sampleCount: number;
  valueMin: number | null;
  valueMax: number | null;
  valueAvg: number | null;
}

export async function getHealthTrend(
  playerId: string,
  metric: string,
  sinceHours = 24
): Promise<HealthTrendPoint[]> {
  return bucketQuery(
    // locf on the average: a heart rate does not stop existing because the
    // watch missed an hour, so carrying the last reading forward reads truer
    // than a hole. Counts are NOT carried forward -- zero samples is a fact.
    `select time_bucket_gapfill('1 hour', bucket) as gf_bucket,
            $2::text                              as metric,
            coalesce(sum(sample_count), 0)        as sample_count,
            min(value_min)                        as value_min,
            max(value_max)                        as value_max,
            locf(
              case when sum(sample_count) > 0
                   then sum(value_sum) / sum(sample_count) end
            )                                     as value_avg
       from analytics.health_hourly
      where player_id = $1 and metric = $2
        and bucket >= time_bucket('1 hour', now() - ($3 || ' hours')::interval)
        and bucket <  time_bucket('1 hour', now() + interval '1 hour')
      group by gf_bucket
      order by gf_bucket asc`,
    [playerId, metric, String(windowHours(sinceHours, 24))],
    (r) => ({
      bucket: String(r.gf_bucket instanceof Date ? r.gf_bucket.toISOString() : r.gf_bucket),
      metric: String(r.metric),
      sampleCount: num(r.sample_count),
      valueMin: maybeNum(r.value_min),
      valueMax: maybeNum(r.value_max),
      valueAvg: maybeNum(r.value_avg),
    })
  );
}
