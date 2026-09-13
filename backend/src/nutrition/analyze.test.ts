import { describe, it, expect } from "vitest";
import { analyzeDishPhoto, extractJson, LIMITS, normalizeAnalysis } from "./analyze";
import { NotFoodError } from "./types";

/** A realistic three-item plate the way the model is asked to report it. */
const CHICKEN_PLATE = {
  dishName: "Chicken, rice and broccoli",
  colorHex: "#C8A45C",
  nova: 1,
  items: [
    {
      name: "Grilled chicken breast",
      portionGrams: 160,
      portionLabel: "1 breast (~160 g)",
      calories: 264,
      proteinG: 49,
      carbsG: 0,
      fatG: 6,
      fiberG: 0,
      sugarG: 0,
      sodiumMg: 110,
      micronutrients: ["iron", "potassium"],
      foodGroup: "protein",
      confidence: 0.86
    },
    {
      name: "White rice",
      portionGrams: 160,
      portionLabel: "1 cup (~160 g)",
      calories: 208,
      proteinG: 4.3,
      carbsG: 45,
      fatG: 0.4,
      fiberG: 0.6,
      sugarG: 0,
      sodiumMg: 2,
      micronutrients: ["iron"],
      foodGroup: "grain",
      confidence: 0.78
    },
    {
      name: "Steamed broccoli",
      portionGrams: 90,
      portionLabel: "~90 g",
      calories: 31,
      proteinG: 2.6,
      carbsG: 6,
      fatG: 0.3,
      fiberG: 2.4,
      sugarG: 1.4,
      sodiumMg: 30,
      micronutrients: ["vitamin-c", "calcium", "potassium"],
      foodGroup: "produce",
      confidence: 0.82
    }
  ]
};

describe("normalizeAnalysis — happy path", () => {
  it("keeps every distinct item rather than merging the plate", () => {
    const a = normalizeAnalysis(CHICKEN_PLATE, "fixed-id");
    expect(a.items).toHaveLength(3);
    expect(a.items.map((i) => i.name)).toEqual([
      "Grilled chicken breast",
      "White rice",
      "Steamed broccoli"
    ]);
    expect(a.analysisId).toBe("fixed-id");
    expect(a.dishName).toBe("Chicken, rice and broccoli");
  });

  it("assigns stable per-item ids for the confirm screen to reference", () => {
    const a = normalizeAnalysis(CHICKEN_PLATE);
    expect(a.items.map((i) => i.id)).toEqual(["i0", "i1", "i2"]);
  });

  it("derives plate totals from the items", () => {
    const a = normalizeAnalysis(CHICKEN_PLATE);
    expect(a.totals.portionG).toBe(410);
    expect(a.totals.calories).toBe(503);
    expect(a.totals.dominantFoodGroup).toBe("protein");
    expect(new Set(a.totals.foodGroups)).toEqual(new Set(["protein", "grain", "produce"]));
  });

  it("scores micronutrients on the same 0..1 scale as barcode products", () => {
    const a = normalizeAnalysis(CHICKEN_PLATE);
    // iron, potassium, vitamin-c, calcium = 4 of 6
    expect(a.totals.microScore).toBeCloseTo(4 / 6, 3);
  });

  it("averages item confidence and flags a solid plate as trustworthy", () => {
    const a = normalizeAnalysis(CHICKEN_PLATE);
    expect(a.confidence).toBeGreaterThan(0.8);
    expect(a.lowConfidence).toBe(false);
  });
});

describe("normalizeAnalysis — rejecting non-food", () => {
  it("throws when the model reports notFood", () => {
    expect(() => normalizeAnalysis({ notFood: true })).toThrow(NotFoodError);
  });

  it("throws on the legacy not_food error shape", () => {
    expect(() => normalizeAnalysis({ error: "not_food" })).toThrow(NotFoodError);
  });

  it("throws when no usable item survives normalisation", () => {
    expect(() => normalizeAnalysis({ items: [] })).toThrow(NotFoodError);
    expect(() => normalizeAnalysis({ items: [{ name: "garnish" }] })).toThrow(NotFoodError);
  });

  it("throws on a non-object reply", () => {
    expect(() => normalizeAnalysis("nope")).toThrow(NotFoodError);
  });
});

describe("normalizeAnalysis — treating the model as hostile input", () => {
  it("replaces a calorie figure that contradicts the macros", () => {
    // macros imply 49*4 + 0 + 6*9 = 250 kcal; the model claims 20.
    const a = normalizeAnalysis({
      items: [{ name: "Chicken", portionGrams: 160, calories: 20, proteinG: 49, carbsG: 0, fatG: 6 }]
    });
    expect(a.items[0].calories).toBeCloseTo(250, 0);
  });

  it("keeps a calorie figure that broadly agrees with the macros", () => {
    // macros imply 250; 264 is within tolerance, so the model's value stands.
    const a = normalizeAnalysis({
      items: [{ name: "Chicken", portionGrams: 160, calories: 264, proteinG: 49, carbsG: 0, fatG: 6 }]
    });
    expect(a.items[0].calories).toBe(264);
  });

  it("clamps absurd per-item values", () => {
    const a = normalizeAnalysis({
      items: [{ name: "Cheat", portionGrams: 999999, calories: 999999, proteinG: 999999, carbsG: 0, fatG: 0 }]
    });
    expect(a.items[0].portionG).toBeLessThanOrEqual(LIMITS.item.portionG);
    expect(a.items[0].proteinG).toBeLessThanOrEqual(LIMITS.item.macroG);
    expect(a.items[0].calories).toBeLessThanOrEqual(LIMITS.item.calories);
  });

  it("scales a whole plate back under the ceiling, preserving the mix", () => {
    const a = normalizeAnalysis({
      items: [
        { name: "A", portionGrams: 2000, calories: 5000, proteinG: 400, carbsG: 0, fatG: 0 },
        { name: "B", portionGrams: 2000, calories: 5000, proteinG: 200, carbsG: 0, fatG: 0 }
      ]
    });
    expect(a.totals.calories).toBeLessThanOrEqual(LIMITS.plate.calories);
    // A still has twice the protein of B after the proportional cap.
    expect(a.items[0].proteinG / a.items[1].proteinG).toBeCloseTo(2, 1);
  });

  it("rejects negative and non-numeric nutrients", () => {
    const a = normalizeAnalysis({
      items: [{ name: "Weird", portionGrams: 100, calories: 50, proteinG: -20, carbsG: "abc", fatG: null }]
    });
    expect(a.items[0].proteinG).toBe(0);
    expect(a.items[0].carbsG).toBe(0);
    expect(a.items[0].fatG).toBe(0);
  });

  it("caps the number of items", () => {
    const many = Array.from({ length: 40 }, (_, i) => ({
      name: `Item ${i}`,
      portionGrams: 10,
      calories: 10,
      proteinG: 1,
      carbsG: 1,
      fatG: 0
    }));
    const a = normalizeAnalysis({ items: many });
    expect(a.items.length).toBeLessThanOrEqual(LIMITS.maxItems);
  });

  it("normalises micronutrient spellings and drops unknown ones", () => {
    const a = normalizeAnalysis({
      items: [
        {
          name: "Orange",
          portionGrams: 100,
          calories: 47,
          proteinG: 1,
          carbsG: 12,
          fatG: 0,
          micronutrients: ["Vitamin C", "vitamin_a", "IRON", "unobtainium", 42]
        }
      ]
    });
    expect(new Set(a.items[0].micronutrients)).toEqual(new Set(["vitamin-c", "vitamin-a", "iron"]));
  });

  it("falls back to 'other' for an unknown food group", () => {
    const a = normalizeAnalysis({
      items: [{ name: "X", portionGrams: 100, calories: 100, proteinG: 1, carbsG: 1, fatG: 1, foodGroup: "dessert" }]
    });
    expect(a.items[0].foodGroup).toBe("other");
  });

  it("falls back to a safe colour and NOVA level", () => {
    const a = normalizeAnalysis({ colorHex: "red", nova: 99, items: CHICKEN_PLATE.items });
    expect(a.colorHex).toBe("#5FCB82");
    expect(a.nova).toBe(4);
  });

  it("flags a shaky plate as low confidence", () => {
    const a = normalizeAnalysis({
      items: [{ name: "Mystery", portionGrams: 100, calories: 100, proteinG: 1, carbsG: 1, fatG: 1, confidence: 0.2 }]
    });
    expect(a.lowConfidence).toBe(true);
  });
});

describe("extractJson", () => {
  it("parses a bare JSON object", () => {
    expect(extractJson('{"a":1}')).toEqual({ a: 1 });
  });

  it("strips markdown fences", () => {
    expect(extractJson('```json\n{"a":1}\n```')).toEqual({ a: 1 });
  });

  it("recovers an object from a chatty reply", () => {
    expect(extractJson('Sure! Here you go:\n{"a":1}\nHope that helps.')).toEqual({ a: 1 });
  });

  it("throws when there is no JSON at all", () => {
    expect(() => extractJson("I cannot help with that")).toThrow(NotFoodError);
  });
});

describe("analyzeDishPhoto", () => {
  it("runs the vision reply through normalisation", async () => {
    const a = await analyzeDishPhoto("base64", async () => JSON.stringify(CHICKEN_PLATE));
    expect(a.items).toHaveLength(3);
    expect(a.totals.calories).toBe(503);
  });

  it("passes the prompt and image to the transport", async () => {
    let seenImage = "";
    let seenPrompt = "";
    await analyzeDishPhoto("IMAGEDATA", async (image, prompt) => {
      seenImage = image;
      seenPrompt = prompt;
      return JSON.stringify(CHICKEN_PLATE);
    });
    expect(seenImage).toBe("IMAGEDATA");
    expect(seenPrompt).toContain("identify EVERY distinct food");
  });

  it("surfaces NotFoodError for a non-food photo", async () => {
    await expect(analyzeDishPhoto("base64", async () => '{"notFood":true}')).rejects.toThrow(NotFoodError);
  });
});
