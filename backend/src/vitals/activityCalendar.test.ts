import { describe, expect, it } from "vitest";
import { activityByDay } from "./activityCalendar";
import { HealthSnapshot, StoredSnapshot, WorkoutSummary } from "../types";

function workout(activityType: string, start: string, minutes: number, kcal: number | null = null): WorkoutSummary {
  return {
    activityType,
    start,
    end: start,
    durationMinutes: minutes,
    activeCalories: kcal,
    distanceMeters: null,
    averageHeartRateBpm: null,
    maxHeartRateBpm: null
  };
}

function stored(receivedAt: string, partial: Partial<HealthSnapshot>): StoredSnapshot {
  return {
    receivedAt,
    analysis: {},
    snapshot: {
      timestamp: receivedAt,
      testerId: null,
      heartRateBpm: null,
      restingHeartRateBpm: null,
      hrvMs: null,
      stepsToday: null,
      activeCaloriesToday: null,
      exerciseMinutesToday: null,
      exerciseGoalMinutes: null,
      standHoursToday: null,
      standGoalHours: null,
      recentWorkouts: [],
      ...partial
    }
  };
}

describe("activityByDay", () => {
  it("dedupes workouts repeated across snapshots and buckets by start day", () => {
    const run = workout("Running", "2026-09-10T07:00:00Z", 30.4, 280.6);
    const lift = workout("Traditional Strength Training", "2026-09-11T18:00:00Z", 45, null);
    const days = activityByDay([
      stored("2026-09-10T12:00:00Z", { recentWorkouts: [run] }),
      stored("2026-09-11T20:00:00Z", { recentWorkouts: [run, lift] }),
      stored("2026-09-12T09:00:00Z", { recentWorkouts: [lift, run] })
    ]);

    expect(days.map((d) => d.date)).toEqual(["2026-09-10", "2026-09-11", "2026-09-12"]);
    expect(days[0].workouts).toEqual([run]);
    expect(days[0].workoutMinutes).toBe(30);
    expect(days[0].workoutCalories).toBe(281);
    expect(days[1].workouts).toEqual([lift]);
    expect(days[1].workoutCalories).toBe(0);
    expect(days[2].workouts).toEqual([]);
  });

  it("takes the newest snapshot's day counters and keeps earlier non-null values", () => {
    const days = activityByDay([
      stored("2026-09-10T08:00:00Z", { stepsToday: 1200, exerciseMinutesToday: 5 }),
      stored("2026-09-10T21:00:00Z", { stepsToday: 9800, activeCaloriesToday: 410.4 })
    ]);
    expect(days).toHaveLength(1);
    expect(days[0]).toMatchObject({ steps: 9800, activeCalories: 410, exerciseMinutes: 5 });
  });

  it("sorts a day's workouts oldest first", () => {
    const early = workout("Walking", "2026-09-10T06:00:00Z", 20);
    const late = workout("Cycling", "2026-09-10T19:00:00Z", 40);
    const [day] = activityByDay([stored("2026-09-10T22:00:00Z", { recentWorkouts: [late, early] })]);
    expect(day.workouts.map((w) => w.activityType)).toEqual(["Walking", "Cycling"]);
    expect(day.workoutMinutes).toBe(60);
  });

  it("keys day counters by the reading's timestamp, not the upload time", () => {
    const late = stored("2026-09-11T02:00:00Z", { stepsToday: 4000 });
    late.snapshot.timestamp = "2026-09-10T23:30:00Z";
    const [day] = activityByDay([late]);
    expect(day.date).toBe("2026-09-10");
    expect(day.steps).toBe(4000);
  });

  it("returns nothing for no snapshots", () => {
    expect(activityByDay([])).toEqual([]);
  });
});
