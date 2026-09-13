// Net worth: the rarity bands and the additive star economy.
//
// Canonical implementation of the spec (final-dev-doc.pdf §2); every constant
// comes from game/spec.ts — this file is the math over them, nothing else.
// Everything about what a monster is *worth* lives here; nothing about what it
// does in a fight. Combat scaling is deliberately a separate system.
//
// Two ideas, in order:
//
//   1. Rarity is the primary driver of value. A fresh ★1 mint lands inside its
//      rarity's band and never crosses it; the weighted segment roll decides
//      where inside the band the individual monster sits.
//
//   2. Stars add value, they do not multiply it. A star bonus is a property of
//      the *rarity band*, not of the individual monster, so two Commons worth
//      500 and 900 both gain the same amount at 3 stars and their individual
//      difference survives mastery.

import { Rarity } from "../types";
import { RARITY_ORDER } from "../data/lootTable";
import {
  MINT_SEGMENTS,
  SECRET_MAX_STAR,
  SPEC_BANDS,
  SPEC_STAR_BONUS,
  MAX_STAR
} from "./spec";

export const MAX_STAR_LEVEL = MAX_STAR;
/** Copies of the previous star level needed to make one of the next. */
export const FUSION_COPIES_PER_LEVEL = 3;

export type StarLevel = 1 | 2 | 3 | 4 | 5;

/** Total 1-star copies behind one monster at each star level: 3^(n-1). */
export function copiesForStar(star: StarLevel): number {
  return FUSION_COPIES_PER_LEVEL ** (star - 1);
}

/**
 * The highest star level a rarity can reach (spec §2). Common through Mythic
 * run to ★5; Secret is capped at ★2 so terminal rarity cannot also stack
 * terminal mastery.
 */
export function maxStarsFor(rarity: Rarity): StarLevel {
  return (rarity === "secret" ? SECRET_MAX_STAR : MAX_STAR_LEVEL) as StarLevel;
}

// ---------------------------------------------------------------------------
// Bands
// ---------------------------------------------------------------------------

export interface RarityBand {
  rarity: Rarity;
  /** Inclusive lower bound, and the net worth of the cheapest 1-star monster. */
  min: number;
  /** Inclusive upper bound — the spec gives even Secret a ceiling. */
  max: number;
  /** Width of this band: max - min + 1 (== next band's floor minus this one's). */
  step: number;
}

export const RARITY_BANDS: Record<Rarity, RarityBand> = Object.fromEntries(
  RARITY_ORDER.map((rarity) => {
    const spec = SPEC_BANDS[rarity];
    return [
      rarity,
      { rarity, min: spec.min, max: spec.max, step: spec.max - spec.min + 1 }
    ];
  })
) as Record<Rarity, RarityBand>;

/**
 * The band a net worth falls into.
 *
 * Anything below the Common floor is still Common -- the floor is where the
 * *cheapest* Common sits, not a minimum that value must clear. Anything above
 * the Secret ceiling is still Secret -- mastery legitimately pushes a monster
 * past its own band's top (spec §2: Net Worth may exceed the ★1 band).
 */
export function bandForValue(netWorth: number): RarityBand {
  const value = Math.max(0, netWorth);
  for (let i = RARITY_ORDER.length - 1; i >= 0; i--) {
    const band = RARITY_BANDS[RARITY_ORDER[i]];
    if (value >= band.min) return band;
  }
  return RARITY_BANDS[RARITY_ORDER[0]];
}

/** Convenience: just the tier. */
export function rarityForValue(netWorth: number): Rarity {
  return bandForValue(netWorth).rarity;
}

// ---------------------------------------------------------------------------
// Star bonuses
// ---------------------------------------------------------------------------

/**
 * Additive net worth a star level grants, per rarity — the spec's frozen table
 * (§2). Levels 2-4 are 15%/40%/75% of the band's own width; level 5 anchors a
 * ★5 monster on a ★2 of the next rarity up. Secret lists ★2 only: higher stars
 * are unreachable (maxStarsFor) and read as 0.
 */
export const STAR_BONUS: Record<Rarity, Record<StarLevel, number>> = Object.fromEntries(
  RARITY_ORDER.map((rarity) => [
    rarity,
    {
      1: 0,
      2: SPEC_STAR_BONUS[rarity][2] ?? 0,
      3: SPEC_STAR_BONUS[rarity][3] ?? 0,
      4: SPEC_STAR_BONUS[rarity][4] ?? 0,
      5: SPEC_STAR_BONUS[rarity][5] ?? 0
    }
  ])
) as Record<Rarity, Record<StarLevel, number>>;

export function starBonus(rarity: Rarity, star: StarLevel): number {
  return STAR_BONUS[rarity]?.[star] ?? 0;
}

/**
 * A monster instance's current authoritative net worth (spec §2):
 *
 *     CurrentNetWorth = baseMintValue + starBonus[rarity][stars]
 *
 * This is the only place the two halves meet, and it is what `value` on an
 * inventory row must always equal.
 */
export function netWorthFor(baseValue: number, rarity: Rarity, star: StarLevel): number {
  return Math.round(baseValue) + starBonus(rarity, star);
}

// ---------------------------------------------------------------------------
// Minting — the weighted segment roll (spec §2)
// ---------------------------------------------------------------------------

/**
 * Which segment of its band a fresh mint lands in. Exposed for tests and for
 * audit trails that want to record the roll's anatomy.
 */
export interface MintSegment {
  from: number;
  to: number;
  weight: number;
}

export const MINT_SEGMENT_TABLE: readonly MintSegment[] = MINT_SEGMENTS;

/** Pick the band segment for a roll unit in [0,1). */
export function mintSegmentFor(segmentUnit: number): MintSegment {
  const u = Math.min(Math.max(segmentUnit, 0), 1 - Number.EPSILON);
  let cumulative = 0;
  for (const segment of MINT_SEGMENTS) {
    cumulative += segment.weight;
    if (u < cumulative) return segment;
  }
  return MINT_SEGMENTS[MINT_SEGMENTS.length - 1];
}

/**
 * Base mint value of a freshly minted ★1 monster (spec §2).
 *
 * Two independent rolls: `segmentUnit` picks the band segment by the
 * 55/27/13/4/1 weights, `positionUnit` rolls uniformly inside that segment.
 * The result is `baseMintValue` — permanent for the monster's lineage — and it
 * never lands outside its rarity's band.
 */
export function mintValue(rarity: Rarity, segmentUnit: number, positionUnit: number): number {
  const band = RARITY_BANDS[rarity];
  const segment = mintSegmentFor(segmentUnit);
  const position = segment.from + (segment.to - segment.from) * Math.min(Math.max(positionUnit, 0), 1);
  const value = Math.round(band.min + position * band.step);
  return Math.min(band.max, Math.max(band.min, value));
}

/**
 * Expected value of the mint roll for a rarity — mean segment position
 * (Σ weight × midpoint) applied to the band width. Used by EV math and tests:
 * Common ≈ 746, Secret ≈ 355,510 (spec §3 reference table).
 */
export function expectedMintValue(rarity: Rarity): number {
  const band = RARITY_BANDS[rarity];
  const meanPosition = MINT_SEGMENTS.reduce((sum, s) => sum + s.weight * (s.from + s.to) / 2, 0);
  return band.min + meanPosition * band.step;
}

/** Clamp anything claiming to be a star level into the legal 1..5. */
export function asStarLevel(value: unknown): StarLevel {
  const n = Math.trunc(Number(value));
  if (!Number.isFinite(n) || n < 1) return 1;
  return Math.min(n, MAX_STAR_LEVEL) as StarLevel;
}

// --- Invariants. A bad rebalance should fail at boot, not in a demo. ---

for (let i = 1; i < RARITY_ORDER.length; i++) {
  const previous = RARITY_BANDS[RARITY_ORDER[i - 1]];
  const current = RARITY_BANDS[RARITY_ORDER[i]];
  if (current.min !== previous.max + 1) {
    throw new Error(
      `rarity bands must tile: ${current.rarity} starts at ${current.min}, ` +
        `${previous.rarity} ends at ${previous.max}`
    );
  }
  if (current.step <= previous.step) {
    throw new Error(
      `rarity steps must widen with scarcity: ${current.rarity} step ${current.step} ` +
        `<= ${previous.rarity} step ${previous.step}`
    );
  }
}

for (const rarity of RARITY_ORDER) {
  const bonuses = STAR_BONUS[rarity];
  for (let star = 2; star <= maxStarsFor(rarity); star++) {
    if (bonuses[star as StarLevel] <= bonuses[(star - 1) as StarLevel]) {
      throw new Error(`star bonuses must increase: ${rarity} ★${star} is not worth more than ★${star - 1}`);
    }
  }
}

for (const rarity of RARITY_ORDER) {
  const band = RARITY_BANDS[rarity];
  // The luckiest legal mint: deepest segment, position at the top of it.
  const luckiest = mintValue(rarity, 1 - Number.EPSILON, 1 - Number.EPSILON);
  if (luckiest > band.max) {
    throw new Error(
      `a fresh ${rarity} can mint at ${luckiest}, past its own band ceiling ${band.max}`
    );
  }
}

const segmentWeightSum = MINT_SEGMENTS.reduce((sum, s) => sum + s.weight, 0);
if (Math.abs(segmentWeightSum - 1) > 1e-9) {
  throw new Error(`mint segment weights sum to ${segmentWeightSum}, expected 1`);
}
