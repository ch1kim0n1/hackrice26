// Ranked season rollover (docs/BATTLE-SYSTEM.md §7: "Ranked season: 7 days,
// tier rewards ... RP soft-reset 20% toward base").
//
// Seasons are numbered from a fixed epoch, the same trick todayKey() uses for
// daily quests (game/quests.ts): no server-side scheduler or cron is needed to
// know which season is current, and no season needs to be "created" ahead of
// time. A player's stored `rankSeason` is just the last season number they
// were reconciled against; awardRankPoints() reconciles it lazily whenever RP
// next moves, the same way rankDay/rankEarnedToday reconcile per UTC day.
//
// Scope note: Postgres already has unused app.seasons / app.rankings /
// app.season_reward_claims tables from an earlier design pass (0005). This
// module intentionally does not wire into them -- SQLite is the source of
// truth for gameplay today (see CLAUDE.md), and standing up a second,
// currently-dormant season lifecycle in Postgres is a separate migration
// project, not part of this pass.

import { RankTier, tierForPoints } from "./rankTiers";

/** A Monday. Arbitrary but fixed -- only the cadence from here matters. */
const SEASON_EPOCH_MS = Date.parse("2025-01-06T00:00:00Z");
const SEASON_MS = 7 * 24 * 60 * 60 * 1000;

/** The season number in effect at `now`. Seasons never overlap or gap. */
export function seasonNumber(now: number): number {
  return Math.floor((now - SEASON_EPOCH_MS) / SEASON_MS);
}

/** Capsule keys paid out for the tier held when a season closes. */
export const SEASON_TIER_REWARD: Record<RankTier, number> = {
  bronze: 1,
  silver: 2,
  gold: 4,
  plat: 8
};

/** Fraction of RP kept across a season boundary; the rest resets toward 0. */
const SEASON_CARRYOVER = 0.8;

export interface SeasonRollover {
  /** RP after rollover -- unchanged if no boundary was crossed. */
  rankPoints: number;
  /** The season number `now` falls in. */
  season: number;
  /** Keys to grant for this rollover; 0 when no season boundary was crossed. */
  reward: number;
  /** Tier the player held going into the rollover (for reward + display). */
  tierAtClose: RankTier;
}

/**
 * Reconcile a stored (season, points) pair against `now`. Idempotent: called
 * again before the next boundary, it returns the input unchanged with
 * reward 0.
 *
 * A player who skips several seasons entirely still only rolls over once --
 * one soft-reset and one reward, not one per missed week. Compounding the
 * decay for absence would punish returning players far harder than the
 * design intends ("a habit ladder pays for showing up", rankPoints.ts).
 *
 * `storedSeason: null` means the profile has never been stamped (brand new
 * player) -- it is seeded to the current season with no reward or decay,
 * since there was no prior season to close out.
 */
export function rollSeason(storedSeason: number | null, rankPoints: number, now: number): SeasonRollover {
  const current = seasonNumber(now);
  const tierAtClose = tierForPoints(rankPoints);

  if (storedSeason === current) {
    return { rankPoints, season: current, reward: 0, tierAtClose };
  }
  if (storedSeason === null) {
    return { rankPoints, season: current, reward: 0, tierAtClose };
  }

  return {
    rankPoints: Math.floor(rankPoints * SEASON_CARRYOVER),
    season: current,
    reward: SEASON_TIER_REWARD[tierAtClose],
    tierAtClose
  };
}
