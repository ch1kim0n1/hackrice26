// Revaluation: the one place a monster's worth is decided.
//
// Issue #120. Net worth changes at several moments -- a monster is minted, it
// gains a star, it comes out of a cauldron or off a Plinko board -- and every
// one of those paths used to be free to compute a value its own way. That is
// how two monsters with identical stats end up priced differently depending on
// which door they came through.
//
// So: nothing computes `value` itself. Everything calls `revalue()`, which
// applies the one formula from docs/NET-WORTH.md:
//
//     value = base net worth + star bonus(rarity, star)
//
// and reports the rarity band that value lands in. `rarity` on the monster is
// a separate, permanent property -- stars never change it (net worth spec
// §14) -- so the band is returned alongside rather than written over it.

import { Rarity } from "../types";
import {
  StarLevel,
  asStarLevel,
  netWorthFor,
  rarityForValue,
  starBonus
} from "./rarityBands";

/** Anything that can be revalued: the fields the formula actually reads. */
export interface Valuable {
  /** Worth at one star, before mastery. Set when the monster was minted. */
  baseValue: number;
  /** The monster's own rarity. Permanent; stars do not change it. */
  rarity: Rarity;
  /** 1..5. */
  stars?: number;
}

export interface Valuation {
  /** Current authoritative net worth: what `value` must be set to. */
  value: number;
  /** What the base was, so a caller can store it back unchanged. */
  baseValue: number;
  star: StarLevel;
  /** The mastery component, broken out for display. */
  starBonus: number;
  /** The monster's own rarity, unchanged. */
  rarity: Rarity;
  /**
   * The band `value` falls into, which may be ABOVE `rarity` for a mastered
   * monster -- that overlap is intended (net worth spec §9). Use it to price
   * rewards, never to relabel the monster.
   */
  valueBand: Rarity;
}

/** Every reason a monster's worth can change. Named so hooks are auditable. */
export type RevaluationTrigger =
  | "mint"
  | "merge"
  | "gamble_win"
  | "sell_quote"
  | "manual";

/**
 * Recompute a monster's net worth.
 *
 * Pure: same input, same answer, no clock and no database. The callers below
 * are the hooks; this is the formula they all share.
 */
export function revalue(monster: Valuable): Valuation {
  const star = asStarLevel(monster.stars ?? 1);
  const baseValue = Math.max(0, Math.round(monster.baseValue));
  const value = netWorthFor(baseValue, monster.rarity, star);

  return {
    value,
    baseValue,
    star,
    starBonus: starBonus(monster.rarity, star),
    rarity: monster.rarity,
    valueBand: rarityForValue(value)
  };
}

/**
 * Recover the base worth of a monster that only stores its current `value`.
 *
 * Inventory rows written before mastery existed hold a total with no record of
 * how much of it was star bonus. Subtracting the bonus for the star level they
 * claim reconstructs the base, so those rows can be revalued without a
 * migration that would have to guess.
 */
export function baseValueOf(currentValue: number, rarity: Rarity, stars?: number): number {
  const star = asStarLevel(stars ?? 1);
  return Math.max(0, Math.round(currentValue) - starBonus(rarity, star));
}

/**
 * Revalue a monster already carrying a total, e.g. after a merge raised its
 * star level. Reads the base out of the old total first, so the bonus is
 * applied once rather than compounding on every call.
 */
export function revalueFromTotal(
  currentValue: number,
  rarity: Rarity,
  previousStars: number | undefined,
  nextStars: number
): Valuation {
  return revalue({
    baseValue: baseValueOf(currentValue, rarity, previousStars),
    rarity,
    stars: nextStars
  });
}

/**
 * What selling a monster pays.
 *
 * The full current net worth, mastery included. Selling is a conversion of a
 * monster into coins at what it is worth, not a haircut -- the house already
 * takes its cut at the tables, and charging again on the way out would make
 * every win worth less than the number the player was shown.
 */
export const SELL_RATE = 1;

export function sellValue(monster: Valuable): number {
  return Math.floor(revalue(monster).value * SELL_RATE);
}
