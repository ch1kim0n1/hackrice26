// Dish photo analysis — shared types.
//
// The analysis engine (see analyze.ts) is deliberately independent of the
// game: it takes a photo and produces nutrition data a person would trust.
// Nothing in here knows about characters, stats or rarity — that mapping
// happens downstream once the numbers are confirmed.

/** Canonical food groups — mirrors BattleKit `FoodGroup` and the Postgres
 *  `food_group` column on app.products (backend/migrations/0002). */
export const FOOD_GROUPS = ["produce", "grain", "dairy", "protein", "other"] as const;
export type FoodGroup = (typeof FOOD_GROUPS)[number];

/** The six micronutrients the game scores on. Matches `compute_micro_score()`
 *  in backend/migrations/0002 so photo dishes and barcode products are
 *  measured on the same scale. */
export const MICRONUTRIENTS = [
  "vitamin-a",
  "vitamin-c",
  "vitamin-b12",
  "iron",
  "calcium",
  "potassium"
] as const;
export type Micronutrient = (typeof MICRONUTRIENTS)[number];

/** One distinct food identified on the plate, with its own estimated portion.
 *  Nutrient figures are absolute for `portionG` grams of that item (not
 *  per-100g) — the whole point is that a plate is several different things. */
export interface DishItem {
  /** Stable index-based id so the client can reference an item when editing. */
  id: string;
  name: string;
  /** Estimated grams of this item on the plate. */
  portionG: number;
  /** Human-readable portion, e.g. "1 breast (~120 g)". */
  portionLabel: string;
  calories: number;
  proteinG: number;
  carbsG: number;
  fatG: number;
  fiberG: number;
  sugarG: number;
  sodiumMg: number;
  micronutrients: Micronutrient[];
  foodGroup: FoodGroup;
  /** Model's self-reported confidence for this item, 0..1. */
  confidence: number;
}

/** Plate-level sums. Always recomputed from items — never taken from the
 *  model or the client. */
export interface DishTotals {
  portionG: number;
  calories: number;
  proteinG: number;
  carbsG: number;
  fatG: number;
  fiberG: number;
  sugarG: number;
  sodiumMg: number;
  /** Union of micronutrients across all items. */
  micronutrients: Micronutrient[];
  /** Share of the six tracked micronutrients present, 0..1. */
  microScore: number;
  /** Distinct food groups on the plate (diversity signal). */
  foodGroups: FoodGroup[];
  /** The group contributing the most calories — drives character art. */
  dominantFoodGroup: FoodGroup;
}

/** A complete draft analysis, before the user has confirmed it. */
export interface DishAnalysis {
  analysisId: string;
  dishName: string;
  /** Dominant plate color, used as the character's accent. */
  colorHex: string;
  /** NOVA processing level 1-4 (4 = ultra-processed). */
  nova: number;
  items: DishItem[];
  totals: DishTotals;
  /** Mean item confidence, 0..1. */
  confidence: number;
  /** True when the estimate is shaky enough that the user should look closely. */
  lowConfidence: boolean;
}

/** Thrown when the photo doesn't contain food, or the model's reply is
 *  unusable. Callers map this to a 422. */
export class NotFoodError extends Error {
  constructor(message = "No food could be recognized in that photo") {
    super(message);
    this.name = "NotFoodError";
  }
}

/**
 * Thrown when the vision provider itself is unreachable, rate-limited or
 * refusing us (quota, auth, deprecation). Distinct from NotFoodError on
 * purpose: "we couldn't call the analyser" must never be reported to the user
 * as "there's no food in your photo". Callers map this to a 503.
 */
export class VisionUnavailableError extends Error {
  constructor(message = "The photo analyser is unavailable right now", readonly status?: number) {
    super(message);
    this.name = "VisionUnavailableError";
  }
}
