import { describe, it, expect } from "vitest";
import { computeBaseStats, computeMicroScore, elementFromStats } from "./baseStats";

describe("base stats (BATTLE-SYSTEM §2)", () => {
  it("applies each formula and clamps to 10..100", () => {
    // protein 10 -> power 60; fiber 8 -> guard 60; micro 0.5 -> vitality 42.5->43
    const s = computeBaseStats({ proteinG: 10, fiberG: 8, sugarG: 5, microScore: 0.5 });
    expect(s.power).toBe(60);
    expect(s.guard).toBe(60);
    expect(s.vitality).toBe(43);
    // tempo = 20 + (10/5)*10 + (50-5)*0.6 = 20 + 20 + 27 = 67
    expect(s.tempo).toBe(67);
  });

  it("clamps high protein to 100 and low inputs to 10", () => {
    expect(computeBaseStats({ proteinG: 90, fiberG: 0, sugarG: 0, microScore: 0 }).power).toBe(100);
    // very high sugar drives tempo below 10 -> clamp 10
    expect(computeBaseStats({ proteinG: 0, fiberG: 0, sugarG: 200, microScore: 0 }).tempo).toBe(10);
  });

  it("element is the dominant stat's type", () => {
    expect(elementFromStats({ power: 90, guard: 10, vitality: 10, tempo: 10 })).toBe("protein");
    expect(elementFromStats({ power: 10, guard: 90, vitality: 10, tempo: 10 })).toBe("fiber");
    expect(elementFromStats({ power: 10, guard: 10, vitality: 90, tempo: 10 })).toBe("vitamin");
    expect(elementFromStats({ power: 10, guard: 10, vitality: 10, tempo: 90 })).toBe("hydration");
  });

  it("micro score counts distinct micronutrients present (0..1)", () => {
    expect(computeMicroScore(null)).toBe(0);
    expect(computeMicroScore({ proteins_100g: 5 })).toBe(0);
    // 3 of 6 present -> 0.5
    expect(
      computeMicroScore({ "vitamin-c_100g": 12, iron_100g: 2, calcium_100g: 30, sugars_100g: 4 })
    ).toBe(0.5);
    // all six present -> 1
    expect(
      computeMicroScore({
        "vitamin-c_100g": 1,
        "vitamin-a_100g": 1,
        iron_100g: 1,
        calcium_100g: 1,
        potassium_100g: 1,
        "vitamin-b12_100g": 1
      })
    ).toBe(1);
  });
});
