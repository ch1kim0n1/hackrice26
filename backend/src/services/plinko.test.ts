import { describe, it, expect } from "vitest";
import {
  actualHouseEdge,
  dropPath,
  expectedMultiplier,
  finalNetWorth,
  isSlotLegal,
  multiplierForSlot,
  pathsToSlot,
  payoutTable,
  slotForPath,
  slotProbability
} from "./plinkoEngine";
import {
  HOUSE_EDGE,
  PEG_ROWS,
  SLOT_COUNT,
  SLOT_MULTIPLIERS,
  TOTAL_PATHS,
  slotTier
} from "../data/plinko";

// ============================================================================
// Plinko — the board's odds and the edge they buy.
//
// Plinko has no decisions, so the payout table IS the game. If the weighted
// payout drifts, the casino is quietly giving money away or quietly taking it,
// and nothing in the UI would show it. These tests are the alarm.
// ============================================================================

describe("landing distribution", () => {
  it("is binomial across 12 rows", () => {
    // C(12, k): the number of distinct paths into each slot.
    expect([...Array(SLOT_COUNT).keys()].map(pathsToSlot)).toEqual([
      1, 12, 66, 220, 495, 792, 924, 792, 495, 220, 66, 12, 1
    ]);
  });

  it("accounts for every path exactly once", () => {
    const total = [...Array(SLOT_COUNT).keys()].reduce((sum, slot) => sum + pathsToSlot(slot), 0);
    expect(total).toBe(TOTAL_PATHS);
    expect(total).toBe(4096);
  });

  it("sums to one", () => {
    const total = [...Array(SLOT_COUNT).keys()].reduce((sum, slot) => sum + slotProbability(slot), 0);
    expect(total).toBeCloseTo(1, 12);
  });

  it("makes the centre far more likely than the edges", () => {
    // The centre is nearly a quarter of all drops; an edge is one in 4096.
    expect(slotProbability(6)).toBeCloseTo(924 / 4096, 12);
    expect(slotProbability(0)).toBeCloseTo(1 / 4096, 12);
    expect(slotProbability(6) / slotProbability(0)).toBeCloseTo(924, 6);
  });

  it("is symmetric", () => {
    for (let slot = 0; slot < SLOT_COUNT; slot++) {
      expect(slotProbability(slot)).toBeCloseTo(slotProbability(SLOT_COUNT - 1 - slot), 12);
    }
  });
});

describe("the payout table", () => {
  it("charges the house edge the rest of the casino charges", () => {
    // The whole economy of this game in one number.
    expect(expectedMultiplier()).toBeCloseTo(1 - HOUSE_EDGE, 3);
    expect(actualHouseEdge()).toBeCloseTo(HOUSE_EDGE, 3);
  });

  it("is symmetric, and never pays a common slot more than a rare one", () => {
    for (let slot = 0; slot < SLOT_COUNT; slot++) {
      expect(multiplierForSlot(slot)).toBe(multiplierForSlot(SLOT_COUNT - 1 - slot));
    }
    // Walking inward from the edge, payouts only fall.
    for (let slot = 1; slot <= Math.floor(SLOT_COUNT / 2); slot++) {
      expect(SLOT_MULTIPLIERS[slot]).toBeLessThanOrEqual(SLOT_MULTIPLIERS[slot - 1]);
    }
  });

  it("pays the most where the orb almost never goes", () => {
    const table = payoutTable();
    const richest = table.reduce((best, entry) => (entry.multiplier > best.multiplier ? entry : best));
    const likeliest = table.reduce((best, entry) => (entry.probability > best.probability ? entry : best));
    expect(richest.probability).toBeLessThan(0.001);
    expect(likeliest.multiplier).toBe(0);
  });

  it("puts the whole edge in the bust slot, not in a slow bleed", () => {
    // The board's character: one way to lose, and it is the likeliest slot.
    // Every other landing returns the wager or better, which is what keeps a
    // game with no cash-out from feeling relentless.
    expect(SLOT_MULTIPLIERS.some((m) => m === 0)).toBe(true);
    expect(SLOT_MULTIPLIERS.every((m) => m === 0 || m >= 1)).toBe(true);
    expect(SLOT_MULTIPLIERS.some((m) => m >= 20)).toBe(true);
  });

  it("returns the wager or better on most drops", () => {
    const kept = payoutTable()
      .filter((entry) => entry.multiplier >= 1)
      .reduce((sum, entry) => sum + entry.probability, 0);
    expect(kept).toBeGreaterThan(0.7);

    // ...and the bust slot is the only way to lose anything at all.
    const lost = payoutTable()
      .filter((entry) => entry.multiplier < 1)
      .reduce((sum, entry) => sum + entry.probability, 0);
    expect(lost).toBeCloseTo(slotProbability(6), 10);
  });

  it("labels each slot by what it pays", () => {
    expect(slotTier(0)).toBe("bust");
    expect(slotTier(0.5)).toBe("loss");
    expect(slotTier(1.8)).toBe("even");
    expect(slotTier(4.2)).toBe("win");
    expect(slotTier(25)).toBe("jackpot");
  });
});

describe("dropping", () => {
  it("makes one left/right decision per peg row", () => {
    const path = dropPath(() => 0.9);
    expect(path).toHaveLength(PEG_ROWS);
    expect(path.every((step) => step === true)).toBe(true);
    expect(slotForPath(path)).toBe(PEG_ROWS); // all right = far edge
  });

  it("lands where the path says, and nowhere else", () => {
    expect(slotForPath(dropPath(() => 0.1))).toBe(0); // all left
    expect(slotForPath([true, false, true, false, true, false, false, false, false, false, false, false])).toBe(3);
  });

  it("reproduces from the same seed chain", () => {
    const rollFn = (cursor: number) => ((cursor * 48271) % 2147483647) / 2147483647;
    expect(dropPath(rollFn)).toEqual(dropPath(rollFn));
  });

  it("produces the binomial distribution from uniform rolls", () => {
    // The claim the whole payout table rests on: uniform rolls in, binomial
    // landings out. Sample a lot of drops and compare against C(12,k)/4096.
    const counts = new Array(SLOT_COUNT).fill(0);
    const trials = 40_000;
    for (let t = 0; t < trials; t++) {
      const path = dropPath((cursor) => {
        const x = Math.sin(t * 12_007 + cursor * 7919) * 10_000;
        return x - Math.floor(x);
      });
      counts[slotForPath(path)]++;
    }
    for (let slot = 0; slot < SLOT_COUNT; slot++) {
      const expected = slotProbability(slot) * trials;
      if (expected < 20) continue; // edge slots are too rare to bound tightly
      expect(counts[slot]).toBeGreaterThan(expected * 0.85);
      expect(counts[slot]).toBeLessThan(expected * 1.15);
    }
    expect(counts.reduce((a, b) => a + b, 0)).toBe(trials);
  });

  it("pays out what the landing is worth, floored", () => {
    expect(finalNetWorth(20_000, 3)).toBe(60_000);
    expect(finalNetWorth(12_345, 1.8)).toBe(Math.floor(12_345 * 1.8));
    // A bust is worth nothing, not a rounding artefact.
    expect(finalNetWorth(999_999, 0)).toBe(0);
  });

  it("knows which slots exist", () => {
    expect(isSlotLegal(0)).toBe(true);
    expect(isSlotLegal(12)).toBe(true);
    expect(isSlotLegal(13)).toBe(false);
    expect(isSlotLegal(-1)).toBe(false);
    expect(isSlotLegal(2.5)).toBe(false);
  });
});

describe("fairness", () => {
  it("takes nothing but the roll", () => {
    // dropPath's only argument is a roll function. There is nowhere for the
    // wager, the monster, the player or their history to enter the outcome.
    const constant = () => 0.75;
    expect(dropPath(constant)).toEqual(dropPath(constant));
  });

  it("prices a slot the same however valuable the wager was", () => {
    // Read the multiplier from the table rather than restating it, so a
    // rebalance cannot make this pass for the wrong reason.
    const multiplier = multiplierForSlot(3);
    for (const wager of [500, 20_000, 187_000]) {
      expect(finalNetWorth(wager, multiplier)).toBe(Math.floor(wager * multiplier));
    }
  });
});
