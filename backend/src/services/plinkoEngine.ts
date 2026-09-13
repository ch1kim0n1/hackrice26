// Plinko — the pure drop math.
//
// The simplest game in the casino: one monster, one drop, no decisions. The
// orb falls through twelve rows of pegs, goes left or right at each, and lands
// in whichever of the thirteen slots the twelve choices add up to.
//
// That makes the landing distribution exactly binomial:
//
//     P(slot k) = C(12, k) / 2^12
//
// which is not an approximation of the animation — it IS the outcome. The
// server rolls the twelve decisions from the commit-reveal seed chain and
// hands the whole path to the client, so the orb the player watches is
// bouncing along the route that actually decided the result. The animation
// cannot contradict the outcome because it is drawn from it.
//
// Nothing here reads the clock or the RNG; the caller supplies the roll.

import {
  HOUSE_EDGE,
  PEG_ROWS,
  SLOT_COUNT,
  SLOT_MULTIPLIERS,
  TOTAL_PATHS
} from "../data/plinko";

/** Cursors for this game's rolls. Distinct from every other game's. */
export const PLINKO_CURSOR = {
  /** Base for the per-row left/right decisions; one cursor per row. */
  pathBase: 300,
  rewardCharacter: 80,
  rewardPower: 81
} as const;

/** Binomial coefficient C(n, k). Exact for the values this board uses. */
export function pathsToSlot(slot: number): number {
  if (slot < 0 || slot > PEG_ROWS) return 0;
  let result = 1;
  for (let i = 0; i < slot; i++) {
    result = (result * (PEG_ROWS - i)) / (i + 1);
  }
  return Math.round(result);
}

/** The real chance the orb lands in a given slot. */
export function slotProbability(slot: number): number {
  return pathsToSlot(slot) / TOTAL_PATHS;
}

export function multiplierForSlot(slot: number): number {
  return SLOT_MULTIPLIERS[slot] ?? 0;
}

export function isSlotLegal(slot: number): boolean {
  return Number.isInteger(slot) && slot >= 0 && slot < SLOT_COUNT;
}

/**
 * The weighted payout across the whole board.
 *
 * This is the number the house edge lives in: it should come out at
 * `1 - HOUSE_EDGE`. Exposed rather than hidden so the config's boot-time
 * invariant and the published odds endpoint both read the same figure.
 */
export function expectedMultiplier(): number {
  let expected = 0;
  for (let slot = 0; slot < SLOT_COUNT; slot++) {
    expected += slotProbability(slot) * multiplierForSlot(slot);
  }
  return expected;
}

/** Actual edge the board charges, given the current payout table. */
export function actualHouseEdge(): number {
  return 1 - expectedMultiplier();
}

/**
 * Roll one drop.
 *
 * Twelve independent left/right decisions, one per peg row. `true` is a step
 * to the right; the slot is simply how many of them there were, which is why
 * the distribution is binomial rather than something the physics has to be
 * tuned to imitate.
 *
 * `roll(cursor)` must return a float in [0, 1); the caller supplies the
 * commit-reveal HMAC so this stays pure and replayable.
 */
export function dropPath(roll: (cursor: number) => number): boolean[] {
  const path: boolean[] = [];
  for (let row = 0; row < PEG_ROWS; row++) {
    path.push(roll(PLINKO_CURSOR.pathBase + row) >= 0.5);
  }
  return path;
}

/** Which slot a path lands in: the number of rightward steps. */
export function slotForPath(path: boolean[]): number {
  return path.reduce((slot, wentRight) => slot + (wentRight ? 1 : 0), 0);
}

/**
 * What a drop is worth. Floored, like every stored net worth.
 *
 * A landing on the 0x slot is worth nothing at all, which is a real outcome
 * and not an error: the monster is spent and nothing comes back.
 */
export function finalNetWorth(wagerValue: number, multiplier: number): number {
  return Math.floor(wagerValue * multiplier);
}

/**
 * The whole payout table with its real odds, for the help panel.
 *
 * Published because the odds are not a secret — the player should be able to
 * see that the centre slot is nearly a quarter of all drops before they spend
 * a monster on one.
 */
export function payoutTable(): {
  slot: number;
  multiplier: number;
  paths: number;
  probability: number;
}[] {
  return Array.from({ length: SLOT_COUNT }, (_, slot) => ({
    slot,
    multiplier: multiplierForSlot(slot),
    paths: pathsToSlot(slot),
    probability: slotProbability(slot)
  }));
}

/** Sanity: the published edge must match the one the rest of the casino runs. */
export function edgeMatchesHouse(tolerance = 0.005): boolean {
  return Math.abs(actualHouseEdge() - HOUSE_EDGE) <= tolerance;
}
