import { describe, it, expect } from "vitest";
import { applyEdits, parseEdits } from "./edits";
import { normalizeAnalysis } from "./analyze";
import { NotFoodError } from "./types";

const PLATE = normalizeAnalysis({
  dishName: "Chicken and rice",
  items: [
    { name: "Chicken", portionGrams: 160, calories: 264, proteinG: 49, carbsG: 0, fatG: 6, foodGroup: "protein" },
    { name: "Rice", portionGrams: 160, calories: 208, proteinG: 4, carbsG: 45, fatG: 0.4, foodGroup: "grain" },
    { name: "Broccoli", portionGrams: 90, calories: 31, proteinG: 2.6, carbsG: 6, fatG: 0.3, fiberG: 2.4, foodGroup: "produce" }
  ]
}, "plate-1");

describe("parseEdits", () => {
  it("keeps well-formed edits", () => {
    expect(parseEdits([{ id: "i0", portionG: 80, name: "Chicken thigh" }])).toEqual([
      { id: "i0", name: "Chicken thigh", portionG: 80 }
    ]);
  });

  it("ignores entries without an id", () => {
    expect(parseEdits([{ portionG: 80 }, "junk", null, 42])).toEqual([]);
  });

  it("clamps an absurd portion instead of rejecting the whole payload", () => {
    const [edit] = parseEdits([{ id: "i0", portionG: 10_000_000 }]);
    expect(edit.portionG).toBeLessThanOrEqual(2000);
  });

  it("drops a non-numeric portion", () => {
    const [edit] = parseEdits([{ id: "i0", portionG: "lots" }]);
    expect(edit.portionG).toBeUndefined();
  });

  it("returns nothing for a non-array body", () => {
    expect(parseEdits({ id: "i0" })).toEqual([]);
    expect(parseEdits(undefined)).toEqual([]);
  });
});

describe("applyEdits", () => {
  it("leaves the plate untouched when there are no edits", () => {
    const result = applyEdits(PLATE, []);
    expect(result.items).toHaveLength(3);
    expect(result.totals.calories).toBe(PLATE.totals.calories);
  });

  it("rescales an item when the user corrects the portion", () => {
    const result = applyEdits(PLATE, [{ id: "i0", portionG: 80 }]);
    const chicken = result.items.find((i) => i.id === "i0")!;
    expect(chicken.portionG).toBe(80);
    expect(chicken.calories).toBe(132); // half of 264
    expect(chicken.proteinG).toBeCloseTo(24.5, 1);
  });

  it("recomputes plate totals after a portion edit", () => {
    const result = applyEdits(PLATE, [{ id: "i0", portionG: 80 }]);
    expect(result.totals.calories).toBe(PLATE.totals.calories - 132);
    expect(result.totals.portionG).toBe(PLATE.totals.portionG - 80);
  });

  it("removes an item the user says isn't there", () => {
    const result = applyEdits(PLATE, [{ id: "i1", removed: true }]);
    expect(result.items.map((i) => i.id)).toEqual(["i0", "i2"]);
    expect(result.totals.calories).toBe(PLATE.totals.calories - 208);
  });

  it("treats a zero portion as a removal", () => {
    const result = applyEdits(PLATE, [{ id: "i1", portionG: 0 }]);
    expect(result.items.map((i) => i.id)).toEqual(["i0", "i2"]);
  });

  it("renames without touching nutrition", () => {
    const result = applyEdits(PLATE, [{ id: "i0", name: "Roast chicken" }]);
    const chicken = result.items.find((i) => i.id === "i0")!;
    expect(chicken.name).toBe("Roast chicken");
    expect(chicken.calories).toBe(264);
    expect(chicken.proteinG).toBe(49);
  });

  it("recomputes the dominant food group when the plate changes", () => {
    expect(PLATE.totals.dominantFoodGroup).toBe("protein");
    const result = applyEdits(PLATE, [{ id: "i0", removed: true }]);
    expect(result.totals.dominantFoodGroup).toBe("grain");
  });

  it("recomputes the micro score when items are dropped", () => {
    const withMicros = normalizeAnalysis({
      items: [
        { name: "A", portionGrams: 100, calories: 100, proteinG: 5, carbsG: 5, fatG: 1, micronutrients: ["iron", "calcium"] },
        { name: "B", portionGrams: 100, calories: 100, proteinG: 5, carbsG: 5, fatG: 1, micronutrients: ["vitamin-c"] }
      ]
    });
    expect(withMicros.totals.microScore).toBeCloseTo(3 / 6, 3);
    const result = applyEdits(withMicros, [{ id: "i1", removed: true }]);
    expect(result.totals.microScore).toBeCloseTo(2 / 6, 3);
  });

  it("ignores edits referencing an unknown item id", () => {
    const result = applyEdits(PLATE, [{ id: "does-not-exist", portionG: 5 }]);
    expect(result.items).toHaveLength(3);
    expect(result.totals.calories).toBe(PLATE.totals.calories);
  });

  it("throws when the user removes everything", () => {
    expect(() =>
      applyEdits(PLATE, [{ id: "i0", removed: true }, { id: "i1", removed: true }, { id: "i2", removed: true }])
    ).toThrow(NotFoodError);
  });

  it("never lets an edit raise nutrient density (the anti-cheat property)", () => {
    // A client trying to smuggle macros in gets only the portion honoured.
    const result = applyEdits(PLATE, [
      { id: "i0", portionG: 200, ...( { proteinG: 5000, calories: 99999 } as object) }
    ]);
    const chicken = result.items.find((i) => i.id === "i0")!;
    const originalDensity = 264 / 160;
    expect(chicken.calories / chicken.portionG).toBeCloseTo(originalDensity, 6);
    expect(chicken.proteinG).toBeCloseTo(49 * (200 / 160), 1);
  });

  it("clears the low-confidence flag once a human has vetted the plate", () => {
    const shaky = normalizeAnalysis({
      items: [{ name: "Mystery", portionGrams: 100, calories: 100, proteinG: 1, carbsG: 1, fatG: 1, confidence: 0.2 }]
    });
    expect(shaky.lowConfidence).toBe(true);
    expect(applyEdits(shaky, []).lowConfidence).toBe(false);
  });
});
