import { describe, it, expect } from "vitest";
import {
  BAND_BASE,
  MAX_STAR_LEVEL,
  RARITY_BANDS,
  STAR_BONUS,
  StarLevel,
  asStarLevel,
  bandForValue,
  copiesForStar,
  netWorthFor,
  rarityForValue,
  starBonus
} from "./rarityBands";
import { RARITY_ORDER } from "../data/lootTable";

// ============================================================================
// Net worth: exponential rarity bands + the additive star economy.
//
// The balancing anchor is the thing to protect. Everything else in the economy
// is derived from it, so a rebalance that quietly breaks it would cascade into
// fusion, the crash game, and every valuation in the app.
// ============================================================================

const STARS: StarLevel[] = [1, 2, 3, 4, 5];

describe("rarity bands", () => {
  it("tile the number line with no gaps or overlaps", () => {
    for (let i = 1; i < RARITY_ORDER.length; i++) {
      const previous = RARITY_BANDS[RARITY_ORDER[i - 1]];
      const current = RARITY_BANDS[RARITY_ORDER[i]];
      expect(current.min).toBe(previous.max + 1);
    }
    expect(RARITY_BANDS.common.min).toBe(BAND_BASE);
    expect(RARITY_BANDS.secret.max).toBe(Infinity);
  });

  it("grow exponentially — each gap is bigger than the last", () => {
    // The whole point of #77: common -> uncommon is pocket change next to
    // epic -> legendary.
    for (let i = 1; i < RARITY_ORDER.length; i++) {
      const previous = RARITY_BANDS[RARITY_ORDER[i - 1]];
      const current = RARITY_BANDS[RARITY_ORDER[i]];
      expect(current.step).toBeGreaterThan(previous.step);
    }
    expect(RARITY_BANDS.epic.step).toBeGreaterThan(RARITY_BANDS.common.step * 10);
  });

  it("map a value back to exactly one band", () => {
    for (const rarity of RARITY_ORDER) {
      const band = RARITY_BANDS[rarity];
      expect(rarityForValue(band.min)).toBe(rarity);
      if (Number.isFinite(band.max)) expect(rarityForValue(band.max)).toBe(rarity);
    }
    // Below the Common floor is still Common: the floor is where the cheapest
    // Common sits, not a minimum a value has to clear.
    expect(rarityForValue(0)).toBe("common");
    expect(rarityForValue(-50)).toBe("common");
    expect(rarityForValue(10_000_000)).toBe("secret");
  });

  it("never go backwards as value climbs", () => {
    let seen = 0;
    for (let value = 0; value < 400_000; value += 331) {
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
    // individual variation survives mastery (spec §3, §6).
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
    // Later stars cost exponentially more copies, so they must be worth
    // progressively more (spec §7).
    for (const rarity of RARITY_ORDER) {
      for (let star = 2; star <= MAX_STAR_LEVEL; star++) {
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
    // "+100 per star" across every rarity is explicitly wrong (spec §2).
    for (const star of STARS.filter((s) => s > 1)) {
      for (let i = 1; i < RARITY_ORDER.length; i++) {
        expect(starBonus(RARITY_ORDER[i], star)).toBeGreaterThan(starBonus(RARITY_ORDER[i - 1], star));
      }
    }
  });

  it("lands a 5★ on the 2★ of the next rarity — the balancing anchor", () => {
    // Spec §8. This is the equation bonus5 is solved from, so it should hold
    // exactly; if a rebalance breaks it, the whole mastery economy drifts.
    for (let i = 0; i < RARITY_ORDER.length - 1; i++) {
      const lower = RARITY_ORDER[i];
      const upper = RARITY_ORDER[i + 1];
      const masteredLower = netWorthFor(RARITY_BANDS[lower].min, lower, 5);
      const freshUpper = netWorthFor(RARITY_BANDS[upper].min, upper, 2);
      expect(masteredLower).toBe(freshUpper);
    }
  });

  it("lets mastery overlap the next rarity without dominating it", () => {
    // Spec §9: a 5★ Common should beat *some* 1★ Uncommons, and sit in the
    // lower reaches of the Uncommon band — not above the whole of it.
    for (let i = 0; i < RARITY_ORDER.length - 1; i++) {
      const lower = RARITY_ORDER[i];
      const upper = RARITY_BANDS[RARITY_ORDER[i + 1]];
      const mastered = netWorthFor(RARITY_BANDS[lower].min, lower, 5);

      expect(mastered).toBeGreaterThan(upper.min); // overlaps
      expect(mastered).toBeLessThan(upper.min + upper.step * 0.5); // but stays low in the band
    }
  });

  it("never changes a monster's rarity", () => {
    // Spec §14: a ★5 Common is a Common, however much it is worth. Rarity is
    // a property of the monster; the band lookup is only for pricing rewards.
    const mastered = netWorthFor(RARITY_BANDS.common.min, "common", 5);
    expect(rarityForValue(mastered)).toBe("uncommon"); // by value alone
    // ...which is exactly why callers must carry rarity explicitly rather than
    // re-deriving it from value for an owned monster.
    expect(netWorthFor(RARITY_BANDS.common.min, "common", 5)).toBe(mastered);
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

  it("is worth less than the copies burned to make it", () => {
    // 81 copies in, one monster out: fusion must concentrate value, not print
    // it, or duplicate-farming becomes the whole economy (spec §5).
    for (const rarity of RARITY_ORDER) {
      const base = RARITY_BANDS[rarity].min;
      const mastered = netWorthFor(base, rarity, 5);
      expect(mastered).toBeLessThan(base * copiesForStar(5));
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
  it("cover every rarity at every star", () => {
    for (const rarity of RARITY_ORDER) {
      expect(RARITY_BANDS[rarity]).toBeDefined();
      for (const star of STARS) {
        expect(STAR_BONUS[rarity][star]).toBeTypeOf("number");
        expect(Number.isInteger(STAR_BONUS[rarity][star])).toBe(true);
      }
    }
  });
});
