// Plate math: portion scaling, totals, micro score, per-100g conversion.
//
// Pure functions, no I/O — this is the part of the analysis engine that must
// be provably correct, because the numbers it produces become both the user's
// nutrition log and the character's stats.

import {
  DishItem,
  DishTotals,
  FoodGroup,
  FOOD_GROUPS,
  Micronutrient,
  MICRONUTRIENTS
} from "./types";

const round1 = (v: number) => Math.round(v * 10) / 10;

/** kcal implied by the macros (Atwater factors). */
export function caloriesFromMacros(proteinG: number, carbsG: number, fatG: number): number {
  return proteinG * 4 + carbsG * 4 + fatG * 9;
}

/**
 * Rescale an item to a new portion size, holding its nutrient *density*
 * constant. This is the only way item nutrition ever changes after analysis:
 * the client may re-portion, rename or drop an item, but it can never hand us
 * arbitrary macros (which would be a trivial way to mint a maxed character).
 */
export function scaleItem(item: DishItem, newPortionG: number): DishItem {
  const from = Math.max(item.portionG, 0.001);
  const factor = Math.max(newPortionG, 0) / from;
  return {
    ...item,
    portionG: round1(newPortionG),
    calories: round1(item.calories * factor),
    proteinG: round1(item.proteinG * factor),
    carbsG: round1(item.carbsG * factor),
    fatG: round1(item.fatG * factor),
    fiberG: round1(item.fiberG * factor),
    sugarG: round1(item.sugarG * factor),
    sodiumMg: round1(item.sodiumMg * factor)
  };
}

/** Share of the six tracked micronutrients present, 0..1. */
export function microScoreFor(micronutrients: Micronutrient[]): number {
  const present = new Set(micronutrients.filter((m) => MICRONUTRIENTS.includes(m)));
  return round1000(present.size / MICRONUTRIENTS.length);
}

const round1000 = (v: number) => Math.round(v * 1000) / 1000;

/** The food group contributing the most calories; ties break by plate order.
 *  Falls back to the heaviest group when a plate somehow has zero calories. */
export function dominantFoodGroup(items: DishItem[]): FoodGroup {
  if (items.length === 0) return "other";
  const byCalories = new Map<FoodGroup, number>();
  const byMass = new Map<FoodGroup, number>();
  for (const item of items) {
    byCalories.set(item.foodGroup, (byCalories.get(item.foodGroup) ?? 0) + item.calories);
    byMass.set(item.foodGroup, (byMass.get(item.foodGroup) ?? 0) + item.portionG);
  }
  const pick = (m: Map<FoodGroup, number>): FoodGroup | null => {
    let best: FoodGroup | null = null;
    let bestValue = 0;
    // Iterate in canonical order so ties are deterministic.
    for (const group of FOOD_GROUPS) {
      const value = m.get(group) ?? 0;
      if (value > bestValue) {
        bestValue = value;
        best = group;
      }
    }
    return best;
  };
  return pick(byCalories) ?? pick(byMass) ?? items[0].foodGroup;
}

/** Sum items into plate totals. Always derived — never trusted from input. */
export function computeTotals(items: DishItem[]): DishTotals {
  const sum = (pick: (i: DishItem) => number) => round1(items.reduce((acc, i) => acc + pick(i), 0));

  const micronutrients = [...new Set(items.flatMap((i) => i.micronutrients))].filter((m) =>
    MICRONUTRIENTS.includes(m)
  );
  const foodGroups = [...new Set(items.map((i) => i.foodGroup))];

  return {
    portionG: sum((i) => i.portionG),
    calories: sum((i) => i.calories),
    proteinG: sum((i) => i.proteinG),
    carbsG: sum((i) => i.carbsG),
    fatG: sum((i) => i.fatG),
    fiberG: sum((i) => i.fiberG),
    sugarG: sum((i) => i.sugarG),
    sodiumMg: sum((i) => i.sodiumMg),
    micronutrients,
    microScore: microScoreFor(micronutrients),
    foodGroups,
    dominantFoodGroup: dominantFoodGroup(items)
  };
}

/**
 * Convert plate totals to per-100g figures — the shape the existing barcode
 * stat pipeline expects (Open Food Facts is all per-100g).
 *
 * The old one-shot photo route faked this by dividing by 5 ("assume a 500 g
 * plate"). Now that the analysis estimates a real portion weight per item, the
 * conversion is honest. Guards against a zero/absurd portion producing
 * division blow-ups.
 */
export function per100g(totals: DishTotals): {
  proteins_100g: number;
  fiber_100g: number;
  sugars_100g: number;
  carbohydrates_100g: number;
  fat_100g: number;
  "energy-kcal_100g": number;
} {
  const grams = totals.portionG > 0 ? totals.portionG : 100;
  const factor = 100 / grams;
  return {
    proteins_100g: round1(totals.proteinG * factor),
    fiber_100g: round1(totals.fiberG * factor),
    sugars_100g: round1(totals.sugarG * factor),
    carbohydrates_100g: round1(totals.carbsG * factor),
    fat_100g: round1(totals.fatG * factor),
    "energy-kcal_100g": round1(totals.calories * factor)
  };
}
