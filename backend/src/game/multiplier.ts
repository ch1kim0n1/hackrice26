// Daily Party Multiplier — byte-for-byte port of BattleKit
// `DailyMultiplierCalculator` (battle-system branch, DailyMultiplier.swift §3)
// and the DB `recalc_multiplier()` function. Clamp [0.80, 1.50].

import { PersonalTargets } from "./targets";

export type FoodGroup = "produce" | "grain" | "dairy" | "protein" | "other";

export interface DayLogEntry {
  barcode: string;
  calories: number;
  protein: number;
  fiber: number;
  sugar: number;
  microScore: number; // 0..1
  foodGroup: FoodGroup;
  loggedAt: number; // epoch ms
}

export interface MultiplierBreakdown {
  protein: number;
  fiber: number;
  micronutrients: number;
  diversity: number;
  calorie: number;
  sugarPenalty: number; // includes nutrient-poor penalty
  total: number;
}

export interface MultiplierResult extends MultiplierBreakdown {
  objectives: { protein: boolean; fiber: boolean; diversity: boolean; calories: boolean };
}

export const NEUTRAL: MultiplierBreakdown = {
  protein: 0,
  fiber: 0,
  micronutrients: 0,
  diversity: 0,
  calorie: 0,
  sugarPenalty: 0,
  total: 1.0
};

/**
 * Applies the anti-gaming filter (one barcode/day, max 3 items/hour toward the
 * log) exactly as the Swift calculator does, then computes the breakdown.
 */
export function calculateMultiplier(entries: DayLogEntry[], targets: PersonalTargets): MultiplierResult {
  const sorted = [...entries].sort((a, b) => a.loggedAt - b.loggedAt);
  const seen = new Set<string>();
  let hourWindow: number[] = [];
  const filtered: DayLogEntry[] = [];

  for (const entry of sorted) {
    if (seen.has(entry.barcode)) continue; // one barcode/day, even if hour-capped
    seen.add(entry.barcode);
    hourWindow = hourWindow.filter((t) => entry.loggedAt - t < 3600 * 1000);
    if (hourWindow.length >= 3) continue;
    hourWindow.push(entry.loggedAt);
    filtered.push(entry);
  }

  if (filtered.length === 0) {
    return { ...NEUTRAL, objectives: { protein: false, fiber: false, diversity: false, calories: false } };
  }

  const calories = filtered.reduce((s, e) => s + e.calories, 0);
  const protein = filtered.reduce((s, e) => s + e.protein, 0);
  const fiber = filtered.reduce((s, e) => s + e.fiber, 0);
  const sugar = filtered.reduce((s, e) => s + e.sugar, 0);
  const microAvg = filtered.reduce((s, e) => s + e.microScore, 0) / filtered.length;
  const groups = new Set(filtered.map((e) => e.foodGroup)).size;

  const pRatio = protein / Math.max(targets.proteinTarget, 1);
  const proteinBonus = pRatio >= 0.8 ? Math.min((pRatio - 0.8) / 0.5, 1) * 0.12 : 0;

  const fiberBonus = Math.min(fiber / Math.max(targets.fiberTarget, 1), 1) * 0.12;

  const diversityBonus = Math.min(groups, 3) * 0.04;

  const microBonus = Math.min(microAvg / 0.5, 1) * 0.12;

  const calDelta = Math.abs(calories - targets.calorieTarget) / Math.max(targets.calorieTarget, 1);
  const calorieBase = calDelta <= 0.1 ? 0.2 : calDelta <= 0.2 ? 0.1 : 0;
  const calorieBonus = calorieBase * Math.min(microAvg / 0.4, 1);

  const sugarPenalty = sugar > 75 ? -0.15 : sugar > 50 ? -0.08 : 0;
  const poorNutritionPenalty = microAvg < 0.2 ? -0.1 : 0;

  const total = Math.min(
    1.5,
    Math.max(
      0.8,
      1.0 + proteinBonus + fiberBonus + diversityBonus + microBonus + calorieBonus + sugarPenalty + poorNutritionPenalty
    )
  );

  return {
    protein: proteinBonus,
    fiber: fiberBonus,
    micronutrients: microBonus,
    diversity: diversityBonus,
    calorie: calorieBonus,
    sugarPenalty: sugarPenalty + poorNutritionPenalty,
    total,
    objectives: {
      protein: pRatio >= 0.8,
      fiber: fiber >= 25,
      diversity: groups >= 3,
      calories: calDelta <= 0.2
    }
  };
}
