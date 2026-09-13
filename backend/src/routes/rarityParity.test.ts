import { describe, it, expect } from "vitest";
import { CHARACTERS, RARITY_ORDER, RARITY_TIERS, RARITY_TOTAL } from "../data/lootTable";
import { RARITY_MULT } from "./battle";
import { Rarity } from "../types";

// ============================================================================
// Rarity parity between the loot table and everything that consumes a rarity.
//
// The loot table was widened to seven tiers while battle.ts kept a
// hand-written four-tier multiplier map. Squad validation rejects any tier
// missing from that map, so uncommon, mythic and secret pulls -- about 16% of
// all crate drops -- were droppable but could not be taken into battle.
//
// These tests pin the contract that made that possible: every tier the loot
// table can drop must be battle-legal, and the multipliers must rise with
// scarcity. They are deliberately derived from RARITY_TIERS rather than
// listing tiers by hand, so adding an eighth tier cannot quietly pass.
// ============================================================================

// Squad validation in battle.ts admits a rarity if and only if it is a key of
// RARITY_MULT, so that map is the real definition of "battle-legal". Importing
// it means this test fails if battle.ts ever goes back to a hand-written list.
const battleAcceptedTiers = new Set<string>(Object.keys(RARITY_MULT));

describe("rarity parity", () => {
  it("every tier the loot table can drop is battle-legal", () => {
    const droppable = new Set(Object.values(CHARACTERS).map((c) => c.rarity));
    const rejected = [...droppable].filter((r) => !battleAcceptedTiers.has(r));
    expect(rejected).toEqual([]);
  });

  it("battle's multiplier map covers exactly the loot table's tiers", () => {
    expect(Object.keys(RARITY_MULT).sort()).toEqual([...RARITY_ORDER].sort());
    for (const id of RARITY_ORDER) {
      expect(RARITY_MULT[id]).toBe(RARITY_TIERS[id].statMultiplier);
      expect(Number.isFinite(RARITY_MULT[id])).toBe(true);
    }
  });

  it("multipliers increase with scarcity, so a rarer pull is never a downgrade", () => {
    const multipliers = RARITY_ORDER.map((id) => RARITY_TIERS[id].statMultiplier);
    const ascending = [...multipliers].sort((a, b) => a - b);
    expect(multipliers).toEqual(ascending);
    expect(new Set(multipliers).size).toBe(multipliers.length);
  });

  it("preserves the original four multipliers, so existing matchups are unchanged", () => {
    // Widening the ladder must not re-balance battles that already worked.
    expect(RARITY_TIERS.common.statMultiplier).toBe(1.0);
    expect(RARITY_TIERS.rare.statMultiplier).toBe(1.12);
    expect(RARITY_TIERS.epic.statMultiplier).toBe(1.25);
    expect(RARITY_TIERS.legendary.statMultiplier).toBe(1.4);
  });

  it("the seven tiers are exactly the Rarity union, in scarcity order", () => {
    const expected: Rarity[] = [
      "common", "uncommon", "rare", "epic", "legendary", "mythic", "secret"
    ];
    expect(RARITY_ORDER).toEqual(expected);
  });

  it("weights still partition the space exactly", () => {
    const sum = RARITY_ORDER.reduce((acc, id) => acc + RARITY_TIERS[id].weight, 0);
    expect(sum).toBe(RARITY_TOTAL);
  });

  it("every tier is reachable from at least one crate character", () => {
    const covered = new Set(Object.values(CHARACTERS).map((c) => c.rarity));
    for (const id of RARITY_ORDER) expect(covered.has(id)).toBe(true);
  });
});
