// Hand-rolled validation.
//
// The backend has no schema library and adding one for a single payload is not
// worth the dependency. The rules below are loose sanity bounds meant to catch a
// broken client or a unit mix-up -- not to make any clinical judgement.

import { FieldError, HealthSnapshot, WorkoutSummary } from "../types";

type Range = { min: number; max: number };

const METRIC_RANGES: Record<string, Range> = {
  heartRateBpm: { min: 20, max: 250 },
  restingHeartRateBpm: { min: 20, max: 150 },
  hrvMs: { min: 0, max: 500 },
  stepsToday: { min: 0, max: 200_000 },
  activeCaloriesToday: { min: 0, max: 20_000 },
  exerciseMinutesToday: { min: 0, max: 24 * 60 },
  exerciseGoalMinutes: { min: 0, max: 24 * 60 },
  standHoursToday: { min: 0, max: 24 },
  standGoalHours: { min: 0, max: 24 }
};

const WORKOUT_RANGES: Record<string, Range> = {
  durationMinutes: { min: 0, max: 24 * 60 },
  activeCalories: { min: 0, max: 20_000 },
  distanceMeters: { min: 0, max: 1_000_000 },
  averageHeartRateBpm: { min: 20, max: 250 },
  maxHeartRateBpm: { min: 20, max: 250 }
};

const TESTER_ID = /^[A-Za-z0-9_.-]{1,64}$/;

export type ValidationResult =
  | { ok: true; snapshot: HealthSnapshot }
  | { ok: false; errors: FieldError[] };

function isObject(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function isoTimestamp(value: unknown): boolean {
  return typeof value === "string" && !Number.isNaN(Date.parse(value));
}

/** Optional numeric metric: absent, null, or a finite number inside `range`. */
function readMetric(
  source: Record<string, unknown>,
  field: string,
  range: Range,
  errors: FieldError[],
  prefix = ""
): number | null {
  const raw = source[field];
  if (raw === undefined || raw === null) return null;

  if (typeof raw !== "number" || !Number.isFinite(raw)) {
    errors.push({ field: prefix + field, reason: "must be a number or null" });
    return null;
  }
  if (raw < range.min || raw > range.max) {
    errors.push({
      field: prefix + field,
      reason: `must be between ${range.min} and ${range.max}`
    });
    return null;
  }
  return raw;
}

function validateWorkout(
  raw: unknown,
  index: number,
  errors: FieldError[]
): WorkoutSummary | null {
  const prefix = `recentWorkouts[${index}].`;
  if (!isObject(raw)) {
    errors.push({ field: `recentWorkouts[${index}]`, reason: "must be an object" });
    return null;
  }

  const activityType = raw.activityType;
  if (typeof activityType !== "string" || !activityType.length || activityType.length > 64) {
    errors.push({ field: prefix + "activityType", reason: "must be a string of 1-64 characters" });
  }
  for (const field of ["start", "end"]) {
    if (!isoTimestamp(raw[field])) {
      errors.push({ field: prefix + field, reason: "must be an ISO 8601 timestamp" });
    }
  }

  const duration = readMetric(raw, "durationMinutes", WORKOUT_RANGES.durationMinutes, errors, prefix);
  if (raw.durationMinutes === undefined || raw.durationMinutes === null) {
    errors.push({ field: prefix + "durationMinutes", reason: "is required" });
  }
  if (errors.length) return null;

  return {
    activityType: activityType as string,
    start: raw.start as string,
    end: raw.end as string,
    durationMinutes: duration ?? 0,
    activeCalories: readMetric(raw, "activeCalories", WORKOUT_RANGES.activeCalories, errors, prefix),
    distanceMeters: readMetric(raw, "distanceMeters", WORKOUT_RANGES.distanceMeters, errors, prefix),
    averageHeartRateBpm: readMetric(raw, "averageHeartRateBpm", WORKOUT_RANGES.averageHeartRateBpm, errors, prefix),
    maxHeartRateBpm: readMetric(raw, "maxHeartRateBpm", WORKOUT_RANGES.maxHeartRateBpm, errors, prefix)
  };
}

export function validateSnapshot(body: unknown): ValidationResult {
  const errors: FieldError[] = [];

  if (!isObject(body)) {
    return { ok: false, errors: [{ field: "body", reason: "must be a JSON object" }] };
  }

  if (!isoTimestamp(body.timestamp)) {
    errors.push({ field: "timestamp", reason: "is required and must be an ISO 8601 timestamp" });
  }

  let testerId: string | null = null;
  if (body.testerId !== undefined && body.testerId !== null) {
    if (typeof body.testerId !== "string" || !TESTER_ID.test(body.testerId)) {
      errors.push({
        field: "testerId",
        reason: "must be 1-64 characters of letters, digits, underscore, dot or hyphen"
      });
    } else {
      testerId = body.testerId;
    }
  }

  const metrics: Record<string, number | null> = {};
  for (const [field, range] of Object.entries(METRIC_RANGES)) {
    metrics[field] = readMetric(body, field, range, errors);
  }

  const workouts: WorkoutSummary[] = [];
  if (body.recentWorkouts !== undefined && body.recentWorkouts !== null) {
    if (!Array.isArray(body.recentWorkouts)) {
      errors.push({ field: "recentWorkouts", reason: "must be an array" });
    } else if (body.recentWorkouts.length > 50) {
      errors.push({ field: "recentWorkouts", reason: "must contain 50 items or fewer" });
    } else {
      body.recentWorkouts.forEach((raw, i) => {
        const workout = validateWorkout(raw, i, errors);
        if (workout) workouts.push(workout);
      });
    }
  }

  if (errors.length) return { ok: false, errors };

  return {
    ok: true,
    snapshot: {
      timestamp: body.timestamp as string,
      testerId,
      heartRateBpm: metrics.heartRateBpm,
      restingHeartRateBpm: metrics.restingHeartRateBpm,
      hrvMs: metrics.hrvMs,
      stepsToday: metrics.stepsToday,
      activeCaloriesToday: metrics.activeCaloriesToday,
      exerciseMinutesToday: metrics.exerciseMinutesToday,
      exerciseGoalMinutes: metrics.exerciseGoalMinutes,
      standHoursToday: metrics.standHoursToday,
      standGoalHours: metrics.standGoalHours,
      recentWorkouts: workouts
    }
  };
}

/** Names of the metrics that actually arrived. Used for logging *which* metrics
 *  came through without writing the values themselves to the log. */
export function presentMetrics(snapshot: HealthSnapshot): string[] {
  return Object.keys(METRIC_RANGES).filter(
    (field) => snapshot[field as keyof HealthSnapshot] !== null
  );
}
