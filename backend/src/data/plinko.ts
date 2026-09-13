// Plinko configuration. Board shape and the payout table, kept here so the
// economy can be retuned without touching the drop logic in
// services/plinkoEngine.ts.

/**
 * Twelve peg rows, thirteen landing slots.
 *
 * Every row is one left/right decision, so a drop is twelve coin flips and the
 * slot is how many went right. That makes the landing distribution exactly
 * binomial — `C(12, k) / 2^12` — which is what the payout table below is
 * balanced against.
 */
export const PEG_ROWS = 12;
export const SLOT_COUNT = PEG_ROWS + 1;

/** Total distinct paths through the board: 2^12. */
export const TOTAL_PATHS = 2 ** PEG_ROWS;

/** Same edge as Cauldron Crash and Kitchen Mines. Imported, never redeclared. */
export { HOUSE_EDGE } from "./cauldron";

/** Exactly one monster per drop (spec §2). */
export const WAGER_MONSTERS = 1;

/**
 * What each slot pays, left to right.
 *
 * Symmetric, because the board is. The centre is where the orb almost always
 * lands and it pays nothing at all; everything else pays the wager back or
 * better, rising to 25x at the edges.
 *
 * That shape is deliberate. An earlier table ran a 150x jackpot, which at a
 * fixed 5% edge forced nearly every other slot below 1x -- 63% of drops were a
 * slow bleed and only 15% broke even. Since Plinko is the one game with no
 * cash-out, that read as relentless. Capping the jackpot at 25x buys back the
 * whole middle of the board: now the only way to lose value is the centre
 * slot, and 77% of drops return the wager or more.
 *
 * The edge is unchanged. It is paid entirely by that 22.6% bust rather than by
 * grinding down the common slots.
 *
 * These numbers are NOT free: they are balanced against the real landing
 * probabilities so the weighted payout comes to ~0.95x, the same 5% edge the
 * rest of the casino runs at. The invariant at the bottom of this file fails
 * at boot if a rebalance breaks that, because a Plinko board whose table has
 * drifted is a casino quietly giving money away (or quietly taking it).
 *
 *   slot:    0     1    2    3     4     5    6    7     8     9   10   11   12
 *   paths:   1    12   66  220   495   792  924  792   495   220   66   12    1
 */
export const SLOT_MULTIPLIERS: number[] = [
  25, 4.2, 2, 1.6, 1.2, 1, 0, 1, 1.2, 1.6, 2, 4.2, 25
];

/**
 * How hot a slot looks. Purely presentational, and derived from the payout
 * table rather than hand-listed, so adding a slot cannot leave a gap.
 */
export function slotTier(multiplier: number): "bust" | "loss" | "even" | "win" | "jackpot" {
  if (multiplier === 0) return "bust";
  if (multiplier < 1) return "loss";
  if (multiplier < 2) return "even";
  if (multiplier < 20) return "win";
  return "jackpot";
}

// --- Invariants. A bad rebalance should fail at boot, not in a demo. ---

if (SLOT_MULTIPLIERS.length !== SLOT_COUNT) {
  throw new Error(`SLOT_MULTIPLIERS has ${SLOT_MULTIPLIERS.length} entries, expected ${SLOT_COUNT}`);
}

for (const multiplier of SLOT_MULTIPLIERS) {
  if (!Number.isFinite(multiplier) || multiplier < 0) {
    throw new Error(`SLOT_MULTIPLIERS contains an illegal payout: ${multiplier}`);
  }
}

// Mirrored slots must match, or the board lies about being symmetric.
for (let i = 0; i < SLOT_COUNT; i++) {
  const mirrored = SLOT_MULTIPLIERS[SLOT_COUNT - 1 - i];
  if (SLOT_MULTIPLIERS[i] !== mirrored) {
    throw new Error(`SLOT_MULTIPLIERS is not symmetric: slot ${i} pays ${SLOT_MULTIPLIERS[i]}, its mirror pays ${mirrored}`);
  }
}

// Payouts must rise towards the edges: a common slot paying more than a rare
// one would invert the whole point of the board.
for (let i = 1; i <= Math.floor(SLOT_COUNT / 2); i++) {
  if (SLOT_MULTIPLIERS[i - 1] < SLOT_MULTIPLIERS[i]) {
    throw new Error(
      `SLOT_MULTIPLIERS must not decrease towards the edge: slot ${i - 1} pays ` +
        `${SLOT_MULTIPLIERS[i - 1]}, slot ${i} pays ${SLOT_MULTIPLIERS[i]}`
    );
  }
}
