// Integration test for the nutrition mirror + a full-coverage check that every
// hypertable is reachable. Gated on DATABASE_URL.
import { afterAll, describe, expect, it } from "vitest";
import { getPool, closePool } from "../pg";
import { mirrorMealIntake } from "./nutritionRepo";

const RUN = Boolean(process.env.DATABASE_URL);
const suite = RUN ? describe : describe.skip;

suite("nutrition mirror + hypertable coverage (integration)", () => {
  const p = `p_ittest_${Date.now()}_n`;

  afterAll(async () => {
    await getPool().query("delete from app.players where id = $1", [p]);
    await closePool();
  });

  it("records a confirmed meal as an intake leg in nutrition_deltas", async () => {
    await mirrorMealIntake(p, {
      calories: 620, proteinG: 35, carbsG: 60, fatG: 18, sodiumMg: 400,
      foodGroup: "grain", microScore: 0.5,
    });
    const { rows } = await getPool().query(
      "select count(*)::int n, sum(calories)::int cal from telemetry.nutrition_deltas where player_id=$1 and leg='intake'",
      [p]
    );
    expect(rows[0].n).toBe(1);
    expect(rows[0].cal).toBe(620);
  });

  it("all 8 telemetry hypertables exist and are queryable", async () => {
    const expected = [
      "health_samples", "activity_observations", "nutrition_deltas", "battle_events",
      "battle_metrics", "gameplay_events", "body_metrics", "gamble_events",
    ];
    const { rows } = await getPool().query(
      "select hypertable_name from timescaledb_information.hypertables where hypertable_schema='telemetry'"
    );
    const present = new Set(rows.map((r) => r.hypertable_name));
    for (const h of expected) expect(present.has(h)).toBe(true);
  });
});
