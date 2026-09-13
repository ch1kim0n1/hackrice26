import { describe, expect, it } from "vitest";
import {
  calorieDensityOf,
  densityBandFor,
  densityTempoShift,
  mapNutrition
} from "./nutritionStats";
import { computeBaseStats } from "./baseStats";

// protein 8 / sugar 15 keeps canonical tempo at ~46 — below the 100 cap,
// so the density overlay is actually observable in tests.
const CHICKEN_RICE = { proteinG: 8, fiberG: 4, sugarG: 15, microScore: 0.5, calories: 480, portionG: 350 };

describe("calorieDensityOf / densityBandFor", () => {
  it("kcal per gram", () => {
    expect(calorieDensityOf(480, 350)).toBeCloseTo(1.371, 3);
  });

  it("null when either input missing or non-positive", () => {
    expect(calorieDensityOf(undefined, 350)).toBeNull();
    expect(calorieDensityOf(480, undefined)).toBeNull();
    expect(calorieDensityOf(480, 0)).toBeNull();
    expect(calorieDensityOf(NaN, 100)).toBeNull();
  });

  it("bands: produce light, burger balanced, chocolate dense", () => {
    expect(densityBandFor(0.4)).toBe("light");
    expect(densityBandFor(2.9)).toBe("balanced");
    expect(densityBandFor(5.5)).toBe("dense");
  });
});

describe("densityTempoShift", () => {
  it("neutral at 2.0 kcal/g, positive below, negative above", () => {
    expect(densityTempoShift(2.0)).toBe(0);
    expect(densityTempoShift(1.0)).toBeCloseTo(6);
    expect(densityTempoShift(3.0)).toBeCloseTo(-6);
  });

  it("capped at ±12 and zero when density unknown", () => {
    expect(densityTempoShift(0)).toBe(12); // floor of the band range
    expect(densityTempoShift(9)).toBe(-12); // capped: olive oil territory
    expect(densityTempoShift(null)).toBe(0);
  });
});

describe("mapNutrition", () => {
  it("matches the canonical formula when density is absent", () => {
    const canonical = computeBaseStats({ proteinG: 8, fiberG: 4, sugarG: 15, microScore: 0.5 });
    const out = mapNutrition({ proteinG: 8, fiberG: 4, sugarG: 15, microScore: 0.5 });
    expect(out.stats).toEqual(canonical);
    expect(out.calorieDensity).toBeNull();
    expect(out.tempoShift).toBe(0);
  });

  it("light food lifts tempo, dense food drops it", () => {
    const canonical = computeBaseStats({ proteinG: 8, fiberG: 4, sugarG: 15, microScore: 0.5 });
    const light = mapNutrition(CHICKEN_RICE); // ~1.37 kcal/g
    const dense = mapNutrition({ ...CHICKEN_RICE, calories: 1900, portionG: 350 }); // ~5.4 kcal/g
    expect(light.stats.tempo).toBeGreaterThan(canonical.tempo);
    expect(dense.stats.tempo).toBeLessThan(canonical.tempo);
    expect(light.densityBand).toBe("light");
    expect(dense.densityBand).toBe("dense");
  });

  it("derives microScore from the micronutrient list when no scalar given", () => {
    const out = mapNutrition({
      proteinG: 10,
      fiberG: 5,
      sugarG: 5,
      micronutrients: ["vitamin-c", "iron", "potassium"]
    });
    expect(out.microScore).toBeCloseTo(0.5, 4); // 3 of 6
  });

  it("element follows the dominant stat", () => {
    const proteinMeal = mapNutrition({ proteinG: 40, fiberG: 1, sugarG: 1, microScore: 0.1 });
    expect(proteinMeal.element).toBe("protein");
  });

  it("is deterministic and stats stay within 10..100", () => {
    const a = mapNutrition(CHICKEN_RICE);
    const b = mapNutrition(CHICKEN_RICE);
    expect(a).toEqual(b);
    for (const v of Object.values(a.stats)) {
      expect(v).toBeGreaterThanOrEqual(10);
      expect(v).toBeLessThanOrEqual(100);
    }
  });
});
