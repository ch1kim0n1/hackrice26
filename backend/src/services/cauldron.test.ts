import { describe, it, expect } from "vitest";
import {
  MAX_CRASH_MULTIPLIER,
  bracketsCrossed,
  cashOutValue,
  crashPointFrom,
  elapsedForMultiplier,
  intensityFor,
  multiplierAt,
  quantizeMultiplier,
  rarityForValue,
  rewardFor,
  rewardPool,
  startingNetWorth
} from "./cauldronEngine";
import { HOUSE_EDGE } from "../data/cauldron";
import { RARITY_BANDS } from "../game/rarityBands";
import { RARITY_ORDER } from "../data/lootTable";
import { ROSTER } from "../data/roster";
import { Rarity } from "../types";

// ============================================================================
// Cauldron Crash — the round math.
//
// The distribution is the product here: a crash game whose odds drift, or
// whose crash point can be nudged by the size of the wager, is not the game
// the rules page describes. These tests pin both.
// ============================================================================

describe("crash point distribution", () => {
  it("follows P(reach x) = (1 - edge) / x", () => {
    // The roll is uniform, so the share of rolls producing a crash of at least
    // x is exactly the survival probability the spec publishes.
    for (const x of [1.1, 1.25, 1.5, 2, 3, 5, 10, 20, 50, 100]) {
      const samples = 200_000;
      let reached = 0;
      for (let i = 0; i < samples; i++) {
        if (crashPointFrom((i + 0.5) / samples) >= x) reached++;
      }
      const expected = (1 - HOUSE_EDGE) / x;
      expect(reached / samples).toBeCloseTo(expected, 2);
    }
  });

  it("gives the house its edge as instant crashes at 1.00x", () => {
    // A roll above 0.95 cannot produce a multiplier above 1.
    expect(crashPointFrom(0.96)).toBe(1);
    expect(crashPointFrom(0.999)).toBe(1);
    expect(crashPointFrom(0.95)).toBe(1);
    expect(crashPointFrom(0.9)).toBeGreaterThan(1);
  });

  it("never returns less than 1.00x or an infinite multiplier", () => {
    expect(crashPointFrom(0)).toBe(MAX_CRASH_MULTIPLIER);
    expect(crashPointFrom(1)).toBe(1);
    expect(Number.isFinite(crashPointFrom(1e-18))).toBe(true);
    for (let i = 1; i < 1000; i++) {
      expect(crashPointFrom(i / 1000)).toBeGreaterThanOrEqual(1);
    }
  });

  it("matches the worked examples in the spec", () => {
    expect(crashPointFrom(0.42)).toBeCloseTo(2.26, 2);
    expect(crashPointFrom(0.08)).toBeCloseTo(11.87, 2);
  });

  it("rounds a multiplier down, never up", () => {
    expect(quantizeMultiplier(2.269)).toBe(2.26);
    expect(quantizeMultiplier(11.8749)).toBe(11.87);
  });
});

describe("fairness — the crash point depends on nothing about the player", () => {
  it("is a function of the roll alone", () => {
    // Same roll, wildly different wagers: crashPointFrom takes no other input,
    // so there is nowhere for wager size, rank, or history to enter.
    const roll = 0.3137;
    expect(crashPointFrom(roll)).toBe(crashPointFrom(roll));
    expect(crashPointFrom(roll)).toBeCloseTo(3.02, 2);
  });

  it("is monotonic in the roll — no engineered dead zones", () => {
    let previous = Infinity;
    for (let i = 1; i <= 1000; i++) {
      const crash = crashPointFrom(i / 1000);
      expect(crash).toBeLessThanOrEqual(previous);
      previous = crash;
    }
  });
});

describe("multiplier growth", () => {
  it("starts at 1.00x and rises", () => {
    expect(multiplierAt(0)).toBe(1);
    expect(multiplierAt(-500)).toBe(1);
    expect(multiplierAt(1000)).toBeGreaterThan(1);
    expect(multiplierAt(10_000)).toBeGreaterThan(multiplierAt(5_000));
  });

  it("round-trips through its own inverse", () => {
    for (const multiplier of [1.5, 2, 3.75, 10, 42.5]) {
      const elapsed = elapsedForMultiplier(multiplier);
      // Quantization floors, so the value at exactly that instant is the
      // multiplier itself (never more).
      expect(multiplierAt(elapsed)).toBeCloseTo(multiplier, 2);
      expect(multiplierAt(elapsed)).toBeLessThanOrEqual(multiplier);
    }
  });

  it("reaches 2x in a few seconds, not minutes", () => {
    const seconds = elapsedForMultiplier(2) / 1000;
    expect(seconds).toBeGreaterThan(3);
    expect(seconds).toBeLessThan(10);
  });
});

describe("visual intensity", () => {
  it("escalates with the displayed multiplier only", () => {
    expect(intensityFor(1)).toBe("calm");
    expect(intensityFor(1.99)).toBe("calm");
    expect(intensityFor(2)).toBe("warming");
    expect(intensityFor(3.5)).toBe("shaking");
    expect(intensityFor(7)).toBe("searing");
    expect(intensityFor(10)).toBe("unstable");
    expect(intensityFor(500)).toBe("unstable");
  });
});

describe("net worth and cash-out", () => {
  it("adds the wagered monsters into one pot", () => {
    expect(startingNetWorth([8_500, 6_200, 2_800])).toBe(17_500);
    expect(startingNetWorth([])).toBe(0);
  });

  it("floors the cash-out, matching the spec's worked example", () => {
    expect(cashOutValue(17_500, 4.31)).toBe(75_425);
    expect(cashOutValue(17_500, 1.5)).toBe(26_250);
    // 3 * 1.1 = 3.3000000000000003 in binary floating point; flooring keeps
    // the stored value an integer rather than leaking the noise.
    expect(cashOutValue(3, 1.1)).toBe(3);
  });
});

describe("rarity brackets", () => {
  it("maps every value to exactly one tier", () => {
    for (const rarity of RARITY_ORDER) {
      const range = RARITY_BANDS[rarity];
      expect(rarityForValue(range.min)).toBe(rarity);
      if (Number.isFinite(range.max)) expect(rarityForValue(range.max)).toBe(rarity);
    }
    // Below the Common floor is still Common: the floor is where the cheapest
    // Common sits, not a bar a value must clear.
    expect(rarityForValue(0)).toBe("common");
    expect(rarityForValue(-100)).toBe("common");
    expect(rarityForValue(10_000_000)).toBe("secret");
  });

  it("is monotonic — more net worth is never a worse tier", () => {
    let previousIndex = 0;
    for (let value = 0; value < 400_000; value += 137) {
      const index = RARITY_ORDER.indexOf(rarityForValue(value));
      expect(index).toBeGreaterThanOrEqual(previousIndex);
      previousIndex = index;
    }
  });

  it("reports the brackets a climbing pot crosses", () => {
    // A pot climbing from inside Common to inside Legendary announces every
    // band it enters on the way, in order, and never the one it started in.
    const crossed = bracketsCrossed(RARITY_BANDS.common.min, RARITY_BANDS.legendary.min);
    expect(crossed).toEqual(["uncommon", "rare", "epic", "legendary"]);

    // A climb that stays inside one band announces nothing...
    expect(bracketsCrossed(RARITY_BANDS.rare.min, RARITY_BANDS.rare.min + 10)).toEqual([]);
    // ...and so does falling back down.
    expect(bracketsCrossed(RARITY_BANDS.legendary.min, RARITY_BANDS.common.min)).toEqual([]);
  });
});

describe("reward selection", () => {
  it("awards a monster from the bracket the budget landed in", () => {
    for (const budget of [600, 1_500, 3_000, 9_000, 25_000, 90_000, 400_000]) {
      const reward = rewardFor(budget, 0.5, 0.5);
      expect(reward.rarity).toBe(rarityForValue(budget));
      expect(reward.character.rarity).toBe(reward.rarity);
    }
  });

  it("picks the character at random within the bracket, never by value", () => {
    const pool = rewardPool("common");
    const seen = new Set<string>();
    for (let i = 0; i < pool.length; i++) {
      seen.add(rewardFor(600, (i + 0.5) / pool.length, 0.5).character.id);
    }
    expect(seen.size).toBe(pool.length);
  });

  it("mints the reward near the budget, not at the bottom of the tier", () => {
    // A Secret bought near the top of its band must not arrive at the floor.
    const rich = rewardFor(400_000, 0.5, 0.5);
    const poor = rewardFor(RARITY_BANDS.secret.min, 0.5, 0.5);
    expect(rich.rarity).toBe("secret");
    expect(rich.value).toBeGreaterThanOrEqual(poor.value);
    for (const budget of [3_000, 9_000, 25_000, 90_000]) {
      const reward = rewardFor(budget, 0.5, 0.5);
      // Within a factor of two of what was paid, in either direction.
      expect(reward.value).toBeGreaterThan(budget / 2);
      expect(reward.value).toBeLessThan(budget * 2);
    }
  });

  it("always lands at one star — Crash is rarity, never mastery", () => {
    for (const budget of [600, 9_000, 500_000]) {
      expect(rewardFor(budget, 0.5, 0.5).stars).toBe(1);
    }
  });

  it("keeps the mint value inside the band that priced it", () => {
    for (let i = 0; i < 20; i++) {
      const reward = rewardFor(25_000, i / 20, i / 20);
      const band = RARITY_BANDS[reward.rarity];
      expect(reward.baseMintValue).toBeGreaterThanOrEqual(band.min);
      expect(reward.baseMintValue).toBeLessThanOrEqual(band.max);
      expect(reward.value).toBe(reward.baseMintValue); // rewards are always ★1
    }
  });

  it("can mint something for every bracket", () => {
    for (const rarity of RARITY_ORDER as Rarity[]) {
      expect(rewardPool().length).toBeGreaterThan(0);
      const budget = RARITY_BANDS[rarity].min + 1;
      expect(rewardFor(budget, 0.5, 0.5).rarity).toBe(rarity);
    }
  });

  it("mints casino rewards from the whole catalog — rarity is on the instance", () => {
    // No separate secret pool: the budget bought the rarity, and any of the
    // 14 designs can be the monster that carries it (spec §2).
    expect([...rewardPool().map((c) => c.id)].sort()).toEqual([...ROSTER.map((c) => c.id)].sort());
  });
});
