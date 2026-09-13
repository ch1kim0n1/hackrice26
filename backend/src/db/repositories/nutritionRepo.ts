// Nutrition mirror -> telemetry.nutrition_deltas hypertable (signed food legs).
// A confirmed plate is an intake leg; corrections would append reversal/replacement
// legs (see docs/04 §Nutrition — never re-sum). Feeds analytics.nutrition_hourly.
import { randomUUID } from "crypto";
import { withPlayer } from "../pg";
import { ensurePlayer } from "./players";

export interface MealIntakeInput {
  calories?: number | null;
  proteinG?: number | null;
  carbsG?: number | null;
  fatG?: number | null;
  sodiumMg?: number | null;
  foodGroup?: string | null;
  microScore?: number | null;
  consumedAt?: string;
}

/** Record one confirmed meal as a positive intake leg. */
export async function mirrorMealIntake(playerId: string, m: MealIntakeInput): Promise<void> {
  await withPlayer(playerId, async (client) => {
    await ensurePlayer(client, playerId);
    await client.query(
      `insert into telemetry.nutrition_deltas
         (meal_id, meal_revision, item_id, leg, consumed_at, player_id, food_group,
          calories, protein_g, carbs_g, fat_g, sodium_mg, known_value_counts, micronutrient_sum)
       values ($1, 1, $2, 'intake', $3, $4, $5, $6, $7, $8, $9, $10, $11, $12)`,
      [
        randomUUID(), randomUUID(), m.consumedAt ?? new Date().toISOString(), playerId,
        m.foodGroup ?? null, m.calories ?? null, m.proteinG ?? null, m.carbsG ?? null,
        m.fatG ?? null, m.sodiumMg ?? null,
        JSON.stringify({ calories: m.calories != null ? 1 : 0 }),
        JSON.stringify({ micro_score: m.microScore ?? null }),
      ]
    );
  });
}
