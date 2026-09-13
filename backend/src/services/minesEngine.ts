// Kitchen Mines — the pure round math.
//
// 25 covered dishes, some number of them burnt. Reveal safe ingredients to
// climb a multiplier, and stop before you find a burnt one.
//
// The multiplier is NOT a hand-written payout table. It is the reciprocal of
// the real probability of having survived this many picks, times the house
// edge -- so the game pays what the risk is actually worth and a new mine
// count needs no balancing pass:
//
//     P(survive k picks) = C(S, k) / C(T, k)      S = safe tiles, T = 25
//     multiplier(k)      = (1 - HOUSE_EDGE) / P(survive k)
//
// Nothing here reads the clock or the RNG. The board layout is derived from
// the caller's seed chain, so a round can be replayed and checked afterwards,
// and the layout is fixed before the first pick rather than decided as the
// player goes -- a game that chose where the mines were *after* you clicked
// would not be the game these odds describe.

import {
  HEAT_THRESHOLDS,
  HOUSE_EDGE,
  MAX_MINES,
  MIN_MINES,
  TILE_COUNT
} from "../data/mines";

/** Cursors for this game's rolls. Distinct from the crate and cauldron
 *  cursors so no two games ever share a digest. */
export const MINES_CURSOR = {
  /** Base for the layout shuffle; one cursor per swap. */
  layoutBase: 200,
  rewardCharacter: 60,
  rewardPower: 61
} as const;

/** Multipliers are quoted to two decimals, always rounded down: the player is
 *  never paid for a hundredth they did not actually earn.
 *
 *  The epsilon absorbs binary representation error before flooring. A fair
 *  price of exactly 4.75 can compute as 4.749999999999999, and a naive floor
 *  would charge the player a hundredth for an artifact of IEEE-754 rather than
 *  for anything in the rules. */
export function quantizeMultiplier(multiplier: number): number {
  return Math.floor(multiplier * 100 + 1e-9) / 100;
}

export function isMineCountLegal(mines: number): boolean {
  return Number.isInteger(mines) && mines >= MIN_MINES && mines <= MAX_MINES;
}

export function safeTiles(mines: number): number {
  return TILE_COUNT - mines;
}

/**
 * The chance a board with `mines` mines survives `picks` safe reveals.
 *
 * Computed as a product of shrinking ratios rather than with factorials:
 * C(25, 12) overflows nothing, but the product form is exact for the values
 * this game uses and cannot drift for large k.
 *
 *     (S/T) * ((S-1)/(T-1)) * ... * ((S-k+1)/(T-k+1))
 */
export function survivalProbability(mines: number, picks: number): number {
  if (picks <= 0) return 1;
  const safe = safeTiles(mines);
  if (picks > safe) return 0;

  let probability = 1;
  for (let i = 0; i < picks; i++) {
    probability *= (safe - i) / (TILE_COUNT - i);
  }
  return probability;
}

/**
 * What the pot is worth after `picks` successful reveals.
 *
 * Zero picks pays 1.00x: the player has risked nothing yet and cashing out
 * immediately returns exactly what they put in (minus nothing -- the edge is
 * charged on the upside, not on the wager).
 */
export function multiplierAfter(mines: number, picks: number): number {
  if (picks <= 0) return 1;
  const probability = survivalProbability(mines, picks);
  if (probability <= 0) return 0;
  return Math.max(1, quantizeMultiplier((1 - HOUSE_EDGE) / probability));
}

/** What the next safe dish would pay. Drives the cash-out-or-risk-it prompt. */
export function nextMultiplier(mines: number, picks: number): number | null {
  if (picks >= safeTiles(mines)) return null; // board already cleared
  return multiplierAfter(mines, picks + 1);
}

/** The chance the next single pick is safe. Published; it is not a secret. */
export function nextPickSafeChance(mines: number, picks: number): number {
  const remaining = TILE_COUNT - picks;
  if (remaining <= 0) return 0;
  return (safeTiles(mines) - picks) / remaining;
}

/** Current pot value. Floored, like every stored net worth. */
export function potValue(wagerValue: number, multiplier: number): number {
  return Math.floor(wagerValue * multiplier);
}

/** How hot the kitchen looks. A function of the displayed multiplier only. */
export function heatFor(multiplier: number): string {
  let id = HEAT_THRESHOLDS[0].id;
  for (const tier of HEAT_THRESHOLDS) {
    if (multiplier >= tier.from) id = tier.id;
  }
  return id;
}

/**
 * Where the mines are.
 *
 * A Fisher-Yates shuffle of all 25 positions driven by the caller's roll
 * function, taking the first `mines` as the burnt ones. Deterministic in the
 * seed chain, uniform over every possible board, and fixed before the round
 * starts -- the three properties that make the published odds true.
 *
 * `roll(cursor)` must return a float in [0, 1); the caller supplies the
 * commit-reveal HMAC so this stays pure.
 */
export function mineLayout(mines: number, roll: (cursor: number) => number): number[] {
  const positions = Array.from({ length: TILE_COUNT }, (_, i) => i);

  for (let i = TILE_COUNT - 1; i > 0; i--) {
    const j = Math.min(i, Math.floor(roll(MINES_CURSOR.layoutBase + i) * (i + 1)));
    [positions[i], positions[j]] = [positions[j], positions[i]];
  }

  return positions.slice(0, mines).sort((a, b) => a - b);
}

export function isTileIndexLegal(tile: number): boolean {
  return Number.isInteger(tile) && tile >= 0 && tile < TILE_COUNT;
}
