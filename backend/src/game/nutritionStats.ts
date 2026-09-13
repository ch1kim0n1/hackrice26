// Nutrition -> battle-stat mapping (#104). Deterministic, pure.
//
// The canonical four-stat formula lives in baseStats.ts and is a direct
// port of Postgres `compute_base_stats()` + BattleKit — that parity is
// load-bearing, so this module layers on top instead of forking it:
//
//   power/guard/vitality : unchanged canonical formula
//   tempo                : canonical formula + bounded calorie-density
//                          overlay (documented in docs/NUTRITION-STATS.md)
//
// Calorie density (kcal per gram) is the extra signal the scan pipeline
// has that the canonical macro-only formula never used: energy-dense food
// burns fast and fades — in game terms, low staying power -> lower tempo.
// Light, bulky food keeps you going -> higher tempo.

import {
  BaseStats,
  Element,
  computeBaseStats,
  elementFromStats
} from "./baseStats";
import { MICRONUTRIENTS, Micronutrient } from "../nutrition/types";

export interface NutritionInput {
  proteinG: number;
  fiberG: number;
  sugarG: number;
  /** 0..1 share of the six tracked micronutrients. If omitted, derived
   *  from `micronutrients`. */
  microScore?: number;
  micronutrients?: Micronutrient[];
  /** Portion energy, kcal. Needs portionG to compute density. */
  calories?: number;
  /** Portion size in grams. Needs calories to compute density. */
  portionG?: number;
}

export type DensityBand = "light" | "balanced" | "dense";

export interface NutritionStatMap {
  stats: BaseStats;
  element: Element;
  /** Resolved 0..1 micro score actually used in vitality. */
  microScore: number;
  /** kcal per gram. Null when calories or portionG were not supplied. */
  calorieDensity: number | null;
  densityBand: DensityBand | null;
  /** The bounded density contribution applied to tempo (see docs). */
  tempoShift: number;
}

// Density bands in kcal/g. Anchors: leafy produce ~0.3, cooked rice ~1.3,
// bread ~2.6, cheeseburger ~2.9, chocolate ~5.5, olive oil ~8.8.
const DENSITY_LIGHT_MAX = 1.5;
const DENSITY_BALANCED_MAX = 3.5;

// Overlay tuning: density 2.0 kcal/g is neutral; every kcal/g below adds
// tempo, every kcal/g above subtracts it, capped at ±12 so macros still
// dominate the stat.
const DENSITY_NEUTRAL = 2.0;
const DENSITY_TEMPO_SLOPE = 6;
const TEMPO_SHIFT_CAP = 12;

export function calorieDensityOf(calories?: number, portionG?: number): number | null {
  if (!Number.isFinite(calories) || !Number.isFinite(portionG) || !portionG || portionG! <= 0) {
    return null;
  }
  return calories! / portionG!;
}

export function densityBandFor(density: number | null): DensityBand | null {
  if (density === null) return null;
  if (density < DENSITY_LIGHT_MAX) return "light";
  if (density < DENSITY_BALANCED_MAX) return "balanced";
  return "dense";
}

/** Bounded tempo contribution from calorie density. 0 when unknown. */
export function densityTempoShift(density: number | null): number {
  if (density === null) return 0;
  const raw = (DENSITY_NEUTRAL - density) * DENSITY_TEMPO_SLOPE;
  return Math.max(-TEMPO_SHIFT_CAP, Math.min(TEMPO_SHIFT_CAP, raw));
}

function resolveMicroScore(input: NutritionInput): number {
  if (Number.isFinite(input.microScore)) {
    return Math.max(0, Math.min(1, input.microScore!));
  }
  const present = new Set(input.micronutrients ?? []);
  const count = MICRONUTRIENTS.filter((m) => present.has(m)).length;
  return Math.round((count / MICRONUTRIENTS.length) * 1e4) / 1e4;
}

const clampStat = (v: number) => Math.max(10, Math.min(100, Math.round(v)));

/**
 * Map a portion's nutrition to its stat block.
 *
 *   power    = 20 + protein_g * 4
 *   guard    = 20 + fiber_g   * 5
 *   vitality = 20 + microScore * 45
 *   tempo    = 20 + (protein_g / max(sugar_g,1)) * 10
 *              + (50 - sugar_g) * 0.6
 *              + densityTempoShift(calories / portionG)
 *
 * All stats clamped to 10..100. Pure: same input, same output, always.
 */
export function mapNutrition(input: NutritionInput): NutritionStatMap {
  const microScore = resolveMicroScore(input);
  const density = calorieDensityOf(input.calories, input.portionG);
  const tempoShift = densityTempoShift(density);

  const canonical = computeBaseStats({
    proteinG: input.proteinG,
    fiberG: input.fiberG,
    sugarG: input.sugarG,
    microScore
  });

  const stats: BaseStats = { ...canonical, tempo: clampStat(canonical.tempo + tempoShift) };

  return {
    stats,
    element: elementFromStats(stats),
    microScore,
    calorieDensity: density,
    densityBand: densityBandFor(density),
    tempoShift
  };
}
