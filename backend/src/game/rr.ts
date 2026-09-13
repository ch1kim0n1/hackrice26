// Ranked Rating (RR) — spec §5. Replaces the old consistency RP ladder
// (rankTiers.ts / rankPoints.ts / rankSeason.ts), Elo, and squad fatigue:
// one rating, six named ranks, adjusted win/loss deltas, and a capped
// task-RR drip that can never promote you.
//
//   RRDifference = OpponentRR - PlayerRR
//   Adjustment   = clamp(round(RRDifference / 25), -5, +5)
//   Win          = +20 + Adjustment
//   Loss         = -15 + Adjustment
//
//   Task RR      = +5 per eligible task, max +10 per UTC day, and it can
//                  only take you to the top of your current rank — crossing
//                  a boundary requires a ranked win.
//
// All constants live in game/spec.ts (the Phase-0 contract); this file is
// the math and nothing else.

import { Rarity } from "../types";
import {
  RANKS as SPEC_RANKS,
  Rank as RankId,
  RR_WIN_BASE,
  RR_LOSS_BASE,
  RR_ADJUST_STEP,
  RR_ADJUST_CAP,
  TASK_RR_AMOUNT,
  TASK_RR_DAILY_CAP,
  SBMM_ATTACK_WEIGHT,
  SBMM_RR_SCALE,
  RANKED_CASE_ODDS
} from "./spec";

export type { RankId };

export { RR_WIN_BASE, RR_LOSS_BASE, RR_ADJUST_STEP, RR_ADJUST_CAP };
export { TASK_RR_AMOUNT, TASK_RR_DAILY_CAP, SBMM_ATTACK_WEIGHT, SBMM_RR_SCALE };
export { RANKED_CASE_ODDS };

export const RANK_LABELS: Record<RankId, string> = {
  iron: "Iron",
  bronze: "Bronze",
  silver: "Silver",
  gold: "Gold",
  platinum: "Platinum",
  diamond: "Diamond"
};

/** The rank an RR total sits in (Diamond is unbounded above). */
export function rankForRR(rr: number): RankId {
  let rank: RankId = SPEC_RANKS[0].rank;
  for (const r of SPEC_RANKS) if (rr >= r.minRR) rank = r.rank;
  return rank;
}

const rankIndex = (rank: RankId): number => SPEC_RANKS.findIndex((r) => r.rank === rank);

/** RR needed to reach the next rank; null at Diamond (no rank above). */
export function rrToNextRank(rr: number): number | null {
  const idx = rankIndex(rankForRR(rr));
  if (idx === SPEC_RANKS.length - 1) return null;
  return SPEC_RANKS[idx + 1].minRR - rr;
}

export function rankedAdjustment(playerRR: number, opponentRR: number): number {
  const raw = Math.round((opponentRR - playerRR) / RR_ADJUST_STEP);
  return Math.max(-RR_ADJUST_CAP, Math.min(RR_ADJUST_CAP, raw));
}

/** The RR delta a ranked result applies (before the 0 floor). */
export function rankedDelta(playerRR: number, opponentRR: number, won: boolean): number {
  const adj = rankedAdjustment(playerRR, opponentRR);
  return won ? RR_WIN_BASE + adj : RR_LOSS_BASE + adj;
}

export interface RankedResult {
  delta: number;
  rr: number;
  rankBefore: RankId;
  rankAfter: RankId;
  promoted: boolean;
}

/** Apply a ranked battle outcome to a rating. RR never goes below 0. */
export function applyRankedResult(playerRR: number, opponentRR: number, won: boolean): RankedResult {
  const delta = rankedDelta(playerRR, opponentRR, won);
  const rr = Math.max(0, playerRR + delta);
  return {
    delta,
    rr,
    rankBefore: rankForRR(playerRR),
    rankAfter: rankForRR(rr),
    promoted: rankIndex(rankForRR(rr)) > rankIndex(rankForRR(playerRR))
  };
}

/**
 * Task RR: +5, capped at +10/day, and it can fill the current rank but never
 * cross into the next one — promotion requires a ranked win. `earnedToday`
 * is the task-RR already applied this UTC day. The applied amount can be
 * less than 5 (daily cap or the top of the current rank) or 0.
 */
export function applyTaskRR(playerRR: number, earnedToday: number): { applied: number; rr: number } {
  const headroom = Math.max(0, TASK_RR_DAILY_CAP - earnedToday);
  const rank = rankForRR(playerRR);
  const idx = rankIndex(rank);
  // The top of the current rank is one point below the next floor; Diamond
  // has no ceiling so task RR lands in full there.
  const ceiling = idx === SPEC_RANKS.length - 1 ? Infinity : SPEC_RANKS[idx + 1].minRR - 1;
  const applied = Math.min(TASK_RR_AMOUNT, headroom, Math.max(0, ceiling - playerRR));
  return { applied, rr: playerRR + applied };
}

// ---------------------------------------------------------------------------
// SBMM (spec §5) — replaces exact-tier matchmaking.
//
//   MonsterPower = EffectiveHealth + EffectiveAttack * AttackWeight
//   TeamGap%     = |PowerA - PowerB| / max(PowerA, PowerB)
//   MatchScore   = |RRA - RRB| / 100 + TeamGap%
// ---------------------------------------------------------------------------

export function teamGap(powerA: number, powerB: number): number {
  const denom = Math.max(powerA, powerB);
  return denom > 0 ? Math.abs(powerA - powerB) / denom : 0;
}

export function matchScore(rrA: number, rrB: number, powerA: number, powerB: number): number {
  return Math.abs(rrA - rrB) / SBMM_RR_SCALE + teamGap(powerA, powerB);
}

// ---------------------------------------------------------------------------
// Ranked Case rewards (spec §5): a ranked win rolls a Case rarity off the
// winner's rank table. Losses pay nothing.
// ---------------------------------------------------------------------------

/** Roll a Case rarity for a rank; `v` is a uniform float in [0,1). */
export function rollRankedCaseRarity(rank: RankId, v: number): Rarity {
  const odds = RANKED_CASE_ODDS[rank];
  let acc = 0;
  for (const rarity of Object.keys(odds) as Rarity[]) {
    acc += odds[rarity];
    if (v < acc) return rarity;
  }
  return "common";
}
