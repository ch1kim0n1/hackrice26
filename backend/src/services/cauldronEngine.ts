// Cauldron Crash — the pure round math.
//
// Wager 1-3 owned monsters, their net worth becomes one pot, a multiplier
// climbs from 1.00x, and a hidden crash point ends the round. Cash out first
// and the pot's final value buys a random monster from whichever rarity
// bracket it lands in; cash out late and the cauldron takes everything.
//
// Nothing here reads the clock or the RNG: every function is a pure map from
// its arguments, so a round can be replayed and checked afterwards. The two
// impure inputs — when the round started and the roll that fixed its crash
// point — are supplied by the caller (services/cauldronState.ts).
//
// Fairness (spec §6, §8): the crash point comes from the same commit-reveal
// scheme the loot crates use,
//
//     roll = HMAC_SHA256(serverSeed, `${clientSeed}:${nonce}:${cursor}`)
//
// so it is generated server-side from a secret the server published a hash of
// before the round began. It cannot depend on the wager, the player, or the
// history, because none of those are inputs to it.

import {
  HOUSE_EDGE,
  MAX_WAGER_MONSTERS,
  MIN_WAGER_MONSTERS,
  MULTIPLIER_GROWTH_RATE,
  VISUAL_INTENSITY_THRESHOLDS,
  netWorthRounding
} from "../data/cauldron";
import { RARITY_ORDER } from "../data/lootTable";
import { rarityForValue as bandRarityForValue } from "../game/rarityBands";
import { Rarity } from "../types";

/** Cursors for the round's rolls. Distinct from the crate cursors in
 *  lootboxEngine so a crash and an open never share a digest. */
export const CAULDRON_CURSOR = {
  crash: 40,
  rewardCharacter: 41,
  rewardPower: 42
} as const;

/** A crash multiplier of 1.00x means the cauldron blew up on contact. */
export const MIN_CRASH_MULTIPLIER = 1;

/** Ceiling on a crash point, so a roll of ~0 cannot produce Infinity. */
export const MAX_CRASH_MULTIPLIER = 1_000_000;

/** Multipliers are quoted to two decimals, always rounded down: a player is
 *  never paid for a hundredth they did not actually reach.
 *
 *  The epsilon absorbs binary representation error before flooring, so a value
 *  that should be exactly 4.75 but computes as 4.749999999999999 is not
 *  quietly docked a hundredth for an artifact of IEEE-754. */
export function quantizeMultiplier(multiplier: number): number {
  return Math.floor(multiplier * 100 + 1e-9) / 100;
}

/**
 * The hidden crash point for a round, from a uniform roll in [0, 1).
 *
 * `crash = (1 - houseEdge) / roll` is the standard Crash distribution: the
 * chance a round survives to at least `x` is `(1 - houseEdge) / x`, so 2.00x
 * comes up 47.5% of the time and 10.00x 9.5% — see spec §6. The edge shows up
 * as the 5% of rolls that land above 0.95 and crash instantly at 1.00x.
 */
export function crashPointFrom(rollValue: number): number {
  if (!(rollValue > 0)) return MAX_CRASH_MULTIPLIER;
  const raw = (1 - HOUSE_EDGE) / rollValue;
  const clamped = Math.min(raw, MAX_CRASH_MULTIPLIER);
  return Math.max(MIN_CRASH_MULTIPLIER, quantizeMultiplier(clamped));
}

/** The multiplier a round is showing `elapsedMs` after it started. */
export function multiplierAt(elapsedMs: number): number {
  if (!(elapsedMs > 0)) return MIN_CRASH_MULTIPLIER;
  const grown = Math.exp(MULTIPLIER_GROWTH_RATE * (elapsedMs / 1000));
  return Math.max(MIN_CRASH_MULTIPLIER, quantizeMultiplier(grown));
}

/** Inverse of `multiplierAt`: when this round will hit `multiplier`. */
export function elapsedForMultiplier(multiplier: number): number {
  if (multiplier <= MIN_CRASH_MULTIPLIER) return 0;
  return (Math.log(multiplier) / MULTIPLIER_GROWTH_RATE) * 1000;
}

/** How wild the cauldron looks right now. A function of the displayed
 *  multiplier only — never of the crash point (spec §13). */
export function intensityFor(multiplier: number): string {
  let id = VISUAL_INTENSITY_THRESHOLDS[0].id;
  for (const tier of VISUAL_INTENSITY_THRESHOLDS) {
    if (multiplier >= tier.from) id = tier.id;
  }
  return id;
}

/**
 * The rarity bracket a net worth falls into.
 *
 * Re-exported from game/rarityBands rather than reimplemented: the casino
 * must price a pot on exactly the ladder the rest of the economy uses.
 */
export function rarityForValue(netWorth: number): Rarity {
  return bandRarityForValue(netWorth);
}

/** The pot a set of wagered monsters starts at. */
export function startingNetWorth(values: number[]): number {
  return values.reduce((sum, value) => sum + value, 0);
}

/** What a cash-out at `multiplier` is worth. Floored (spec §10). */
export function cashOutValue(startingValue: number, multiplier: number): number {
  return netWorthRounding(startingValue * multiplier);
}

export function isWagerSizeLegal(count: number): boolean {
  return count >= MIN_WAGER_MONSTERS && count <= MAX_WAGER_MONSTERS;
}

// ---------------------------------------------------------------------------
// Reward
// ---------------------------------------------------------------------------

// Buying a monster with a cash-out budget is not cauldron-specific -- Kitchen
// Mines pays out the same way -- so it lives in game/rewards.ts. Re-exported
// here so existing callers keep one import.
export { rewardFor, rewardPool } from "../game/rewards";
export type { MonsterReward as CauldronReward } from "../game/rewards";

// ---------------------------------------------------------------------------
// Threshold feedback (spec §12)
// ---------------------------------------------------------------------------

/** The rarity brackets a round crosses on its way from `from` to `to`. */
export function bracketsCrossed(from: number, to: number): Rarity[] {
  const start = rarityForValue(from);
  const end = rarityForValue(to);
  const startIndex = RARITY_ORDER.indexOf(start);
  const endIndex = RARITY_ORDER.indexOf(end);
  if (endIndex <= startIndex) return [];
  return RARITY_ORDER.slice(startIndex + 1, endIndex + 1);
}
