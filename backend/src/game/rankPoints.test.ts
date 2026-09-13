import { describe, expect, it } from "vitest";
import { awardCapped, RP_DAILY_CAP, RP_PER_QUEST, RP_PER_SCAN } from "./rankPoints";

const base = { rankPoints: 0, rankTier: "bronze" as const };

describe("awardCapped", () => {
  it("awards up to the daily cap", () => {
    const r = awardCapped(base, 0, RP_PER_QUEST);
    expect(r.state.rankPoints).toBe(10);
    expect(r.earnedToday).toBe(10);
  });

  it("truncates at the cap, never above", () => {
    const r = awardCapped(base, RP_DAILY_CAP - 5, RP_PER_QUEST);
    expect(r.state.rankPoints).toBe(5);
    expect(r.earnedToday).toBe(RP_DAILY_CAP);
  });

  it("a capped day earns nothing more", () => {
    const r = awardCapped(base, RP_DAILY_CAP, RP_PER_SCAN);
    expect(r.state.rankPoints).toBe(0);
    expect(r.earnedToday).toBe(RP_DAILY_CAP);
  });

  it("losses bypass the cap", () => {
    const r = awardCapped({ rankPoints: 120, rankTier: "silver" }, RP_DAILY_CAP, -10);
    expect(r.state.rankPoints).toBe(110);
    expect(r.state.rankTier).toBe("silver");
    expect(r.earnedToday).toBe(RP_DAILY_CAP);
  });

  it("reports promotions on cap-crossing awards", () => {
    const r = awardCapped({ rankPoints: 95, rankTier: "bronze" }, 0, 10);
    expect(r.change.direction).toBe("promotion");
    expect(r.state.rankTier).toBe("silver");
  });
});
