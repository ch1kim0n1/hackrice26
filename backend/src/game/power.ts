// Combat power curve — rarity × mastery (issues #112, #131).
//
// The worth side of this was decided in rarityBands.ts (stars add value, and
// a 5-star monster prices like a 2-star of the next rarity up). Combat uses
// the multiplicative form of the same idea:
//
//     effectiveStat = baseStat × rarityMult × starMult(star)
//
// starMult is 1 + STAR_STEP × (star − 1), so one star is worth less than one
// rarity step everywhere except the common→uncommon edge (1.06), which the
// star economy deliberately lets a fully-mastered Common approach: a ★5
// Common lands at ×1.32, between an Uncommon ★1 (×1.06) and a Rare ★1
// (×1.12) — mastery narrows the gap without ever reaching the next band's
// ceiling. Exactly the "rarity vs mastery" answer from the spec.

import { RARITY_TIERS } from "../data/lootTable";
import { Rarity } from "../types";
import { StarLevel } from "./rarityBands";

/** Per-star combat multiplier step. */
export const STAR_STEP = 0.08;

export function starMult(star: number): number {
  const s = Math.min(Math.max(Math.trunc(star), 1), 5);
  return 1 + STAR_STEP * (s - 1);
}

export function rarityMult(rarity: Rarity): number {
  return RARITY_TIERS[rarity].statMultiplier;
}

export interface BaseStats {
  power: number;
  guard: number;
  vitality: number;
  tempo: number;
}

/** One stat after rarity and star scaling. */
export function scaledStat(base: number, rarity: Rarity, star: number): number {
  return base * rarityMult(rarity) * starMult(star);
}

/** The whole stat line scaled. */
export function scaledStats(stats: BaseStats, rarity: Rarity, star: number): BaseStats {
  return {
    power: scaledStat(stats.power, rarity, star),
    guard: scaledStat(stats.guard, rarity, star),
    vitality: scaledStat(stats.vitality, rarity, star),
    tempo: scaledStat(stats.tempo, rarity, star)
  };
}

/**
 * Single number for balance math and matchmaking estimates: the mean scaled
 * stat. NOT a win predictor — the sim decides fights; this ranks them.
 */
export function powerScore(stats: BaseStats, rarity: Rarity, star: number): number {
  const m = rarityMult(rarity) * starMult(star);
  return ((stats.power + stats.guard + stats.vitality + stats.tempo) / 4) * m;
}

// Back-compat: legacy call sites pass a 0..5 fusionTier. star is 1..5; a
// fusionTier of 0 meant "no fusion", i.e. exactly one star.
export function fusionTierAsStar(fusionTier: number | undefined): StarLevel {
  const t = fusionTier ?? 0;
  return Math.min(Math.max(t + 1, 1), 5) as StarLevel;
}
