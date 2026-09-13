import { describe, expect, it } from "vitest";
import {
  applyRankPoints,
  pointsToNextTier,
  tierForPoints,
  RANK_ORDER,
  RANK_THRESHOLDS
} from "./rankTiers";

describe("tierForPoints", () => {
  it("floors at bronze", () => {
    expect(tierForPoints(0)).toBe("bronze");
    expect(tierForPoints(-50)).toBe("bronze");
  });

  it("crosses each threshold exactly at the floor", () => {
    expect(tierForPoints(RANK_THRESHOLDS.silver - 1)).toBe("bronze");
    expect(tierForPoints(RANK_THRESHOLDS.silver)).toBe("silver");
    expect(tierForPoints(RANK_THRESHOLDS.gold)).toBe("gold");
    expect(tierForPoints(RANK_THRESHOLDS.plat)).toBe("plat");
    expect(tierForPoints(RANK_THRESHOLDS.plat + 10_000)).toBe("plat");
  });
});

describe("applyRankPoints", () => {
  it("promotes on crossing a floor", () => {
    const { state, change } = applyRankPoints({ rankPoints: 95, rankTier: "bronze" }, 10);
    expect(state.rankPoints).toBe(105);
    expect(state.rankTier).toBe("silver");
    expect(change).toEqual({ direction: "promotion", from: "bronze", to: "silver" });
  });

  it("demotes on negative delta crossing a floor", () => {
    const { change } = applyRankPoints({ rankPoints: 105, rankTier: "silver" }, -10);
    expect(change).toEqual({ direction: "demotion", from: "silver", to: "bronze" });
  });

  it("can jump multiple tiers in one award", () => {
    const { change } = applyRankPoints({ rankPoints: 0, rankTier: "bronze" }, 650);
    expect(change).toEqual({ direction: "promotion", from: "bronze", to: "plat" });
  });

  it("reports none within a tier", () => {
    const { change } = applyRankPoints({ rankPoints: 50, rankTier: "bronze" }, 20);
    expect(change.direction).toBe("none");
  });

  it("never goes below zero points", () => {
    const { state } = applyRankPoints({ rankPoints: 30, rankTier: "bronze" }, -500);
    expect(state.rankPoints).toBe(0);
    expect(state.rankTier).toBe("bronze");
  });

  it("self-corrects a drifted stored tier", () => {
    const { state } = applyRankPoints({ rankPoints: 400, rankTier: "bronze" }, 0);
    expect(state.rankTier).toBe("gold");
  });
});

describe("pointsToNextTier", () => {
  it("returns the gap to the next floor", () => {
    expect(pointsToNextTier(95)).toBe(5);
    expect(pointsToNextTier(0)).toBe(100);
  });

  it("returns null at the top", () => {
    expect(pointsToNextTier(RANK_THRESHOLDS.plat)).toBeNull();
  });
});

describe("ladder", () => {
  it("thresholds are strictly ascending in rank order", () => {
    for (let i = 1; i < RANK_ORDER.length; i++) {
      expect(RANK_THRESHOLDS[RANK_ORDER[i]]).toBeGreaterThan(RANK_THRESHOLDS[RANK_ORDER[i - 1]]);
    }
  });
});
