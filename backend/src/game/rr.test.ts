import { describe, it, expect } from "vitest";
import {
  rankForRR,
  rrToNextRank,
  rankedAdjustment,
  rankedDelta,
  applyRankedResult,
  applyTaskRR,
  teamGap,
  matchScore,
  rollRankedCaseRarity,
  TASK_RR_AMOUNT,
  TASK_RR_DAILY_CAP,
  RANKED_CASE_ODDS
} from "./rr";

// Ranked Rating math — spec §5. Iron 0–99 … Diamond 500+; win +20, loss −15,
// adjusted clamp(round(ΔRR/25), ±5); task RR +5 capped +10/day and unable to
// cross a rank boundary; MatchScore = |ΔRR|/100 + TeamGap%.

describe("rankForRR", () => {
  it("maps band edges to the right rank", () => {
    expect(rankForRR(0)).toBe("iron");
    expect(rankForRR(99)).toBe("iron");
    expect(rankForRR(100)).toBe("bronze");
    expect(rankForRR(199)).toBe("bronze");
    expect(rankForRR(200)).toBe("silver");
    expect(rankForRR(300)).toBe("gold");
    expect(rankForRR(400)).toBe("platinum");
    expect(rankForRR(499)).toBe("platinum");
    expect(rankForRR(500)).toBe("diamond");
    expect(rankForRR(9999)).toBe("diamond");
  });

  it("reports the distance to the next band, null at Diamond", () => {
    expect(rrToNextRank(90)).toBe(10);
    expect(rrToNextRank(0)).toBe(100);
    expect(rrToNextRank(500)).toBeNull();
  });
});

describe("ranked deltas", () => {
  it("adjustment is clamp(round(ΔRR/25), −5, +5)", () => {
    expect(rankedAdjustment(100, 100)).toBe(0);
    expect(rankedAdjustment(100, 125)).toBe(1);
    expect(rankedAdjustment(125, 100)).toBe(-1);
    expect(rankedAdjustment(100, 112)).toBe(0); // rounds to 0
    expect(rankedAdjustment(100, 113)).toBe(1); // rounds to 1
    expect(rankedAdjustment(0, 1000)).toBe(5); // clamped
    expect(rankedAdjustment(1000, 0)).toBe(-5); // clamped
  });

  it("win pays 20+Adj, loss pays −15+Adj", () => {
    expect(rankedDelta(100, 100, true)).toBe(20);
    expect(rankedDelta(100, 100, false)).toBe(-15);
    expect(rankedDelta(0, 500, true)).toBe(25);
    expect(rankedDelta(500, 0, false)).toBe(-20);
  });

  it("RR never drops below zero", () => {
    // Formula delta is −15+5 = −10 (big underdog softens the loss); the
    // applied change is −2 because RR floors at 0.
    const r = applyRankedResult(2, 500, false);
    expect(r.rr).toBe(0);
    expect(r.delta).toBe(-10);
  });

  it("flags promotion when the result crosses a boundary", () => {
    const r = applyRankedResult(95, 95, true); // +20 → 115
    expect(r.rr).toBe(115);
    expect(r.rankBefore).toBe("iron");
    expect(r.rankAfter).toBe("bronze");
    expect(r.promoted).toBe(true);
    const stay = applyRankedResult(50, 50, true); // 70, still iron
    expect(stay.promoted).toBe(false);
  });
});

describe("task RR", () => {
  it("pays +5 per eligible task", () => {
    const r = applyTaskRR(50, 0);
    expect(r.applied).toBe(TASK_RR_AMOUNT);
    expect(r.rr).toBe(55);
  });

  it("stops at +10 per day", () => {
    expect(applyTaskRR(50, 0).applied).toBe(5);
    expect(applyTaskRR(55, 5).applied).toBe(5);
    expect(applyTaskRR(60, TASK_RR_DAILY_CAP).applied).toBe(0);
    expect(applyTaskRR(60, TASK_RR_DAILY_CAP).rr).toBe(60);
  });

  it("can fill to the top of the rank but never promote", () => {
    // Iron tops out at 99 — task RR at 97 applies only 2.
    const r = applyTaskRR(97, 0);
    expect(r.applied).toBe(2);
    expect(r.rr).toBe(99);
    expect(rankForRR(r.rr)).toBe("iron");
    // Sitting at the ceiling earns nothing more.
    expect(applyTaskRR(99, 0).applied).toBe(0);
  });

  it("applies the tighter of daily cap and rank ceiling", () => {
    // 1 RR of headroom in the day, 2 to the ceiling → 1.
    expect(applyTaskRR(97, 9).applied).toBe(1);
    // Gold at 395: ceiling 399, full +5 would cross — applies 4.
    const r = applyTaskRR(395, 0);
    expect(r.rr).toBe(399);
    expect(rankForRR(r.rr)).toBe("gold");
  });

  it("Diamond has no ceiling — task RR lands in full", () => {
    const r = applyTaskRR(500, 0);
    expect(r.applied).toBe(5);
    expect(r.rr).toBe(505);
  });
});

describe("SBMM", () => {
  it("teamGap is the normalised absolute difference", () => {
    expect(teamGap(100, 100)).toBe(0);
    expect(teamGap(100, 50)).toBeCloseTo(0.5);
    expect(teamGap(50, 100)).toBeCloseTo(0.5);
    expect(teamGap(0, 0)).toBe(0);
  });

  it("matchScore adds |ΔRR|/100 to the team gap", () => {
    expect(matchScore(100, 100, 1000, 1000)).toBe(0);
    expect(matchScore(100, 200, 1000, 1000)).toBeCloseTo(1);
    expect(matchScore(100, 150, 1000, 500)).toBeCloseTo(0.5 + 0.5);
    // A 100-RR gap costs the same as a 100% team gap — a close-RR pairing
    // with a lopsided team (0.1 + 0.5) beats a far-RR even match (1.0).
    expect(matchScore(0, 10, 100, 50)).toBeLessThan(matchScore(0, 100, 100, 100));
  });
});

describe("ranked case odds", () => {
  it("every rank's odds table sums to 1", () => {
    for (const odds of Object.values(RANKED_CASE_ODDS)) {
      expect(Object.values(odds).reduce((a, b) => a + b, 0)).toBeCloseTo(1, 10);
    }
  });

  it("rolls within the rank's table", () => {
    expect(rollRankedCaseRarity("iron", 0)).toBe("common");
    // Iron: 75% common, so 0.76 lands in uncommon; the last slice is secret.
    expect(rollRankedCaseRarity("iron", 0.76)).toBe("uncommon");
    expect(rollRankedCaseRarity("iron", 0.9999)).toBe("secret");
    expect(rollRankedCaseRarity("diamond", 0.999)).toBe("secret");
  });
});
