import { describe, it, expect } from "vitest";
import {
  caloriesFromMacros,
  computeTotals,
  dominantFoodGroup,
  microScoreFor,
  per100g,
  scaleItem
} from "./totals";
import { DishItem } from "./types";

function item(overrides: Partial<DishItem> & { id: string }): DishItem {
  return {
    name: "Food",
    portionG: 100,
    portionLabel: "~100 g",
    calories: 100,
    proteinG: 5,
    carbsG: 10,
    fatG: 3,
    fiberG: 2,
    sugarG: 1,
    sodiumMg: 50,
    micronutrients: [],
    foodGroup: "other",
    confidence: 0.8,
    ...overrides
  };
}

describe("caloriesFromMacros", () => {
  it("uses Atwater factors (4/4/9)", () => {
    expect(caloriesFromMacros(10, 20, 5)).toBe(10 * 4 + 20 * 4 + 5 * 9);
  });
});

describe("scaleItem", () => {
  it("doubles every nutrient when the portion doubles", () => {
    const scaled = scaleItem(item({ id: "i0" }), 200);
    expect(scaled.portionG).toBe(200);
    expect(scaled.calories).toBe(200);
    expect(scaled.proteinG).toBe(10);
    expect(scaled.carbsG).toBe(20);
    expect(scaled.fatG).toBe(6);
    expect(scaled.fiberG).toBe(4);
    expect(scaled.sugarG).toBe(2);
    expect(scaled.sodiumMg).toBe(100);
  });

  it("holds nutrient density constant (the anti-cheat property)", () => {
    const original = item({ id: "i0", portionG: 160, calories: 264, proteinG: 49 });
    const scaled = scaleItem(original, 80);
    expect(scaled.calories / scaled.portionG).toBeCloseTo(original.calories / original.portionG, 6);
    expect(scaled.proteinG / scaled.portionG).toBeCloseTo(original.proteinG / original.portionG, 6);
  });

  it("scaling to zero zeroes the nutrients without dividing by zero", () => {
    const scaled = scaleItem(item({ id: "i0", portionG: 0 }), 0);
    expect(scaled.calories).toBe(0);
    expect(Number.isFinite(scaled.proteinG)).toBe(true);
  });

  it("keeps name and food group untouched", () => {
    const scaled = scaleItem(item({ id: "i0", name: "Rice", foodGroup: "grain" }), 250);
    expect(scaled.name).toBe("Rice");
    expect(scaled.foodGroup).toBe("grain");
  });
});

describe("microScoreFor", () => {
  it("is the share of the six tracked micronutrients", () => {
    expect(microScoreFor([])).toBe(0);
    expect(microScoreFor(["iron", "calcium", "vitamin-c"])).toBe(0.5);
    expect(
      microScoreFor(["iron", "calcium", "vitamin-c", "vitamin-a", "vitamin-b12", "potassium"])
    ).toBe(1);
  });

  it("ignores duplicates", () => {
    expect(microScoreFor(["iron", "iron", "iron"])).toBeCloseTo(1 / 6, 3);
  });
});

describe("dominantFoodGroup", () => {
  it("picks the group contributing the most calories", () => {
    const items = [
      item({ id: "i0", foodGroup: "grain", calories: 400 }),
      item({ id: "i1", foodGroup: "protein", calories: 700 }),
      item({ id: "i2", foodGroup: "produce", calories: 60 })
    ];
    expect(dominantFoodGroup(items)).toBe("protein");
  });

  it("sums groups that appear more than once", () => {
    const items = [
      item({ id: "i0", foodGroup: "produce", calories: 300 }),
      item({ id: "i1", foodGroup: "produce", calories: 300 }),
      item({ id: "i2", foodGroup: "protein", calories: 500 })
    ];
    expect(dominantFoodGroup(items)).toBe("produce");
  });

  it("falls back to mass on a zero-calorie plate", () => {
    const items = [
      item({ id: "i0", foodGroup: "produce", calories: 0, portionG: 20 }),
      item({ id: "i1", foodGroup: "dairy", calories: 0, portionG: 300 })
    ];
    expect(dominantFoodGroup(items)).toBe("dairy");
  });

  it("returns 'other' for an empty plate", () => {
    expect(dominantFoodGroup([])).toBe("other");
  });
});

describe("computeTotals", () => {
  const items = [
    item({ id: "i0", foodGroup: "protein", portionG: 160, calories: 264, proteinG: 49, fiberG: 0, micronutrients: ["iron", "potassium"] }),
    item({ id: "i1", foodGroup: "grain", portionG: 160, calories: 208, proteinG: 4, fiberG: 1, micronutrients: ["iron"] }),
    item({ id: "i2", foodGroup: "produce", portionG: 90, calories: 31, proteinG: 2, fiberG: 3, micronutrients: ["vitamin-c"] })
  ];

  it("sums portions and nutrients across items", () => {
    const t = computeTotals(items);
    expect(t.portionG).toBe(410);
    expect(t.calories).toBe(503);
    expect(t.proteinG).toBe(55);
    expect(t.fiberG).toBe(4);
  });

  it("unions micronutrients and derives the micro score", () => {
    const t = computeTotals(items);
    expect(new Set(t.micronutrients)).toEqual(new Set(["iron", "potassium", "vitamin-c"]));
    expect(t.microScore).toBe(0.5); // 3 of 6
  });

  it("lists distinct food groups for the diversity signal", () => {
    const t = computeTotals(items);
    expect(new Set(t.foodGroups)).toEqual(new Set(["protein", "grain", "produce"]));
    expect(t.dominantFoodGroup).toBe("protein");
  });

  it("returns zeroes for an empty plate", () => {
    const t = computeTotals([]);
    expect(t.calories).toBe(0);
    expect(t.microScore).toBe(0);
    expect(t.foodGroups).toEqual([]);
  });
});

describe("per100g", () => {
  it("converts plate totals using the estimated portion weight", () => {
    // 500 g plate, 100 g protein -> 20 g per 100 g
    const totals = computeTotals([
      item({ id: "i0", portionG: 500, calories: 1000, proteinG: 100, fiberG: 25, sugarG: 5, carbsG: 50, fatG: 10 })
    ]);
    const p = per100g(totals);
    expect(p.proteins_100g).toBe(20);
    expect(p.fiber_100g).toBe(5);
    expect(p["energy-kcal_100g"]).toBe(200);
  });

  it("does not divide by zero on a weightless plate", () => {
    const totals = computeTotals([item({ id: "i0", portionG: 0, calories: 0, proteinG: 0 })]);
    const p = per100g(totals);
    expect(Number.isFinite(p.proteins_100g)).toBe(true);
  });
});
