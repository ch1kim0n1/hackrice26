// Ranked Elo — port of docs/BATTLE-SYSTEM.md §5 and the DB `elo_delta()` /
// `tier_for()` functions. K = 32, start 1000.

export type Tier = "Bronze" | "Silver" | "Gold" | "Platinum" | "Diamond";

export const K_FACTOR = 32;

/** Expected score of A against B. */
export function expectedScore(ratingA: number, ratingB: number): number {
  return 1 / (1 + Math.pow(10, (ratingB - ratingA) / 400));
}

/**
 * Rating delta for A. scoreA: 1 win / 0.5 draw / 0 loss.
 * 1000 vs 1000, win -> +16.
 */
export function eloDelta(ratingA: number, ratingB: number, scoreA: number): number {
  return Math.round(K_FACTOR * (scoreA - expectedScore(ratingA, ratingB)));
}

/** Bronze <1100, Silver <1300, Gold <1500, Platinum <1700, Diamond >=1700. */
export function tierFor(rating: number): Tier {
  if (rating < 1100) return "Bronze";
  if (rating < 1300) return "Silver";
  if (rating < 1500) return "Gold";
  if (rating < 1700) return "Platinum";
  return "Diamond";
}
