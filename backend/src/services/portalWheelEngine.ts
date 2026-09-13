// Portal Wheel — the pure spin math.
//
// One monster, one colour, one spin. The wheel has sixteen equal sections and
// the colours own unequal numbers of them, so the whole game is:
//
//     P(colour) = sections owned / total sections
//     payout    = (1 - HOUSE_EDGE) / P(colour)
//
// Fewer sections, longer odds, bigger multiplier — and because both halves are
// read off the same layout array, the wheel a player looks at cannot disagree
// with the price they are quoted (spec §22).
//
// The spin itself picks a SECTION, not a colour. That matters: the pointer has
// to stop on one specific wedge, and the client spins to that wedge. Choosing a
// colour first and a wedge afterwards would leave the animation free to land
// anywhere the result allowed, which is the kind of freedom that turns into a
// lie about where the pointer really was.
//
// Nothing here reads the clock or the RNG; the caller supplies the roll.

import {
  HOUSE_EDGE,
  PORTAL_COLORS,
  PortalColor,
  SECTION_LAYOUT,
  TOTAL_SECTIONS
} from "../data/portalWheel";

/** Cursors for this game's rolls. Distinct from every other game's. */
export const PORTAL_WHEEL_CURSOR = {
  /** Which of the sixteen sections the pointer stops on. */
  section: 400,
  rewardCharacter: 100,
  rewardPower: 101
} as const;

export function isColorLegal(value: unknown): value is PortalColor {
  return typeof value === "string" && (PORTAL_COLORS as readonly string[]).includes(value);
}

/** Which sections a colour owns, in wheel order. The client draws from this. */
export function sectionsFor(color: PortalColor): number[] {
  return SECTION_LAYOUT.reduce<number[]>((found, section, index) => {
    if (section === color) found.push(index);
    return found;
  }, []);
}

export function sectionCount(color: PortalColor): number {
  return sectionsFor(color).length;
}

/** The real chance the pointer stops on this colour (spec §8). */
export function probabilityOf(color: PortalColor): number {
  return sectionCount(color) / TOTAL_SECTIONS;
}

export function colorAtSection(section: number): PortalColor {
  const color = SECTION_LAYOUT[section];
  if (!color) throw new Error(`section ${section} is not on the wheel`);
  return color;
}

/**
 * What a colour pays: `(1 - HOUSE_EDGE) / P(colour)`, quoted to two decimals.
 *
 * Rounded DOWN, like every other multiplier in the casino — the player is
 * never paid for a hundredth they did not earn, and the epsilon absorbs
 * IEEE-754 error so a fair 3.80 cannot arrive as 3.799999999999999 and be
 * docked a cent by the floor rather than by the rules.
 *
 * Flooring means the real edge is a shade above 5% on colours whose exact
 * payout is not a round number (green quotes 2.17 rather than 2.171428…).
 * `houseEdgeFor` below reports that honestly instead of repeating the nominal
 * figure.
 */
export function multiplierFor(color: PortalColor): number {
  const exact = (1 - HOUSE_EDGE) / probabilityOf(color);
  return Math.floor(exact * 100 + 1e-9) / 100;
}

/**
 * What this bet actually returns per unit wagered, given the quoted payout.
 *
 * A wheel has no single house edge: each colour is its own bet. This is the
 * per-colour figure, and it should sit a touch below `1 - HOUSE_EDGE` — never
 * above it, which would mean the board is paying out more than it charges.
 */
export function expectedMultiplierFor(color: PortalColor): number {
  return probabilityOf(color) * multiplierFor(color);
}

export function houseEdgeFor(color: PortalColor): number {
  return 1 - expectedMultiplierFor(color);
}

/** The worst edge any colour on this wheel charges. */
export function worstHouseEdge(): number {
  return Math.max(...PORTAL_COLORS.map(houseEdgeFor));
}

/**
 * Spin the wheel: one uniform pick among the sections.
 *
 * `roll(cursor)` must return a float in [0, 1); the caller supplies the
 * commit-reveal HMAC so this stays pure and replayable. Nothing about the
 * wager, the player or the chosen colour reaches this function — which is what
 * makes spec §21 (no hidden odds manipulation) structurally true rather than a
 * promise.
 */
export function spinSection(roll: (cursor: number) => number): number {
  const raw = roll(PORTAL_WHEEL_CURSOR.section);
  return Math.min(TOTAL_SECTIONS - 1, Math.floor(raw * TOTAL_SECTIONS));
}

/**
 * What a spin is worth. Floored, like every stored net worth.
 *
 * A wrong colour is worth nothing at all, which is a real outcome and not an
 * error: the monster is spent and nothing comes back (spec §17).
 */
export function finalNetWorth(wagerValue: number, multiplier: number, won: boolean): number {
  return won ? Math.floor(wagerValue * multiplier) : 0;
}

/**
 * The whole odds table with its real numbers, for the help panel (spec §26).
 *
 * Generated from the layout rather than hardcoded, so a retuned wheel cannot
 * leave the published table describing the old one.
 */
export function oddsTable(): {
  color: PortalColor;
  sections: number;
  totalSections: number;
  sectionIndexes: number[];
  probability: number;
  multiplier: number;
  houseEdge: number;
}[] {
  return PORTAL_COLORS.map((color) => ({
    color,
    sections: sectionCount(color),
    totalSections: TOTAL_SECTIONS,
    sectionIndexes: sectionsFor(color),
    probability: probabilityOf(color),
    multiplier: multiplierFor(color),
    houseEdge: houseEdgeFor(color)
  }));
}

/** Sanity: no colour may pay out more than the house charges for it. */
export function edgeMatchesHouse(tolerance = 0.005): boolean {
  return PORTAL_COLORS.every((color) => {
    const edge = houseEdgeFor(color);
    return edge >= HOUSE_EDGE - 1e-9 && edge <= HOUSE_EDGE + tolerance;
  });
}
