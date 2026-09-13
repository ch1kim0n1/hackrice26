// ============================================================================
// §1 Scan pipeline math — NutritionScore, rarity roll, combat profiles.
//
// Pure + deterministic (docs/CONVENTIONS.md): no Date, no Math.random — every
// stochastic roll takes a unit in [0,1) supplied by the caller, so the mint
// path can pass a seeded/commit-reveal roll and tests can hit exact edges.
//
// NutritionScore is a *holistic* quality score — no permanent
// macro-to-stat mapping. It feeds one thing: the rarity roll's tilt. Combat
// stats come from the separate AttackProfile/HealthProfile calc, and rarity
// never substitutes for them.
// ============================================================================

import { Rarity } from "../types";
import {
  NUTRITION_WEIGHTS,
  SCAN_BASE_ODDS,
  SCAN_RARITY_TILT,
  SPEC_RARITY_ORDER,
  RARITY_INDEX,
  ATTACK_PROFILE_WEIGHTS,
  HEALTH_PROFILE_WEIGHTS
} from "./spec";

/** Per-100g / per-100mL nutrition as reported by the data source (OFF for
 *  barcodes). All fields optional — the spec requires missing fields to
 *  redistribute their weight rather than score as zero. */
export interface NutritionInput {
  calories?: number;
  proteinG?: number;
  carbsG?: number;
  fatG?: number;
  fiberG?: number;
  sugarG?: number;
  sodiumMg?: number;
  satFatG?: number;
}

const clamp01 = (v: number) => Math.min(1, Math.max(0, v));

// ---------------------------------------------------------------------------
// NutritionScore (doc §1)
//
//   ProteinScore = clamp(protein_g/25, 0, 1) * 100          weight .25
//   FiberScore   = clamp(fiber_g/10, 0, 1) * 100            weight .20
//   SugarScore   = (1 - clamp(sugar_g/20, 0, 1)) * 100      weight .25
//   SodiumScore  = (1 - clamp((sodium_mg-50)/950, 0, 1))*100 weight .15
//   SatFatScore  = (1 - clamp((satFat_g-0.5)/9.5, 0, 1))*100 weight .15
//
// A missing field's weight redistributes proportionally across the components
// that are present. With no fields at all the score is neutral (50) — the
// rarity roll then lands exactly on the baseline odds.
// ---------------------------------------------------------------------------

export interface NutritionComponents {
  protein?: number;
  fiber?: number;
  sugar?: number;
  sodium?: number;
  satFat?: number;
}

/** The per-component sub-scores (0..100) that were actually computable. */
export function nutritionComponents(n: NutritionInput): NutritionComponents {
  const components: NutritionComponents = {};
  if (n.proteinG !== undefined) components.protein = clamp01(n.proteinG / 25) * 100;
  if (n.fiberG !== undefined) components.fiber = clamp01(n.fiberG / 10) * 100;
  if (n.sugarG !== undefined) components.sugar = (1 - clamp01(n.sugarG / 20)) * 100;
  if (n.sodiumMg !== undefined) components.sodium = (1 - clamp01((n.sodiumMg - 50) / 950)) * 100;
  if (n.satFatG !== undefined) components.satFat = (1 - clamp01((n.satFatG - 0.5) / 9.5)) * 100;
  return components;
}

/** Neutral score when nothing about the product is known. */
export const NEUTRAL_NUTRITION_SCORE = 50;

/** Holistic 0..100 quality score. Missing fields redistribute weight. */
export function nutritionScore(n: NutritionInput): number {
  const components = nutritionComponents(n);
  let weighted = 0;
  let weight = 0;
  for (const key of Object.keys(NUTRITION_WEIGHTS) as (keyof typeof NUTRITION_WEIGHTS)[]) {
    const value = components[key];
    if (value === undefined) continue;
    weighted += value * NUTRITION_WEIGHTS[key];
    weight += NUTRITION_WEIGHTS[key];
  }
  if (weight === 0) return NEUTRAL_NUTRITION_SCORE;
  return weighted / weight;
}

// ---------------------------------------------------------------------------
// Rarity roll (doc §1)
//
//   rawWeight(r) = baseOdds(r) x exp(TILT x ((score-50)/50) x idx(r))
//
// normalised over the seven tiers. At score 50 the exponent is 0, so the
// distribution is exactly the baseline 80/16/3.2/0.64/0.128/0.0256/0.0064.
// ---------------------------------------------------------------------------

/** Normalised rarity probabilities for a given NutritionScore. */
export function rarityWeights(score: number): Record<Rarity, number> {
  const tilt = ((score - 50) / 50) * SCAN_RARITY_TILT;
  const raw = SPEC_RARITY_ORDER.map(
    (r) => SCAN_BASE_ODDS[r] * Math.exp(tilt * RARITY_INDEX[r])
  );
  const total = raw.reduce((a, b) => a + b, 0);
  return Object.fromEntries(
    SPEC_RARITY_ORDER.map((r, i) => [r, raw[i] / total])
  ) as Record<Rarity, number>;
}

/** Deterministic rarity pick: `unit` is a uniform roll in [0,1). */
export function rollRarity(score: number, unit: number): Rarity {
  const weights = rarityWeights(score);
  const u = Math.min(Math.max(unit, 0), 1 - Number.EPSILON);
  let cumulative = 0;
  for (const rarity of SPEC_RARITY_ORDER) {
    cumulative += weights[rarity];
    if (u < cumulative) return rarity;
  }
  return "secret";
}

// ---------------------------------------------------------------------------
// Combat profiles (doc §1) — a separate calculation from the rarity roll.
//
//   AttackProfile = .40*protein + .25*carbEnergy + .20*calDensity + .15*fatEnergy
//   HealthProfile = .25*fiber + .20*protein + .20*sugarQuality
//                 + .20*sodiumQuality + .15*satFatQuality
//
// Components are normalised per 100g so a generated monster lands inside the
// same stat envelope the catalog authors (Health 60-160, Attack 30-85 —
// inside the roster's 40-200 / 20-100 design space). Missing fields
// redistribute their weight, exactly like NutritionScore.
// ---------------------------------------------------------------------------

interface ProfileInput {
  protein?: number;
  carbEnergy?: number;
  calorieDensity?: number;
  fatEnergy?: number;
  fiber?: number;
  sugarQuality?: number;
  sodiumQuality?: number;
  satFatQuality?: number;
}

function profileComponents(n: NutritionInput): ProfileInput {
  const c: ProfileInput = {};
  if (n.proteinG !== undefined) c.protein = clamp01(n.proteinG / 25);
  if (n.carbsG !== undefined) c.carbEnergy = clamp01((n.carbsG * 4) / 200);
  if (n.calories !== undefined) c.calorieDensity = clamp01(n.calories / 450);
  if (n.fatG !== undefined) c.fatEnergy = clamp01((n.fatG * 9) / 225);
  if (n.fiberG !== undefined) c.fiber = clamp01(n.fiberG / 10);
  if (n.sugarG !== undefined) c.sugarQuality = 1 - clamp01(n.sugarG / 20);
  if (n.sodiumMg !== undefined) c.sodiumQuality = 1 - clamp01((n.sodiumMg - 50) / 950);
  if (n.satFatG !== undefined) c.satFatQuality = 1 - clamp01((n.satFatG - 0.5) / 9.5);
  return c;
}

function weighted(
  components: ProfileInput,
  weights: Partial<Record<keyof ProfileInput, number>>
): number | undefined {
  let acc = 0;
  let total = 0;
  for (const key of Object.keys(weights) as (keyof ProfileInput)[]) {
    const value = components[key];
    const w = weights[key];
    if (value === undefined || w === undefined) continue;
    acc += value * w;
    total += w;
  }
  return total === 0 ? undefined : acc / total;
}

/** 0..1 — how hard this food hits. Independent of rarity. */
export function attackProfile(n: NutritionInput): number | undefined {
  return weighted(profileComponents(n), ATTACK_PROFILE_WEIGHTS);
}

/** 0..1 — how well this food holds up. Independent of rarity. */
export function healthProfile(n: NutritionInput): number | undefined {
  return weighted(profileComponents(n), HEALTH_PROFILE_WEIGHTS);
}

/** Generated base combat stats for a barcode mint, on the catalog's scale. */
export function combatBase(n: NutritionInput): { baseHealth: number; baseAttack: number } {
  // Neutral 0.5 when a whole profile is unknowable — a snack with no protein
  // data should not mint a glass cannon by accident.
  const attack = attackProfile(n) ?? 0.5;
  const health = healthProfile(n) ?? 0.5;
  return {
    baseHealth: 60 + Math.round(health * 100), // 60..160
    baseAttack: 30 + Math.round(attack * 55)   // 30..85
  };
}

// ---------------------------------------------------------------------------
// Plausibility gate (anti-cheat, spec checklist). Values are per-100g; the
// source is server-fetched, so these bounds catch corrupt feeds, tampered
// caches and outright impossible products before anything mints from them.
// ---------------------------------------------------------------------------

const FIELD_BOUNDS: Record<keyof NutritionInput, [number, number]> = {
  calories: [0, 900],      // pure fat is ~900 kcal/100g
  proteinG: [0, 100],
  carbsG: [0, 100],
  fatG: [0, 100],
  fiberG: [0, 100],
  sugarG: [0, 100],
  sodiumMg: [0, 50_000],
  satFatG: [0, 100]
};

export interface Plausibility {
  plausible: boolean;
  reasons: string[];
}

export function checkPlausibility(n: NutritionInput): Plausibility {
  const reasons: string[] = [];
  for (const [key, [lo, hi]] of Object.entries(FIELD_BOUNDS) as [keyof NutritionInput, [number, number]][]) {
    const value = n[key];
    if (value === undefined) continue;
    if (!Number.isFinite(value) || value < lo || value > hi) {
      reasons.push(`${key}=${value} outside plausible range ${lo}..${hi} per 100g`);
    }
  }
  // Macro mass can't exceed the food itself (small slack for label noise).
  const macroGrams = (n.proteinG ?? 0) + (n.carbsG ?? 0) + (n.fatG ?? 0) + (n.fiberG ?? 0);
  if (macroGrams > 110) {
    reasons.push(`macros sum to ${macroGrams}g per 100g`);
  }
  // Saturated fat is a subset of fat.
  if (n.satFatG !== undefined && n.fatG !== undefined && n.satFatG > n.fatG + 1) {
    reasons.push(`satFat ${n.satFatG}g exceeds total fat ${n.fatG}g`);
  }
  // Energy cross-check: implied macro calories must roughly agree with the
  // stated energy when both are present (Atwater factors, wide tolerance for
  // fibre/polyol labelling conventions).
  if (n.calories !== undefined) {
    const implied = 4 * (n.proteinG ?? 0) + 4 * (n.carbsG ?? 0) + 9 * (n.fatG ?? 0) + 2 * (n.fiberG ?? 0);
    if (implied > 0 && (n.calories > implied * 2 || n.calories < implied * 0.4)) {
      reasons.push(`stated ${n.calories} kcal vs ${Math.round(implied)} kcal implied by macros`);
    }
  }
  return { plausible: reasons.length === 0, reasons };
}
