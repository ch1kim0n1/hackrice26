import { describe, it, expect } from "vitest";
import {
  MAX_STAR_LEVEL,
  MINT_SEGMENT_TABLE,
  RARITY_BANDS,
  STAR_BONUS,
  StarLevel,
  asStarLevel,
  bandForValue,
  copiesForStar,
  expectedMintValue,
  maxStarsFor,
  mintSegmentFor,
  mintValue,
  netWorthFor,
  rarityForValue,
  starBonus
} from "./rarityBands";
import { SPEC_BANDS, MINT_SEGMENTS } from "./spec";
import { RARITY_ORDER } from "../data/lootTable";

// ============================================================================
// Net worth: the spec's fixed rarity bands + the additive star economy.
//
// The published numbers are the thing to protect — every valuation in the app
// (sell price, fusion output, casino budget) flows from them.
// ============================================================================

const STARS: StarLevel[] = [1, 2, 3, 4, 5];

describe("rarity bands", () => {
  it("match the spec's published table exactly", () => {
    for (const rarity of RARITY_ORDER) {
      expect(RARITY_BANDS[rarity].min).toBe(SPEC_BANDS[rarity].min);
      expect(RARITY_BANDS[rarity].max).toBe(SPEC_BANDS[rarity].max);
    }
    expect(RARITY_BANDS.common.min).toBe(500);
    expect(RARITY_BANDS.secret.max).toBe(597_999);
  });

  it("tile the number line with no gaps or overlaps", () => {
    for (let i = 1; i < RARITY_ORDER.length; i++) {
      const previous = RARITY_BANDS[RARITY_ORDER[i - 1]];
      const current = RARITY_BANDS[RARITY_ORDER[i]];
      expect(current.min).toBe(previous.max + 1);
    }
  });

  it("widen with scarcity — each band is bigger than the last", () => {
    for (let i = 1; i < RARITY_ORDER.length; i++) {
      const previous = RARITY_BANDS[RARITY_ORDER[i - 1]];
      const current = RARITY_BANDS[RARITY_ORDER[i]];
      expect(current.step).toBeGreaterThan(previous.step);
    }
  });

  it("map a value back to exactly one band", () => {
    for (const rarity of RARITY_ORDER) {
      const band = RARITY_BANDS[rarity];
      expect(rarityForValue(band.min)).toBe(rarity);
      expect(rarityForValue(band.max)).toBe(rarity);
    }
    // Below the Common floor is still Common; above the Secret ceiling is
    // still Secret — mastery legitimately pushes worth past a ★1 band.
    expect(rarityForValue(0)).toBe("common");
    expect(rarityForValue(-50)).toBe("common");
    expect(rarityForValue(10_000_000)).toBe("secret");
  });

  it("never go backwards as value climbs", () => {
    let seen = 0;
    for (let value = 0; value < 700_000; value += 331) {
      const index = RARITY_ORDER.indexOf(rarityForValue(value));
      expect(index).toBeGreaterThanOrEqual(seen);
      seen = index;
    }
  });

  it("expose the band object, not just the tier", () => {
    const band = bandForValue(7_000);
    expect(band.rarity).toBe("epic");
    expect(band.min).toBeLessThanOrEqual(7_000);
    expect(band.max).toBeGreaterThanOrEqual(7_000);
  });
});

describe("star economy", () => {
  it("adds value rather than multiplying it", () => {
    // Two Commons of different base worth gain the SAME amount at 3 stars, so
    // individual variation survives mastery (spec §2).
    const cheap = netWorthFor(500, "common", 3);
    const dear = netWorthFor(900, "common", 3);
    expect(dear - cheap).toBe(400);
    expect(cheap - 500).toBe(dear - 900);
  });

  it("is worth nothing at one star", () => {
    for (const rarity of RARITY_ORDER) {
      expect(starBonus(rarity, 1)).toBe(0);
      expect(netWorthFor(1_234, rarity, 1)).toBe(1_234);
    }
  });

  it("pays progressively more for each star", () => {
    for (const rarity of RARITY_ORDER) {
      for (let star = 2; star <= maxStarsFor(rarity); star++) {
        const gain = starBonus(rarity, star as StarLevel) - starBonus(rarity, (star - 1) as StarLevel);
        const previousGain =
          star === 2
            ? 0
            : starBonus(rarity, (star - 1) as StarLevel) - starBonus(rarity, (star - 2) as StarLevel);
        expect(gain).toBeGreaterThan(previousGain);
      }
    }
  });

  it("scales bonuses with rarity, never one flat number", () => {
    for (const star of STARS.filter((s) => s > 1 && s <= 2)) {
      for (let i = 1; i < RARITY_ORDER.length; i++) {
        expect(starBonus(RARITY_ORDER[i], star)).toBeGreaterThan(starBonus(RARITY_ORDER[i - 1], star));
      }
    }
  });

  it("solves bonus5 as step + bonus2(next rarity) — the balancing anchor", () => {
    // Spec §2: a ★5 monster at its band floor prices like a ★2 of the next
    // rarity at ITS floor. Secret has no ★5 — it is capped at ★2.
    for (let i = 0; i < RARITY_ORDER.length - 1; i++) {
      const lower = RARITY_ORDER[i];
      const upper = RARITY_ORDER[i + 1];
      const masteredLower = netWorthFor(RARITY_BANDS[lower].min, lower, 5);
      const freshUpper = netWorthFor(RARITY_BANDS[upper].min, upper, 2);
      expect(masteredLower).toBe(freshUpper);
    }
    expect(starBonus("secret", 5)).toBe(0);
  });

  it("caps Secret at ★2 while every other rarity reaches ★5", () => {
    expect(maxStarsFor("secret")).toBe(2);
    for (const rarity of RARITY_ORDER) {
      if (rarity === "secret") continue;
      expect(maxStarsFor(rarity)).toBe(MAX_STAR_LEVEL);
    }
  });

  it("never changes a monster's rarity", () => {
    // Rarity is a property of the monster; the band lookup is only for
    // pricing. A mastered Common can be worth Uncommon money while staying
    // a Common — which is why callers carry rarity explicitly.
    const mastered = netWorthFor(RARITY_BANDS.common.min, "common", 5);
    expect(rarityForValue(mastered)).toBe("uncommon");
    expect(netWorthFor(RARITY_BANDS.common.min, "common", 5)).toBe(mastered);
  });
});

describe("the weighted mint roll", () => {
  it("weights the five segments 55/27/13/4/1", () => {
    expect(MINT_SEGMENT_TABLE.map((s) => s.weight)).toEqual([0.55, 0.27, 0.13, 0.04, 0.01]);
    expect(MINT_SEGMENTS.reduce((s, m) => s + m.weight, 0)).toBeCloseTo(1, 9);
  });

  it("picks segments by weight across the unit interval", () => {
    expect(mintSegmentFor(0).from).toBe(0);
    expect(mintSegmentFor(0.54)).toBe(MINT_SEGMENT_TABLE[0]);
    expect(mintSegmentFor(0.55)).toBe(MINT_SEGMENT_TABLE[1]);
    expect(mintSegmentFor(0.81)).toBe(MINT_SEGMENT_TABLE[1]);
    // Exact cumulative edges ride on float dust (0.55+0.27 ≈ 0.82000…01), so
    // probe just past each nominal boundary.
    expect(mintSegmentFor(0.8200001)).toBe(MINT_SEGMENT_TABLE[2]);
    expect(mintSegmentFor(0.94)).toBe(MINT_SEGMENT_TABLE[2]);
    expect(mintSegmentFor(0.9500001)).toBe(MINT_SEGMENT_TABLE[3]);
    expect(mintSegmentFor(0.98)).toBe(MINT_SEGMENT_TABLE[3]);
    expect(mintSegmentFor(0.9900001)).toBe(MINT_SEGMENT_TABLE[4]);
  });

  it("never mints outside the rarity's band", () => {
    for (const rarity of RARITY_ORDER) {
      const band = RARITY_BANDS[rarity];
      for (const seg of [0, 0.3, 0.7, 0.95, 0.995, 1 - Number.EPSILON]) {
        for (const pos of [0, 0.5, 1 - Number.EPSILON]) {
          const value = mintValue(rarity, seg, pos);
          expect(value).toBeGreaterThanOrEqual(band.min);
          expect(value).toBeLessThanOrEqual(band.max);
        }
      }
    }
  });

  it("lands bottom-segment rolls in the bottom of the band", () => {
    // A segment-0 roll with position 0 is the band floor; position ~1 stays
    // under the 40% mark.
    const band = RARITY_BANDS.rare;
    expect(mintValue("rare", 0, 0)).toBe(band.min);
    expect(mintValue("rare", 0, 0.999)).toBeLessThan(band.min + band.step * 0.41);
  });

  it("produces the published segment distribution over many rolls", () => {
    const n = 200_000;
    const counts = MINT_SEGMENT_TABLE.map(() => 0);
    for (let i = 0; i < n; i++) {
      const u = (i + 0.5) / n; // stratified — deterministic, no RNG flakes
      const seg = mintSegmentFor(u);
      counts[MINT_SEGMENT_TABLE.indexOf(seg)]++;
    }
    for (let i = 0; i < counts.length; i++) {
      expect(counts[i] / n).toBeCloseTo(MINT_SEGMENT_TABLE[i].weight, 3);
    }
  });

  it("has an expected value inside the band for every rarity", () => {
    for (const rarity of RARITY_ORDER) {
      const ev = expectedMintValue(rarity);
      expect(ev).toBeGreaterThan(RARITY_BANDS[rarity].min);
      expect(ev).toBeLessThan(RARITY_BANDS[rarity].max);
    }
  });
});

describe("fusion arithmetic", () => {
  it("costs 3^(n-1) one-star copies", () => {
    expect(copiesForStar(1)).toBe(1);
    expect(copiesForStar(2)).toBe(3);
    expect(copiesForStar(3)).toBe(9);
    expect(copiesForStar(4)).toBe(27);
    expect(copiesForStar(5)).toBe(81);
  });

  it("concentrates value rather than printing it", () => {
    // 81 copies in, one monster out: fusion must pay less than the burned
    // copies' sum or duplicate-farming becomes the whole economy.
    for (const rarity of RARITY_ORDER) {
      const base = RARITY_BANDS[rarity].min;
      const mastered = netWorthFor(base, rarity, maxStarsFor(rarity));
      expect(mastered).toBeLessThan(base * copiesForStar(maxStarsFor(rarity)));
    }
  });
});

describe("star level coercion", () => {
  it("clamps anything into the legal 1..5", () => {
    expect(asStarLevel(3)).toBe(3);
    expect(asStarLevel(0)).toBe(1);
    expect(asStarLevel(-4)).toBe(1);
    expect(asStarLevel(99)).toBe(5);
    expect(asStarLevel(undefined)).toBe(1);
    expect(asStarLevel("2")).toBe(2);
    expect(asStarLevel(2.9)).toBe(2);
  });
});

describe("published tables", () => {
  it("cover every rarity at every reachable star", () => {
    for (const rarity of RARITY_ORDER) {
      expect(RARITY_BANDS[rarity]).toBeDefined();
      for (const star of STARS) {
        expect(STAR_BONUS[rarity][star]).toBeTypeOf("number");
        expect(Number.isInteger(STAR_BONUS[rarity][star])).toBe(true);
      }
    }
  });
});
