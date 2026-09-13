import { describe, it, expect } from "vitest";
import { calculateMultiplier, DayLogEntry, FoodGroup } from "./multiplier";
import { deriveTargets } from "./targets";

const maintainTargets = deriveTargets({
  age: 34,
  sex: "male",
  heightCm: 180,
  weightKg: 80,
  activity: "light",
  goal: "maintain"
});

let clock = 0;
function entry(p: Partial<DayLogEntry> & { barcode: string }): DayLogEntry {
  clock += 5 * 60 * 1000; // 5 min apart by default
  return {
    calories: 0,
    protein: 0,
    fiber: 0,
    sugar: 0,
    microScore: 0,
    foodGroup: "other" as FoodGroup,
    loggedAt: clock,
    ...p
  };
}

describe("daily multiplier (BattleKit port)", () => {
  it("empty day is neutral (1.0)", () => {
    expect(calculateMultiplier([], maintainTargets).total).toBe(1.0);
  });

  it("balanced day scores >= 1.3 (spec)", () => {
    const H = 60 * 60 * 1000; // real meals span the day, so none hit the 3/hour cap
    const day: DayLogEntry[] = [
      { barcode: "a", calories: 500, protein: 45, fiber: 12, sugar: 5, microScore: 0.7, foodGroup: "protein", loggedAt: 8 * H },
      { barcode: "b", calories: 700, protein: 40, fiber: 12, sugar: 8, microScore: 0.6, foodGroup: "produce", loggedAt: 12 * H },
      { barcode: "c", calories: 620, protein: 25, fiber: 8, sugar: 6, microScore: 0.6, foodGroup: "grain", loggedAt: 16 * H },
      { barcode: "d", calories: 600, protein: 20, fiber: 4, sugar: 4, microScore: 0.55, foodGroup: "dairy", loggedAt: 20 * H }
    ];
    const r = calculateMultiplier(day, maintainTargets);
    expect(r.total).toBeGreaterThanOrEqual(1.3);
    expect(r.objectives).toEqual({ protein: true, fiber: true, diversity: true, calories: true });
  });

  it("junk day scores < 1.0", () => {
    clock = 0;
    const day: DayLogEntry[] = [
      entry({ barcode: "x", calories: 250, protein: 4, fiber: 0, sugar: 30, microScore: 0, foodGroup: "other" }),
      entry({ barcode: "y", calories: 250, protein: 4, fiber: 0, sugar: 30, microScore: 0, foodGroup: "other" }),
      entry({ barcode: "z", calories: 250, protein: 4, fiber: 0, sugar: 30, microScore: 0, foodGroup: "other" })
    ];
    expect(calculateMultiplier(day, maintainTargets).total).toBeLessThan(1.0);
  });

  it("clamps into [0.8, 1.5]", () => {
    clock = 0;
    const perfect: DayLogEntry[] = [
      entry({ barcode: "a", calories: 800, protein: 60, fiber: 20, sugar: 2, microScore: 1, foodGroup: "protein" }),
      entry({ barcode: "b", calories: 800, protein: 40, fiber: 15, sugar: 2, microScore: 1, foodGroup: "produce" }),
      entry({ barcode: "c", calories: 820, protein: 30, fiber: 10, sugar: 2, microScore: 1, foodGroup: "grain" })
    ];
    expect(calculateMultiplier(perfect, maintainTargets).total).toBeLessThanOrEqual(1.5);

    const awful: DayLogEntry[] = [
      entry({ barcode: "a", calories: 100, protein: 0, fiber: 0, sugar: 200, microScore: 0, foodGroup: "other" })
    ];
    expect(calculateMultiplier(awful, maintainTargets).total).toBeGreaterThanOrEqual(0.8);
  });

  it("same barcode counts once per day", () => {
    clock = 0;
    const dupes: DayLogEntry[] = [
      entry({ barcode: "same", calories: 500, protein: 40, fiber: 10, sugar: 2, microScore: 0.6, foodGroup: "protein" }),
      entry({ barcode: "same", calories: 500, protein: 40, fiber: 10, sugar: 2, microScore: 0.6, foodGroup: "grain" })
    ];
    const single: DayLogEntry[] = [dupes[0]];
    expect(calculateMultiplier(dupes, maintainTargets).total).toBe(
      calculateMultiplier(single, maintainTargets).total
    );
  });

  it("4th distinct scan within one hour does not count toward the log", () => {
    // 3 produce + 1 grain, all within one hour. The grain (4th) is dropped, so
    // diversity stays at a single food group (0.04), not two (0.08).
    const base = 1_000_000;
    const day: DayLogEntry[] = [
      { barcode: "p1", calories: 100, protein: 5, fiber: 2, sugar: 1, microScore: 0.5, foodGroup: "produce", loggedAt: base },
      { barcode: "p2", calories: 100, protein: 5, fiber: 2, sugar: 1, microScore: 0.5, foodGroup: "produce", loggedAt: base + 600_000 },
      { barcode: "p3", calories: 100, protein: 5, fiber: 2, sugar: 1, microScore: 0.5, foodGroup: "produce", loggedAt: base + 1_200_000 },
      { barcode: "g1", calories: 100, protein: 5, fiber: 2, sugar: 1, microScore: 0.5, foodGroup: "grain", loggedAt: base + 1_800_000 }
    ];
    expect(calculateMultiplier(day, maintainTargets).diversity).toBeCloseTo(0.04, 10);
  });
});
