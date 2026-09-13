import { describe, it, expect } from "vitest";
import { eloDelta, tierFor, expectedScore } from "./elo";

describe("elo", () => {
  it("1000 vs 1000, win -> +16 (spec vector)", () => {
    expect(eloDelta(1000, 1000, 1)).toBe(16);
  });

  it("1000 vs 1000, loss -> -16", () => {
    expect(eloDelta(1000, 1000, 0)).toBe(-16);
  });

  it("even match draw -> 0", () => {
    expect(eloDelta(1000, 1000, 0.5)).toBe(0);
  });

  it("underdog win gains more than favorite win", () => {
    const underdog = eloDelta(1000, 1400, 1);
    const favorite = eloDelta(1400, 1000, 1);
    expect(underdog).toBeGreaterThan(favorite);
    expect(underdog + favorite).toBeCloseTo(32, 0); // symmetric expectations
  });

  it("expected scores sum to 1", () => {
    expect(expectedScore(1200, 1000) + expectedScore(1000, 1200)).toBeCloseTo(1, 10);
  });

  it("tier thresholds", () => {
    expect(tierFor(1099)).toBe("Bronze");
    expect(tierFor(1100)).toBe("Silver");
    expect(tierFor(1299)).toBe("Silver");
    expect(tierFor(1300)).toBe("Gold");
    expect(tierFor(1499)).toBe("Gold");
    expect(tierFor(1500)).toBe("Platinum");
    expect(tierFor(1699)).toBe("Platinum");
    expect(tierFor(1700)).toBe("Diamond");
  });
});
