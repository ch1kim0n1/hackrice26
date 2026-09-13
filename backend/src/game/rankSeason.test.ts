import { describe, it, expect } from "vitest";
import { seasonNumber, rollSeason, SEASON_TIER_REWARD } from "./rankSeason";

describe("rankSeason — 7-day rollover (BATTLE-SYSTEM §7)", () => {
  const s0Start = Date.parse("2025-01-06T00:00:00Z");
  const s0Mid = s0Start + 3 * 24 * 60 * 60 * 1000;
  const s1Start = s0Start + 7 * 24 * 60 * 60 * 1000;
  const s2Start = s1Start + 7 * 24 * 60 * 60 * 1000;

  it("numbers seasons in fixed 7-day blocks from the epoch", () => {
    expect(seasonNumber(s0Start)).toBe(0);
    expect(seasonNumber(s0Mid)).toBe(0);
    expect(seasonNumber(s1Start)).toBe(1);
    expect(seasonNumber(s2Start)).toBe(2);
  });

  it("a brand new player (storedSeason null) is seeded with no reward or decay", () => {
    const r = rollSeason(null, 250, s0Mid);
    expect(r).toEqual({ rankPoints: 250, season: 0, reward: 0, tierAtClose: "silver" });
  });

  it("no rollover mid-season: points and reward untouched", () => {
    const r = rollSeason(0, 250, s0Mid);
    expect(r).toEqual({ rankPoints: 250, season: 0, reward: 0, tierAtClose: "silver" });
  });

  it("crossing a season boundary decays 20% and pays the tier reward", () => {
    const r = rollSeason(0, 250, s1Start);
    expect(r.season).toBe(1);
    expect(r.tierAtClose).toBe("silver");
    expect(r.reward).toBe(SEASON_TIER_REWARD.silver);
    expect(r.rankPoints).toBe(200); // floor(250 * 0.8)
  });

  it("pays the plat reward for a plat-tier close", () => {
    const r = rollSeason(0, 900, s1Start);
    expect(r.tierAtClose).toBe("plat");
    expect(r.reward).toBe(SEASON_TIER_REWARD.plat);
    expect(r.rankPoints).toBe(720);
  });

  it("skipping multiple seasons still only rolls over once", () => {
    const r = rollSeason(0, 250, s2Start);
    expect(r.season).toBe(2);
    expect(r.reward).toBe(SEASON_TIER_REWARD.silver);
    expect(r.rankPoints).toBe(200); // same single decay as a one-season gap, not compounded
  });

  it("floors at 0 points cleanly", () => {
    const r = rollSeason(0, 0, s1Start);
    expect(r.rankPoints).toBe(0);
    expect(r.tierAtClose).toBe("bronze");
    expect(r.reward).toBe(SEASON_TIER_REWARD.bronze);
  });
});
