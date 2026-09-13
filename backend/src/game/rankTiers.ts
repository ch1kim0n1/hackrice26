// Rank tiers — the consistency ladder (issues #67, #82, #83, #84).
//
// Two ladders exist and they are deliberately separate:
//
//   rating / tier      Elo. How well you FIGHT. Moved by ranked results.
//   rankPoints / tier  Consistency. How well you EAT. Moved by daily
//                      objectives and day-log quality (award path is #83).
//
// This module owns only the second one: points -> tier, and the
// promotion/demotion event after a point change. Everything here is a pure
// function of points so the badge a player sees can never disagree with the
// number that produced it.

export type RankTier = "bronze" | "silver" | "gold" | "plat";

export const RANK_ORDER: RankTier[] = ["bronze", "silver", "gold", "plat"];

/**
 * Inclusive floors per tier. Gaps widen up the ladder — plat should take
 * roughly a season of consistent days, not a good week.
 */
export const RANK_THRESHOLDS: Record<RankTier, number> = {
  bronze: 0,
  silver: 100,
  gold: 300,
  plat: 600
};

/** The tier a point total belongs to. Below bronze's floor is still bronze. */
export function tierForPoints(points: number): RankTier {
  const value = Math.max(0, Math.floor(points));
  for (let i = RANK_ORDER.length - 1; i >= 0; i--) {
    if (value >= RANK_THRESHOLDS[RANK_ORDER[i]]) return RANK_ORDER[i];
  }
  return "bronze";
}

export interface RankState {
  rankPoints: number;
  rankTier: RankTier;
}

export type RankDirection = "promotion" | "demotion" | "none";

export interface RankChange {
  direction: RankDirection;
  from: RankTier;
  to: RankTier;
}

/**
 * Apply a point delta (positive for a consistent day, negative for decay or a
 * bad one) and report the resulting state plus whether the tier moved.
 * Points floor at 0; tier always re-derives from points, never stored
 * independently, so a drifted `rankTier` input self-corrects here.
 */
export function applyRankPoints(
  state: RankState,
  delta: number
): { state: RankState; change: RankChange } {
  const from = tierForPoints(state.rankPoints);
  const rankPoints = Math.max(0, state.rankPoints + Math.trunc(delta));
  const to = tierForPoints(rankPoints);

  const direction: RankDirection =
    RANK_ORDER.indexOf(to) > RANK_ORDER.indexOf(from)
      ? "promotion"
      : RANK_ORDER.indexOf(to) < RANK_ORDER.indexOf(from)
        ? "demotion"
        : "none";

  return { state: { rankPoints, rankTier: to }, change: { direction, from, to } };
}

/** Points still needed to reach the next tier, or null at the top. */
export function pointsToNextTier(points: number): number | null {
  const tier = tierForPoints(points);
  const idx = RANK_ORDER.indexOf(tier);
  if (idx === RANK_ORDER.length - 1) return null;
  return RANK_THRESHOLDS[RANK_ORDER[idx + 1]] - Math.max(0, Math.floor(points));
}
