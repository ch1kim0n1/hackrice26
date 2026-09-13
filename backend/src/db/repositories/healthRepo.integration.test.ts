// Integration test for the health repository against a real Tiger Cloud / Postgres.
//
// Gated on DATABASE_URL: skipped in normal local/CI runs (so the SQLite suite is
// unaffected), executed when a Postgres connection string is present. Run with:
//   DATABASE_URL="$(TIGER_READ_ONLY=prod tiger db connection-string <id> --with-password)" \
//     npx vitest run healthRepo.integration
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { getPool, closePool } from "../pg";
import { recordHealthSamples, recordBodyMetric, getHourlyHealth, mirrorSnapshot } from "./healthRepo";

const RUN = Boolean(process.env.DATABASE_URL);
const suite = RUN ? describe : describe.skip;

suite("healthRepo (integration)", () => {
  const testPlayer = `p_ittest_${Date.now()}`;

  beforeAll(async () => {
    // health_samples.player_id references app.players; create a throwaway player.
    await getPool().query(
      "insert into app.players(id, display_name) values ($1,$2) on conflict do nothing",
      [testPlayer, "IT Test"]
    );
  });

  afterAll(async () => {
    // ON DELETE CASCADE cleans up samples + body_metrics for this player.
    await getPool().query("delete from app.players where id = $1", [testPlayer]);
    await closePool();
  });

  it("writes health samples and reads them back from the continuous aggregate", async () => {
    const now = Date.now();
    const samples = [0, 1, 2].map((i) => ({
      sourceSystem: "itest",
      sourceSampleId: `hr-${i}`,
      metric: "heart_rate",
      measuredAt: new Date(now - i * 60_000).toISOString(),
      value: 70 + i,
      unit: "bpm",
      quality: "good",
    }));

    const written = await recordHealthSamples(testPlayer, samples);
    expect(written).toBe(3);

    // real-time continuous aggregate reflects the just-written tail
    const hourly = await getHourlyHealth(testPlayer, "heart_rate", 3);
    const total = hourly.reduce((n, p) => n + p.sampleCount, 0);
    expect(total).toBe(3);
    expect(hourly.some((p) => p.valueMax !== null && p.valueMax >= 72)).toBe(true);
  });

  it("is idempotent — re-writing the same samples inserts nothing new", async () => {
    const s = [{
      sourceSystem: "itest",
      sourceSampleId: "hr-dupe",
      metric: "hrv",
      measuredAt: new Date().toISOString(),
      value: 55,
      unit: "ms",
    }];
    expect(await recordHealthSamples(testPlayer, s)).toBe(1);
    expect(await recordHealthSamples(testPlayer, s)).toBe(0);
  });

  it("records a body-metric weigh-in into the hypertable", async () => {
    await recordBodyMetric(testPlayer, { loggedAt: new Date().toISOString(), weightKg: 70.5, bodyFatPct: 18.0, source: "manual" });
    const { rows } = await getPool().query(
      "select count(*)::int n from telemetry.body_metrics where player_id = $1",
      [testPlayer]
    );
    expect(rows[0].n).toBe(1);
  });

  it("mirrors a HealthKit snapshot into hypertables + workouts", async () => {
    const now = new Date().toISOString();
    const res = await mirrorSnapshot(testPlayer, {
      timestamp: now,
      testerId: "it",
      heartRateBpm: 78,
      restingHeartRateBpm: 52,
      hrvMs: 60,
      stepsToday: 4200,
      activeCaloriesToday: 260,
      exerciseMinutesToday: 22,
      exerciseGoalMinutes: 30,
      standHoursToday: 8,
      standGoalHours: 12,
      recentWorkouts: [{
        activityType: "Run", start: now, end: now,
        durationMinutes: 30, activeCalories: 300,
        distanceMeters: 5000, averageHeartRateBpm: 150, maxHeartRateBpm: 175,
      }],
    });
    expect(res.samples).toBe(3);      // hr, resting hr, hrv
    expect(res.activity).toBe(4);     // steps, energy, exercise, stand
    expect(res.workouts).toBe(1);
  });
});
