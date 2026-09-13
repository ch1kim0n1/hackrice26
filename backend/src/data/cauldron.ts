// Cauldron Crash configuration. Every tunable the game reads lives here, so
// the economy can be rebalanced without touching the round logic in
// services/cauldronEngine.ts (spec §4, §27).


/** House edge. P(round reaches x) = (1 - HOUSE_EDGE) / x. */
export const HOUSE_EDGE = 0.05;

export const MIN_WAGER_MONSTERS = 1;
export const MAX_WAGER_MONSTERS = 3;

/** Stored net worth is always floored to an integer (spec §10). */
export const netWorthRounding = Math.floor;

// Rarity brackets are NOT defined here. A cash-out's final net worth is priced
// against the one canonical ladder in game/rarityBands.ts, the same one that
// prices a crate pull and a fused monster -- a casino with its own private idea
// of what "Legendary" is worth is a second economy waiting to drift.
/**
 * Cauldron instability tiers. Purely a function of the *displayed* multiplier —
 * never of the hidden crash point, which is what stops the animation from
 * leaking the outcome (spec §13).
 */
export const VISUAL_INTENSITY_THRESHOLDS: { id: string; from: number }[] = [
  { id: "calm",      from: 1 },
  { id: "warming",   from: 2 },
  { id: "shaking",   from: 3 },
  { id: "searing",   from: 5 },
  { id: "unstable",  from: 10 }
];

/**
 * Multiplier growth, `m(t) = e^(RATE * t)` with `t` in seconds.
 *
 * The server keeps only the round's start time and derives the multiplier from
 * the clock on every request; the client animates the same curve so the number
 * on screen matches the one the server will price a cash-out at. 0.115 puts 2x
 * at ~6s, 5x at ~14s and 10x at ~20s — long enough to hesitate, short enough
 * that a round is over before attention is.
 */
export const MULTIPLIER_GROWTH_RATE = 0.115;

/** Rounds are abandoned (and settled as crashed) past this age. */
export const MAX_ROUND_AGE_MS = 10 * 60 * 1000;
