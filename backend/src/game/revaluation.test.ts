import { describe, it, expect } from "vitest";
import {
  SELL_RATE,
  baseValueOf,
  revalue,
  revalueFromTotal,
  sellValue
} from "./revaluation";
import { RARITY_BANDS, starBonus } from "./rarityBands";
import { RARITY_ORDER } from "../data/lootTable";

// ============================================================================
// Revaluation (#120).
//
// One formula, one place. These tests exist because the alternative -- every
// mutation path doing its own arithmetic -- is how two monsters with identical
// stats end up priced differently depending on which door they came through.
// ============================================================================

describe("revalue", () => {
  it("is base worth plus the star bonus for that rarity", () => {
    for (const rarity of RARITY_ORDER) {
      const base = RARITY_BANDS[rarity].min;
      for (const star of [1, 2, 3, 4, 5] as const) {
        const valuation = revalue({ baseValue: base, rarity, stars: star });
        expect(valuation.value).toBe(base + starBonus(rarity, star));
        expect(valuation.baseValue).toBe(base);
        expect(valuation.starBonus).toBe(starBonus(rarity, star));
      }
    }
  });

  it("leaves a one-star monster at exactly its base worth", () => {
    expect(revalue({ baseValue: 1_234, rarity: "rare", stars: 1 }).value).toBe(1_234);
    // A missing star level means one star, not zero.
    expect(revalue({ baseValue: 1_234, rarity: "rare" }).value).toBe(1_234);
  });

  it("never changes the monster's own rarity", () => {
    // Net worth spec §14: a mastered Common is still Common, however much its
    // value overlaps the next band. The band is reported separately so callers
    // can price rewards without relabelling monsters.
    const mastered = revalue({ baseValue: RARITY_BANDS.common.min, rarity: "common", stars: 5 });
    expect(mastered.rarity).toBe("common");
    expect(mastered.valueBand).toBe("uncommon");
  });

  it("clamps a nonsense star level rather than trusting it", () => {
    expect(revalue({ baseValue: 500, rarity: "common", stars: 0 }).star).toBe(1);
    expect(revalue({ baseValue: 500, rarity: "common", stars: 99 }).star).toBe(5);
    expect(revalue({ baseValue: -100, rarity: "common", stars: 1 }).value).toBe(0);
  });
});

describe("recovering a base worth", () => {
  it("undoes the star bonus", () => {
    for (const rarity of RARITY_ORDER) {
      const base = RARITY_BANDS[rarity].min + 37;
      for (const star of [1, 2, 3, 4, 5] as const) {
        const total = revalue({ baseValue: base, rarity, stars: star }).value;
        expect(baseValueOf(total, rarity, star)).toBe(base);
      }
    }
  });

  it("does not let mastery compound across repeated merges", () => {
    // The bug this prevents: re-applying the bonus to a total that already
    // includes one, so every merge inflates the monster a little more.
    const base = RARITY_BANDS.rare.min;
    let total = revalue({ baseValue: base, rarity: "rare", stars: 1 }).value;

    for (const next of [2, 3, 4, 5] as const) {
      const previous = next - 1;
      total = revalueFromTotal(total, "rare", previous, next).value;
      expect(total).toBe(base + starBonus("rare", next));
    }
    expect(total).toBe(revalue({ baseValue: base, rarity: "rare", stars: 5 }).value);
  });
});

describe("selling", () => {
  it("pays the full current net worth, mastery included", () => {
    // Selling is a conversion, not a haircut: the house takes its cut at the
    // tables, and charging again on the way out would make every win worth
    // less than the number the player was shown.
    expect(SELL_RATE).toBe(1);
    const monster = { baseValue: RARITY_BANDS.epic.min, rarity: "epic" as const, stars: 3 };
    expect(sellValue(monster)).toBe(revalue(monster).value);
    expect(sellValue(monster)).toBeGreaterThan(RARITY_BANDS.epic.min);
  });

  it("pays more for a more mastered copy of the same monster", () => {
    const base = RARITY_BANDS.uncommon.min;
    let previous = 0;
    for (const star of [1, 2, 3, 4, 5] as const) {
      const paid = sellValue({ baseValue: base, rarity: "uncommon", stars: star });
      expect(paid).toBeGreaterThan(previous);
      previous = paid;
    }
  });
});

describe("every value-changing path agrees", () => {
  it("prices a minted monster and a merged one by the same rule", () => {
    // A Rare minted at 3,000 and a Rare merged up to ★2 from a 3,000 base must
    // land on the same number; anything else means two formulas exist.
    const minted = revalue({ baseValue: 3_000, rarity: "rare", stars: 2 });
    const merged = revalueFromTotal(3_000, "rare", 1, 2);
    expect(merged.value).toBe(minted.value);
    expect(merged.valueBand).toBe(minted.valueBand);
  });

  it("prices a gamble reward by the same rule as anything else", () => {
    // Casino rewards are always fresh 1★ monsters, so their value is their
    // base with no bonus -- the same formula, with the mastery term at zero.
    const reward = revalue({ baseValue: 12_345, rarity: "epic", stars: 1 });
    expect(reward.value).toBe(12_345);
    expect(reward.starBonus).toBe(0);
  });
});
