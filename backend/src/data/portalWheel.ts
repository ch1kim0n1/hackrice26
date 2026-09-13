// Portal Wheel configuration. The section layout and nothing else — every
// probability and every payout in this game is derived from the array below,
// so retuning the wheel is editing one list and the odds follow.
//
// That is deliberate, and it is the whole fairness argument (spec §22). A
// hand-written multiplier table beside a hand-written layout is two things
// that can disagree; here the visible wheel and the published odds are the
// same data read twice.

import { HOUSE_EDGE } from "./cauldron";

/** Same edge as Cauldron Crash, Kitchen Mines and Plinko. Imported, never redeclared. */
export { HOUSE_EDGE };

/** The four portal colours. Betting colours only — no elemental meaning (spec §6). */
export type PortalColor = "blue" | "red" | "yellow" | "green";

/** Declaration order, which is also the order the help table is printed in:
 *  rarest section count first, so the risk ladder reads top to bottom. */
export const PORTAL_COLORS: readonly PortalColor[] = ["blue", "red", "yellow", "green"] as const;

/**
 * The wheel, section by section, clockwise from the pointer.
 *
 * Sixteen equal-sized sections with intentionally unequal colour counts:
 *
 *     blue 2 · red 3 · yellow 4 · green 7
 *
 * which is four clearly different risk levels without a Safe/Risky/Insane
 * selector (spec §7). Matching colours are spread around the rim rather than
 * grouped, so no colour looks like one fat wedge — but position is decoration:
 * a section's odds are 1/16 wherever it sits (spec §23).
 *
 * Every section is equal-sized on screen because every section is equally
 * likely here. If this array grows a colour, the wheel grows a wedge.
 */
export const SECTION_LAYOUT: readonly PortalColor[] = [
  "green",
  "blue",
  "yellow",
  "green",
  "red",
  "green",
  "yellow",
  "green",
  "blue",
  "red",
  "green",
  "yellow",
  "green",
  "red",
  "yellow",
  "green"
] as const;

export const TOTAL_SECTIONS = SECTION_LAYOUT.length;

/** Exactly one monster per spin (spec §3). */
export const WAGER_MONSTERS = 1;

/**
 * How each portal is drawn. Presentational, but served from the same place the
 * odds are so the wedge a player bets on is the colour the server named.
 */
export const PORTAL_PALETTE: Record<PortalColor, { label: string; colorHex: string }> = {
  blue: { label: "Blue", colorHex: "#3B82F6" },
  red: { label: "Red", colorHex: "#EF4444" },
  yellow: { label: "Yellow", colorHex: "#F59E0B" },
  green: { label: "Green", colorHex: "#22C55E" }
};

// --- Invariants. A bad rebalance should fail at boot, not in a demo. ---

if (TOTAL_SECTIONS < PORTAL_COLORS.length) {
  throw new Error(`SECTION_LAYOUT has ${TOTAL_SECTIONS} sections, too few for ${PORTAL_COLORS.length} colours`);
}

for (const [index, color] of SECTION_LAYOUT.entries()) {
  if (!PORTAL_COLORS.includes(color)) {
    throw new Error(`SECTION_LAYOUT section ${index} is "${color}", which is not a portal colour`);
  }
}

// Every colour must own at least one section. A colour with none is a bet that
// cannot be won, offered at a finite price.
for (const color of PORTAL_COLORS) {
  if (!SECTION_LAYOUT.includes(color)) {
    throw new Error(`SECTION_LAYOUT gives "${color}" no sections, so that bet can never win`);
  }
}

// No colour may own so much of the rim that hitting it pays less than the
// wager. `(1 - edge) / P >= 1` means `P <= 1 - edge`, so this is the point at
// which a "win" would quietly return less than it cost.
for (const color of PORTAL_COLORS) {
  const sections = SECTION_LAYOUT.filter((section) => section === color).length;
  if (sections / TOTAL_SECTIONS > 1 - HOUSE_EDGE) {
    throw new Error(
      `SECTION_LAYOUT gives "${color}" ${sections}/${TOTAL_SECTIONS} sections, ` +
        `which pays under 1x — winning that bet would lose net worth`
    );
  }
}
