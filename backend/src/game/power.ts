// Combat power curve — rarity × mastery (issues #112, #131).
//
// The worth side of this was decided in rarityBands.ts (stars add value, and
// a 5-star monster prices like a 2-star of the next rarity up). Combat uses
// the multiplicative form of the same idea:
//
//     effectiveStat = baseStat × rarityMult × starMult(star)
//
// starMult follows the spec's authored curve (★1 ×1.00 … ★5 ×1.45), so a
// fully-mastered Common at ×1.45 actually edges a fresh Legendary's ×1.40 —
// mastery buys real ground. But star-for-star the next rarity always wins,
// so bands still dominate. Exactly the "rarity vs mastery" answer from the
// spec.

import { RARITY_TIERS } from "../data/lootTable";
import { Rarity } from "../types";
import { StarLevel } from "./rarityBands";

/**
 * Star -> combat multiplier (final-dev-doc §4). Replaces the old flat
 * 8%-per-star step: the spec's authored curve is steeper at the top so late
 * mastery matters more. Mirrors STAR_COMBAT_MULT in services/battleEngine.ts
 * — same table, kept here for non-battle scaling (merge previews).
 */
export const STAR_COMBAT_MULTS = [0, 1.0, 1.08, 1.18, 1.3, 1.45] as const;

export function starMult(star: number): number {
  const s = Math.min(Math.max(Math.trunc(star), 1), 5);
  return STAR_COMBAT_MULTS[s];
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
