// Rank point accrual (issue #83). The consistency ladder: every day of
// balanced eating moves you toward the next tier (rankTiers.ts). Award paths
// are event-driven — a quest claim, a scan — and each source is idempotent
// upstream (quest_claim PK, scan_seen PK), so awarding here can never
// double-count a day.
//
// Amounts are deliberately flat numbers, not fractions of a goal: rank is a
// habit ladder, and a habit ladder pays for showing up.

import { applyRankPoints, RankChange, RankState } from "./rankTiers";

/** RP per completed daily quest. */
export const RP_PER_QUEST = 10;
/** RP per unique food scan. */
export const RP_PER_SCAN = 5;
/** RP cap per UTC day across all sources — a perfect day tops out here. */
export const RP_DAILY_CAP = 40;
/** RP bonus for a ranked battle win (applied by the ranked route). */
export const RP_RANKED_WIN = 15;
/** RP cost of a ranked loss. */
export const RP_RANKED_LOSS = -10;

/**
 * Apply an award through the daily cap. `earnedToday` is RP already granted
 * under the same UTC day; the caller owns that counter (persisted per player).
 * Returns the actually-applied delta and the resulting state + tier change.
 */
export function awardCapped(
  state: RankState,
  earnedToday: number,
  rawDelta: number
): { state: RankState; earnedToday: number; change: RankChange } {
  const room = Math.max(0, RP_DAILY_CAP - earnedToday);
  const delta = rawDelta > 0 ? Math.min(rawDelta, room) : rawDelta; // losses ignore the cap
  const { state: next, change } = applyRankPoints(state, delta);
  return { state: next, earnedToday: earnedToday + Math.max(0, delta), change };
}
