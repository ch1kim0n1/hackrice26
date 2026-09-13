// Processing layer.
//
// This is the seam where the project's real logic goes -- awarding crate keys
// for closed rings, feeding battle stats, whatever the game needs. For now it
// derives descriptive readouts from whatever metrics arrived, so the pipeline
// returns something visible on the phone.
//
// These are descriptive statistics about numbers the device reported. They are
// not a diagnosis and not medical advice.

import { HealthSnapshot } from "../types";

const STEP_GOAL = 10_000;
const DEFAULT_EXERCISE_GOAL_MINUTES = 30;
const DEFAULT_STAND_GOAL_HOURS = 12;

const METRIC_FIELDS = [
  "heartRateBpm",
  "restingHeartRateBpm",
  "hrvMs",
  "stepsToday",
  "activeCaloriesToday",
  "exerciseMinutesToday",
  "standHoursToday"
] as const;

const round = (n: number) => Math.round(n);
const group = (n: number) => Math.round(n).toLocaleString("en-US");

/** Very rough bucketing of an SDNN reading, for demo output only. */
function hrvBand(hrvMs: number): string {
  if (hrvMs < 20) return "low";
  if (hrvMs < 50) return "moderate";
  return "high";
}

function heartRateNote(heartRate: number | null, resting: number | null): string | null {
  if (heartRate === null || resting === null) return null;
  const delta = heartRate - resting;
  const signed = `${delta >= 0 ? "+" : ""}${round(delta)}`;
  if (delta <= 5) return `at rest (${signed} BPM vs resting)`;
  if (delta <= 30) return `mildly elevated (${signed} BPM vs resting)`;
  return `elevated (${signed} BPM vs resting)`;
}

/**
 * Turn one snapshot into human-readable strings.
 *
 * Missing metrics are skipped rather than defaulted, so a partial snapshot still
 * produces whatever analysis is possible.
 */
export function analyze(snapshot: HealthSnapshot): Record<string, string> {
  const result: Record<string, string> = {};

  const note = heartRateNote(snapshot.heartRateBpm, snapshot.restingHeartRateBpm);
  if (note) {
    result.heartRate = note;
  } else if (snapshot.heartRateBpm !== null) {
    result.heartRate = `${round(snapshot.heartRateBpm)} BPM (no resting baseline yet)`;
  }

  if (snapshot.hrvMs !== null) {
    result.hrv = `${round(snapshot.hrvMs)} ms (${hrvBand(snapshot.hrvMs)} for this sample)`;
  }

  if (snapshot.stepsToday !== null) {
    const pct = Math.min(100, Math.round((snapshot.stepsToday / STEP_GOAL) * 100));
    result.steps = `${group(snapshot.stepsToday)} steps (${pct}% of a ${group(STEP_GOAL)} goal)`;
  }

  if (snapshot.activeCaloriesToday !== null) {
    result.activeEnergy = `${group(snapshot.activeCaloriesToday)} kcal burned today`;
  }

  if (snapshot.exerciseMinutesToday !== null) {
    const goal = snapshot.exerciseGoalMinutes || DEFAULT_EXERCISE_GOAL_MINUTES;
    const pct = Math.min(100, Math.round((snapshot.exerciseMinutesToday / goal) * 100));
    result.exercise = `${round(snapshot.exerciseMinutesToday)} of ${round(goal)} exercise minutes (${pct}%)`;
  }

  if (snapshot.standHoursToday !== null) {
    const goal = snapshot.standGoalHours || DEFAULT_STAND_GOAL_HOURS;
    const pct = Math.min(100, Math.round((snapshot.standHoursToday / goal) * 100));
    result.stand = `${round(snapshot.standHoursToday)} of ${round(goal)} stand hours (${pct}%)`;
  }

  if (snapshot.recentWorkouts.length) {
    const latest = snapshot.recentWorkouts[0];
    const total = snapshot.recentWorkouts.reduce((sum, w) => sum + w.durationMinutes, 0);
    const detail = [`${round(latest.durationMinutes)} min`];
    if (latest.distanceMeters) detail.push(`${(latest.distanceMeters / 1000).toFixed(2)} km`);
    if (latest.averageHeartRateBpm) detail.push(`avg ${round(latest.averageHeartRateBpm)} BPM`);
    result.lastWorkout = `${latest.activityType} - ${detail.join(" / ")}`;
    result.workoutLoad =
      `${snapshot.recentWorkouts.length} workout(s), ${round(total)} min total in the lookback window`;
  }

  const missing = METRIC_FIELDS.filter((f) => snapshot[f] === null);
  if (missing.length) result.unavailableMetrics = missing.join(", ");
  if (missing.length === METRIC_FIELDS.length && !snapshot.recentWorkouts.length) {
    result.status = "No metrics were available in this snapshot.";
  }

  result.disclaimer = "Experimental hackathon output. Not medical advice.";
  return result;
}
