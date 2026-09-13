// Net worth: the exponential rarity bands and the additive star economy.
//
// Canonical implementation of docs/NET-WORTH.md (issues #121, #130, #77, #80).
// Everything about what a monster is *worth* lives here; nothing about what it
// does in a fight. Combat scaling is deliberately a separate system (spec §19)
// and is not modelled in this file.
//
// Two ideas, in order:
//
//   1. Rarity is the primary driver of value, and it scales exponentially.
//      The Common -> Uncommon gap is small; the Epic -> Legendary gap is
//      enormous. That falls out of a geometric ladder of band floors.
//
//   2. Stars add value, they do not multiply it. A star bonus is a property of
//      the *rarity band*, not of the individual monster, so two Commons worth
//      500 and 900 both gain the same amount at 3 stars and their individual
//      difference survives mastery (spec §3, §6).
//
// The anchor that ties the two together: a 5-star monster is worth about the
// same as a 2-star monster of the next rarity up (spec §8). Reaching 5 stars
// costs 81 one-star copies, so mastery has to buy real economic ground -- but
// it buys the *bottom* of the next band, never the whole of it (spec §9).

import { Rarity } from "../types";
import { POWER_BANDS, RARITY_ORDER } from "../data/lootTable";

/**
 * Net worth of the cheapest possible Common. Everything else is derived from
 * it, so re-basing the whole economy is a one-number change.
 */
export const BAND_BASE = 500;

/**
 * Growth factor per rarity step, ascending.
 *
 * These escalate (2.2 -> 3.2) rather than staying constant, because the spec
 * asks for the gaps themselves to widen as rarity climbs: a constant factor
 * already grows gaps geometrically, an escalating one makes the top of the
 * ladder feel genuinely out of reach. Index i is the step from RARITY_ORDER[i]
 * to RARITY_ORDER[i + 1].
 */
export const BAND_FACTORS = [2.2, 2.4, 2.6, 2.8, 3.0, 3.2] as const;

/**
 * Fractions of a rarity's own step width that each star level adds.
 *
 * 5 stars is deliberately absent: it is not a free parameter. It is solved for
 * (see STAR_BONUS) so that a 5-star monster lands on a 2-star monster of the
 * next rarity, which is the balancing anchor the whole star economy hangs on.
 */
export const STAR_STEP_FRACTIONS: Record<2 | 3 | 4, number> = {
  2: 0.15, // "noticeable, still firmly within its rarity"
  3: 0.4, //  "meaningful investment"
  4: 0.75 // "approaching the next rarity"
};

export const MAX_STAR_LEVEL = 5;
/** Copies of the previous star level needed to make one of the next. */
export const FUSION_COPIES_PER_LEVEL = 3;

export type StarLevel = 1 | 2 | 3 | 4 | 5;

/** Total 1-star copies behind one monster at each star level: 3^(n-1). */
export function copiesForStar(star: StarLevel): number {
  return FUSION_COPIES_PER_LEVEL ** (star - 1);
}

// ---------------------------------------------------------------------------
// Bands
// ---------------------------------------------------------------------------

export interface RarityBand {
  rarity: Rarity;
  /** Inclusive lower bound, and the net worth of the cheapest 1-star monster. */
  min: number;
  /** Inclusive upper bound; Infinity for the top tier. */
  max: number;
  /** Width of this band: `min` of the next tier minus this one's. */
  step: number;
}

/**
 * The band floors: a geometric ladder from BAND_BASE.
 *
 * `floor(n+1) = floor(n) * BAND_FACTORS[n]`, rounded to something a human can
 * read in a balance spreadsheet.
 */
function computeFloors(): number[] {
  const floors: number[] = [BAND_BASE];
  for (let i = 0; i < RARITY_ORDER.length - 1; i++) {
    const factor = BAND_FACTORS[Math.min(i, BAND_FACTORS.length - 1)];
    floors.push(roundToScale(floors[i] * factor));
  }
  return floors;
}

/** Round to a readable step for the magnitude: 10s low down, 1000s up top. */
function roundToScale(value: number): number {
  const scale = value < 1_000 ? 10 : value < 10_000 ? 50 : value < 100_000 ? 500 : 1_000;
  return Math.round(value / scale) * scale;
}

const FLOORS = computeFloors();

/**
 * The top tier has no next floor, so its step is extrapolated one rung further
 * up the same ladder. Without this, Secret would have no star bonuses at all.
 */
const SECRET_STEP = roundToScale(FLOORS[FLOORS.length - 1] * (BAND_FACTORS[BAND_FACTORS.length - 1] - 1));

export const RARITY_BANDS: Record<Rarity, RarityBand> = Object.fromEntries(
  RARITY_ORDER.map((rarity, i) => {
    const isTop = i === RARITY_ORDER.length - 1;
    return [
      rarity,
      {
        rarity,
        min: FLOORS[i],
        max: isTop ? Infinity : FLOORS[i + 1] - 1,
        step: isTop ? SECRET_STEP : FLOORS[i + 1] - FLOORS[i]
      }
    ];
  })
) as Record<Rarity, RarityBand>;

/**
 * The band a net worth falls into.
 *
 * Anything below the Common floor is still Common -- the floor is where the
 * *cheapest* Common sits, not a minimum that value must clear.
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
 * Additive net worth a star level grants, per rarity.
 *
 * Levels 2-4 are fractions of the band's own width. Level 5 is solved, not
 * chosen:
 *
 *     bonus5(N) = step(N) + bonus2(N + 1)
 *
 * which places a 5-star monster of rarity N exactly on the 2-star value of the
 * cheapest monster of rarity N+1 -- the anchor from spec §8. Everything else in
 * the star economy is a consequence of that one equation.
 */
export const STAR_BONUS: Record<Rarity, Record<StarLevel, number>> = Object.fromEntries(
  RARITY_ORDER.map((rarity, i) => {
    const band = RARITY_BANDS[rarity];
    const next = i + 1 < RARITY_ORDER.length ? RARITY_BANDS[RARITY_ORDER[i + 1]] : null;
    const nextStep = next ? next.step : SECRET_STEP;

    return [
      rarity,
      {
        1: 0,
        2: Math.round(band.step * STAR_STEP_FRACTIONS[2]),
        3: Math.round(band.step * STAR_STEP_FRACTIONS[3]),
        4: Math.round(band.step * STAR_STEP_FRACTIONS[4]),
        5: Math.round(band.step + nextStep * STAR_STEP_FRACTIONS[2])
      }
    ];
  })
) as Record<Rarity, Record<StarLevel, number>>;

export function starBonus(rarity: Rarity, star: StarLevel): number {
  return STAR_BONUS[rarity]?.[star] ?? 0;
}

/**
 * A monster instance's current authoritative net worth (spec §1, §15).
 *
 * This is the only place the two halves meet, and it is what `value` on an
 * inventory row must always equal.
 */
export function netWorthFor(baseValue: number, rarity: Rarity, star: StarLevel): number {
  return Math.round(baseValue) + starBonus(rarity, star);
}

// ---------------------------------------------------------------------------
// Minting
// ---------------------------------------------------------------------------

/**
 * How far up its own band a power roll can carry a freshly-pulled monster, and
 * what the holo variant adds on top.
 *
 * They sum to 0.8, deliberately short of 1.0: a brand-new monster, however
 * lucky the roll, never reaches the floor of the next rarity. Climbing bands is
 * what fusion and the cauldron are for.
 */
export const BAND_POSITION_SPAN = 0.6;
export const SHINY_BAND_BONUS = 0.2;

const POWER_MULTIPLIERS = POWER_BANDS.map((band) => band.valueMultiplier);
const POWER_MIN = Math.min(...POWER_MULTIPLIERS);
const POWER_MAX = Math.max(...POWER_MULTIPLIERS);

/**
 * Base net worth of a freshly minted 1-star monster.
 *
 * The rarity picks the band; the power roll and the holo decide where inside it
 * the monster lands. This is what gives two Commons different base values
 * without either of them stopping being Common (spec §3).
 */
export function dropNetWorth(rarity: Rarity, powerValueMultiplier: number, shiny: boolean): number {
  const band = RARITY_BANDS[rarity];
  const spread = POWER_MAX - POWER_MIN;
  const normalized = spread === 0 ? 0 : (powerValueMultiplier - POWER_MIN) / spread;
  const position = Math.min(
    1,
    Math.max(0, normalized) * BAND_POSITION_SPAN + (shiny ? SHINY_BAND_BONUS : 0)
  );
  return Math.round(band.min + band.step * position);
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
  for (let star = 2; star <= MAX_STAR_LEVEL; star++) {
    if (bonuses[star as StarLevel] <= bonuses[(star - 1) as StarLevel]) {
      throw new Error(`star bonuses must increase: ${rarity} ★${star} is not worth more than ★${star - 1}`);
    }
  }
}

for (const rarity of RARITY_ORDER) {
  const band = RARITY_BANDS[rarity];
  const luckiest = dropNetWorth(rarity, POWER_MAX, true);
  if (luckiest > band.max) {
    throw new Error(
      `a fresh ${rarity} can mint at ${luckiest}, past its own band ceiling ${band.max}`
    );
  }
}
