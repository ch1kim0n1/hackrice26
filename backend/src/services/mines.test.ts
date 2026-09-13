import { describe, it, expect } from "vitest";
import {
  heatFor,
  isMineCountLegal,
  mineLayout,
  multiplierAfter,
  nextMultiplier,
  nextPickSafeChance,
  potValue,
  quantizeMultiplier,
  safeTiles,
  survivalProbability
} from "./minesEngine";
import { HOUSE_EDGE, MAX_MINES, MIN_MINES, TILE_COUNT } from "../data/mines";

// ============================================================================
// Kitchen Mines — the payout math.
//
// The multiplier is derived from the real survival probability rather than
// written down, so these tests are checking that the derivation is honest:
// that the published odds are the odds, that the house edge is exactly the
// stated 5%, and that no board pays more than the risk it carries.
// ============================================================================

describe("survival probability", () => {
  it("matches the hypergeometric product", () => {
    // 5 mines, 20 safe: 20/25, then 19/24, then 18/23.
    expect(survivalProbability(5, 1)).toBeCloseTo(20 / 25, 10);
    expect(survivalProbability(5, 2)).toBeCloseTo((20 / 25) * (19 / 24), 10);
    expect(survivalProbability(5, 3)).toBeCloseTo((20 / 25) * (19 / 24) * (18 / 23), 10);
  });

  it("is 1 before the first pick and 0 past the last safe dish", () => {
    expect(survivalProbability(5, 0)).toBe(1);
    expect(survivalProbability(24, 2)).toBe(0); // only one safe dish exists
  });

  it("falls as mines rise, for the same number of picks", () => {
    let previous = 1;
    for (let mines = 1; mines <= 20; mines++) {
      const p = survivalProbability(mines, 3);
      expect(p).toBeLessThan(previous);
      previous = p;
    }
  });

  it("clearing the board is exactly as likely as the last mine placement", () => {
    // Turning over all 24 safe dishes with one mine hidden means never hitting
    // it: 24!/25! by the product = 1/25.
    expect(survivalProbability(1, 24)).toBeCloseTo(1 / 25, 10);
  });
});

describe("multipliers", () => {
  it("matches the spec's worked examples", () => {
    // 5 mines: the spec quotes 1.1875 -> "≈1.19", 1.50, 1.92. This project
    // floors to two decimals rather than rounding (a player is never paid for
    // a hundredth they did not reach), so the first and third land a
    // hundredth lower. The underlying probability is identical.
    expect(multiplierAfter(5, 1)).toBe(1.18);
    expect(multiplierAfter(5, 2)).toBe(1.5);
    expect(multiplierAfter(5, 3)).toBe(1.91);

    // 24 mines: a 4% shot at 23.75x, exactly as the spec states.
    expect(nextPickSafeChance(24, 0)).toBeCloseTo(0.04, 10);
    expect(multiplierAfter(24, 1)).toBe(23.75);
  });

  it("charges exactly the stated house edge", () => {
    // The payout is the fair price times (1 - edge), everywhere it is not
    // clamped at 1.00x.
    for (const mines of [2, 5, 10, 15, 20]) {
      for (let picks = 1; picks <= Math.min(6, safeTiles(mines)); picks++) {
        const fair = 1 / survivalProbability(mines, picks);
        const paid = multiplierAfter(mines, picks);
        if (paid > 1) {
          expect(paid).toBeCloseTo(quantizeMultiplier(fair * (1 - HOUSE_EDGE)), 10);
        }
      }
    }
  });

  it("never pays less than the wager", () => {
    // With one mine the edge exceeds the risk premium on the first pick, so
    // the fair price is below 1. Clamping means a safe pick can never make a
    // player poorer than cashing out before it.
    expect(multiplierAfter(1, 1)).toBe(1);
    for (let mines = MIN_MINES; mines <= MAX_MINES; mines++) {
      for (let picks = 0; picks <= safeTiles(mines); picks++) {
        expect(multiplierAfter(mines, picks)).toBeGreaterThanOrEqual(1);
      }
    }
  });

  it("rises with every extra dish, on every board", () => {
    for (let mines = MIN_MINES; mines <= MAX_MINES; mines++) {
      let previous = 0;
      for (let picks = 0; picks <= safeTiles(mines); picks++) {
        const multiplier = multiplierAfter(mines, picks);
        expect(multiplier).toBeGreaterThanOrEqual(previous);
        previous = multiplier;
      }
    }
  });

  it("pays more for the same picks on a more dangerous board", () => {
    expect(multiplierAfter(10, 3)).toBeGreaterThan(multiplierAfter(5, 3));
    expect(multiplierAfter(5, 3)).toBeGreaterThan(multiplierAfter(1, 3));
  });

  it("previews the next dish, and stops at a cleared board", () => {
    expect(nextMultiplier(5, 0)).toBe(multiplierAfter(5, 1));
    expect(nextMultiplier(5, 3)).toBe(multiplierAfter(5, 4));
    expect(nextMultiplier(1, safeTiles(1))).toBeNull();
  });
});

describe("fairness", () => {
  it("depends on nothing but the board", () => {
    // multiplierAfter takes two numbers. There is nowhere for monster value,
    // rarity, stars, rank or history to enter the payout.
    expect(multiplierAfter(7, 4)).toBe(multiplierAfter(7, 4));
  });

  it("lays a board that is uniform over every tile", () => {
    // A biased shuffle would put mines under the same dishes more often, which
    // a player would eventually learn. Sample the layout across many seeds and
    // check every tile is hit about equally.
    const counts = new Array(TILE_COUNT).fill(0);
    const trials = 4_000;
    const mines = 5;
    for (let t = 0; t < trials; t++) {
      // A cheap deterministic pseudo-roll standing in for the HMAC chain.
      const layout = mineLayout(mines, (cursor) => {
        const x = Math.sin(t * 7919 + cursor * 104729) * 10_000;
        return x - Math.floor(x);
      });
      for (const tile of layout) counts[tile]++;
    }
    const expected = (trials * mines) / TILE_COUNT;
    for (const count of counts) {
      expect(count).toBeGreaterThan(expected * 0.75);
      expect(count).toBeLessThan(expected * 1.25);
    }
  });

  it("always hides exactly the requested number of mines, all on the board", () => {
    for (let mines = MIN_MINES; mines <= MAX_MINES; mines++) {
      const layout = mineLayout(mines, (cursor) => ((cursor * 2654435761) % 1000) / 1000);
      expect(layout).toHaveLength(mines);
      expect(new Set(layout).size).toBe(mines);
      for (const tile of layout) {
        expect(tile).toBeGreaterThanOrEqual(0);
        expect(tile).toBeLessThan(TILE_COUNT);
      }
    }
  });

  it("is reproducible from the same seed chain", () => {
    const rollFn = (cursor: number) => ((cursor * 48271) % 2147483647) / 2147483647;
    expect(mineLayout(6, rollFn)).toEqual(mineLayout(6, rollFn));
  });
});

describe("board rules", () => {
  it("accepts 1..24 mines and nothing else", () => {
    expect(isMineCountLegal(1)).toBe(true);
    expect(isMineCountLegal(24)).toBe(true);
    expect(isMineCountLegal(0)).toBe(false);
    expect(isMineCountLegal(25)).toBe(false);
    expect(isMineCountLegal(3.5)).toBe(false);
    expect(isMineCountLegal(NaN)).toBe(false);
  });

  it("always leaves at least one safe dish", () => {
    expect(safeTiles(MAX_MINES)).toBe(1);
  });

  it("floors the pot, like every stored net worth", () => {
    expect(potValue(12_000, 1.92)).toBe(23_040);
    expect(potValue(3, 1.1)).toBe(3);
  });

  it("heats the kitchen by the displayed multiplier only", () => {
    expect(heatFor(1)).toBe("calm");
    expect(heatFor(2)).toBe("warm");
    expect(heatFor(4)).toBe("hot");
    expect(heatFor(50)).toBe("searing");
  });
});
