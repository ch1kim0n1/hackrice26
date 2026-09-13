import { describe, it, expect } from "vitest";
import {
  nutritionScore,
  nutritionComponents,
  rarityWeights,
  rollRarity,
  attackProfile,
  healthProfile,
  combatBase,
  checkPlausibility,
  NEUTRAL_NUTRITION_SCORE
} from "./nutritionScore";
import { SCAN_BASE_ODDS, SPEC_RARITY_ORDER } from "./spec";
import { Rarity } from "../types";

// ============================================================================
// Spec §1 math — NutritionScore, the tilted rarity roll, and the
// Attack/Health combat profiles. These are the contract's load-bearing
// numbers: a regression here silently changes what every barcode mints.
// ============================================================================

const BALANCED = { proteinG: 15, fiberG: 6, sugarG: 8, sodiumMg: 300, satFatG: 3 };

describe("nutritionScore", () => {
  it("scores a genuinely balanced food highly", () => {
    const score = nutritionScore(BALANCED);
    expect(score).toBeGreaterThan(55);
    expect(score).toBeLessThanOrEqual(100);
  });

  it("scores junk low", () => {
    const score = nutritionScore({ proteinG: 0, fiberG: 0, sugarG: 40, sodiumMg: 1500, satFatG: 12 });
    expect(score).toBeLessThan(25);
  });

  it("computes the exact spec components and weights", () => {
    // protein 25 -> 100, fiber 10 -> 100, sugar 20 -> 0, sodium 1000 -> 0,
    // satFat 10 -> 0. Score = (100*.25 + 100*.20 + 0*.25 + 0*.15 + 0*.15) = 45.
    expect(nutritionScore({ proteinG: 25, fiberG: 10, sugarG: 20, sodiumMg: 1000, satFatG: 10 }))
      .toBeCloseTo(45);
  });

  it("clamps every component at its bound", () => {
    const perfect = nutritionScore({ proteinG: 100, fiberG: 100, sugarG: 0, sodiumMg: 0, satFatG: 0 });
    expect(perfect).toBe(100);
    const abysmal = nutritionScore({ proteinG: 0, fiberG: 0, sugarG: 500, sodiumMg: 99999, satFatG: 500 });
    expect(abysmal).toBe(0);
  });

  it("redistributes weight across present fields when some are missing", () => {
    // Only protein present, maxed: the whole score is the protein score.
    expect(nutritionScore({ proteinG: 25 })).toBe(100);
    expect(nutritionScore({ proteinG: 0 })).toBe(0);
    // Protein + sugar present: weights .25/.25 renormalise to 50/50.
    // protein 12.5 -> 50, sugar 10 -> 50 -> score 50.
    expect(nutritionScore({ proteinG: 12.5, sugarG: 10 })).toBeCloseTo(50);
  });

  it("returns the neutral score when nothing is known", () => {
    expect(nutritionScore({})).toBe(NEUTRAL_NUTRITION_SCORE);
  });
});

describe("rarityWeights", () => {
  it("reproduces the baseline odds exactly at score 50", () => {
    const weights = rarityWeights(50);
    for (const rarity of SPEC_RARITY_ORDER) {
      expect(weights[rarity]).toBeCloseTo(SCAN_BASE_ODDS[rarity], 10);
    }
  });

  it("normalises to 1 at every score", () => {
    for (const score of [0, 25, 50, 75, 100]) {
      const total = SPEC_RARITY_ORDER.reduce((sum, r) => sum + rarityWeights(score)[r], 0);
      expect(total).toBeCloseTo(1, 12);
    }
  });

  it("tilts toward rare tiers as the score rises", () => {
    const low = rarityWeights(10);
    const high = rarityWeights(90);
    expect(high.secret).toBeGreaterThan(low.secret);
    expect(high.legendary).toBeGreaterThan(low.legendary);
    expect(low.common).toBeGreaterThan(high.common);
    // At score 90 the tilt exponent for secret is .8*.8*6 = 3.84 — the
    // rarest tier is meaningfully reachable but still rare.
    expect(high.secret).toBeLessThan(0.1);
  });

  it("matches the spec reference shape: rawWeight = baseOdds x exp(0.8 x z x idx)", () => {
    // Hand-computed for score 100 (z = 1): raw(secret) = .000064 * e^4.8.
    const weights = rarityWeights(100);
    const tilt = 0.8;
    const raw = SPEC_RARITY_ORDER.map(
      (r, i) => SCAN_BASE_ODDS[r] * Math.exp(tilt * i)
    );
    const total = raw.reduce((a, b) => a + b, 0);
    for (let i = 0; i < SPEC_RARITY_ORDER.length; i++) {
      expect(weights[SPEC_RARITY_ORDER[i]]).toBeCloseTo(raw[i] / total, 12);
    }
  });
});

describe("rollRarity", () => {
  it("is deterministic on the roll unit and spans every tier", () => {
    expect(rollRarity(50, 0)).toBe("common");
    expect(rollRarity(50, 0.79)).toBe("common");
    expect(rollRarity(50, 0.81)).toBe("uncommon");
    // u -> 1 lands in the deepest tail.
    expect(rollRarity(100, 1 - Number.EPSILON)).toBe("secret");
    expect(rollRarity(0, 1 - Number.EPSILON)).toBe("secret"); // tail is always the last slice
  });

  it("approximates the target distribution over many rolls", () => {
    // Deterministic grid, not RNG: sweep u over [0,1) and histogram.
    const score = 75;
    const weights = rarityWeights(score);
    const counts = new Map<Rarity, number>(SPEC_RARITY_ORDER.map((r) => [r, 0]));
    const N = 1_000_000;
    for (let i = 0; i < N; i++) {
      counts.set(rollRarity(score, i / N), (counts.get(rollRarity(score, i / N)) ?? 0) + 1);
    }
    for (const rarity of SPEC_RARITY_ORDER) {
      expect(counts.get(rarity)! / N).toBeCloseTo(weights[rarity], 5);
    }
  });
});

describe("combat profiles", () => {
  it("keeps generated stats inside the catalog's envelope", () => {
    const maxed = combatBase({ proteinG: 50, carbsG: 60, fatG: 30, calories: 900, fiberG: 20, sugarG: 0, sodiumMg: 0, satFatG: 0 });
    expect(maxed.baseAttack).toBeLessThanOrEqual(85);
    expect(maxed.baseHealth).toBeLessThanOrEqual(160);
    const nothing = combatBase({});
    expect(nothing.baseAttack).toBeGreaterThanOrEqual(30);
    expect(nothing.baseHealth).toBeGreaterThanOrEqual(60);
  });

  it("attack profile rewards protein/carbs/fat energy; health rewards fibre and quality", () => {
    const proteinBomb = attackProfile({ proteinG: 40, carbsG: 50, fatG: 20, calories: 600 })!;
    const junk = attackProfile({ proteinG: 0, carbsG: 0, fatG: 0, calories: 50 })!;
    expect(proteinBomb).toBeGreaterThan(junk);

    const clean = healthProfile({ proteinG: 20, fiberG: 12, sugarG: 0, sodiumMg: 0, satFatG: 0 })!;
    const salty = healthProfile({ proteinG: 20, fiberG: 12, sugarG: 40, sodiumMg: 3000, satFatG: 15 })!;
    expect(clean).toBeGreaterThan(salty);
  });

  it("redistributes profile weights when fields are missing", () => {
    // Only protein known -> both profiles are just the protein component.
    expect(attackProfile({ proteinG: 25 })).toBeCloseTo(1);
    expect(healthProfile({ proteinG: 25 })).toBeCloseTo(1);
    expect(attackProfile({})).toBeUndefined();
    expect(healthProfile({})).toBeUndefined();
  });
});

describe("checkPlausibility", () => {
  it("accepts an ordinary product", () => {
    expect(checkPlausibility(BALANCED).plausible).toBe(true);
  });

  it("rejects out-of-range and impossible values", () => {
    expect(checkPlausibility({ proteinG: 200 }).plausible).toBe(false);
    expect(checkPlausibility({ calories: 5000 }).plausible).toBe(false);
    expect(checkPlausibility({ sodiumMg: -1 }).plausible).toBe(false);
    expect(checkPlausibility({ sugarG: NaN }).plausible).toBe(false);
  });

  it("rejects physically impossible combinations", () => {
    // Macros outweigh the food itself.
    expect(checkPlausibility({ proteinG: 60, carbsG: 60, fatG: 30 }).plausible).toBe(false);
    // Saturated fat exceeds total fat.
    expect(checkPlausibility({ fatG: 5, satFatG: 20 }).plausible).toBe(false);
    // Stated energy wildly disagrees with the macros.
    expect(checkPlausibility({ calories: 900, proteinG: 1, carbsG: 1, fatG: 1 }).plausible).toBe(false);
  });

  it("tolerates plausible label noise", () => {
    // 2g fibre + rounding slack — under the 110g macro ceiling, energy within
    // the Atwater tolerance band.
    const p = checkPlausibility({ calories: 250, proteinG: 10, carbsG: 30, fatG: 10, fiberG: 2 });
    expect(p.plausible).toBe(true);
    expect(p.reasons).toHaveLength(0);
  });
});
