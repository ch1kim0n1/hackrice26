// Health activity grouped by calendar day, for the Journey calendar.
//
// Every snapshot the phone uploads carries the watch's last few workouts, so
// the same workout shows up in many snapshots. Dedupe by (type, start) and
// bucket by the calendar day of the workout's start. Day-level figures
// (steps, calories, exercise minutes) are "today" counters on each snapshot,
// so the newest snapshot for a day wins.

import { StoredSnapshot, WorkoutSummary } from "../types";

/** One calendar day of the player's health activity. */
export interface ActivityDay {
  /** YYYY-MM-DD. */
  date: string;
  /** Oldest first. */
  workouts: WorkoutSummary[];
  workoutMinutes: number;
  workoutCalories: number;
  steps: number | null;
  activeCalories: number | null;
  exerciseMinutes: number | null;
}

/** `snapshots` oldest first, as `VitalsStore.recent()` returns them. */
export function activityByDay(snapshots: StoredSnapshot[]): ActivityDay[] {
  const workouts = new Map<string, WorkoutSummary>();
  const days = new Map<string, ActivityDay>();

  const dayFor = (date: string): ActivityDay => {
    let day = days.get(date);
    if (!day) {
      day = {
        date,
        workouts: [],
        workoutMinutes: 0,
        workoutCalories: 0,
        steps: null,
        activeCalories: null,
        exerciseMinutes: null
      };
      days.set(date, day);
    }
    return day;
  };

  for (const s of snapshots) {
    // The reading's own time, not when the server got it: a queued upload
    // must not move yesterday's counters onto today.
    const day = dayFor((s.snapshot.timestamp || s.receivedAt).slice(0, 10));
    // HealthKit reports fractional sums; the client decodes whole numbers.
    if (s.snapshot.stepsToday != null) day.steps = Math.round(s.snapshot.stepsToday);
    if (s.snapshot.activeCaloriesToday != null) day.activeCalories = Math.round(s.snapshot.activeCaloriesToday);
    if (s.snapshot.exerciseMinutesToday != null) day.exerciseMinutes = Math.round(s.snapshot.exerciseMinutesToday);
    for (const w of s.snapshot.recentWorkouts ?? []) {
      workouts.set(`${w.activityType}|${w.start}`, w);
    }
  }

  for (const w of workouts.values()) {
    const day = dayFor(w.start.slice(0, 10));
    day.workouts.push(w);
    day.workoutMinutes += w.durationMinutes;
    day.workoutCalories += w.activeCalories ?? 0;
  }

  return [...days.values()]
    .map((day) => ({
      ...day,
      workouts: [...day.workouts].sort((a, b) => a.start.localeCompare(b.start)),
      workoutMinutes: Math.round(day.workoutMinutes),
      workoutCalories: Math.round(day.workoutCalories)
    }))
    .sort((a, b) => a.date.localeCompare(b.date));
}
