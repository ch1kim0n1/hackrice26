// Phase-0 contract invariants. These tests are the guardrails the four
// workstreams share: if a constant here stops being true, the spec and the
// code have drifted — fix the code, not this file, unless the doc changed.

import { describe, expect, it } from "vitest";
import {
  COOKBOOKS, MINT_SEGMENTS, RANKED_CASE_ODDS, RARITY_COMBAT_MULT,
  SCAN_BASE_ODDS, SECRET_MAX_STAR, SPEC_BANDS, SPEC_RARITY_ORDER,
  SPEC_STAR_BONUS, STAR_COMBAT_MULT, STAR_MANA_MULT, TASK_DAILY_MAX,
  maxStarsFor
} from "./spec";
import { monsterInstanceSchema, catalogCharacterSchema } from "../schemas/monster";
import { RARITY_TIERS } from "../data/lootTable";

const near = (a: number, b: number, eps = 1e-9) => Math.abs(a - b) < eps;

describe("spec constants", () => {
  it("rarity combat multipliers match the spec table", () => {
    expect(RARITY_COMBAT_MULT).toEqual({
      common: 1.0, uncommon: 1.06, rare: 1.12, epic: 1.25,
      legendary: 1.4, mythic: 1.55, secret: 1.7
    });
    // During the transition the loot table still owns combat multipliers;
    // the two must never disagree.
    for (const r of SPEC_RARITY_ORDER) {
      expect(RARITY_TIERS[r].statMultiplier).toBe(RARITY_COMBAT_MULT[r]);
    }
  });

  it("star combat multipliers match the spec table", () => {
    expect(STAR_COMBAT_MULT).toEqual({ 1: 1, 2: 1.08, 3: 1.18, 4: 1.3, 5: 1.45 });
    expect(STAR_MANA_MULT).toEqual({ 1: 1, 2: 1.1, 3: 1.2, 4: 1.35, 5: 1.5 });
  });

  it("net-worth bands tile with no gaps and match the spec table", () => {
    for (let i = 1; i < SPEC_RARITY_ORDER.length; i++) {
      const prev = SPEC_BANDS[SPEC_RARITY_ORDER[i - 1]];
      const cur = SPEC_BANDS[SPEC_RARITY_ORDER[i]];
      expect(cur.min).toBe(prev.max + 1);
      expect(cur.min).toBeGreaterThan(prev.min);
    }
    expect(SPEC_BANDS.secret.max).toBe(597_999);
  });

  it("star bonuses: 15/40/75% of band step; ★5 = step + ★2(next)", () => {
    for (let i = 0; i < SPEC_RARITY_ORDER.length - 1; i++) {
      const r = SPEC_RARITY_ORDER[i];
      const next = SPEC_RARITY_ORDER[i + 1];
      const step = SPEC_BANDS[next].min - SPEC_BANDS[r].min;
      const b = SPEC_STAR_BONUS[r];
      expect(b[2]).toBe(Math.round(step * 0.15));
      expect(b[3]).toBe(Math.round(step * 0.4));
      expect(b[4]).toBe(Math.round(step * 0.75));
      expect(b[5]).toBe(Math.round(step + (SPEC_STAR_BONUS[next][2] ?? 0)));
    }
    // Secret: ★2 only, 15% of its own extrapolated step (411,000 * .15).
    expect(SPEC_STAR_BONUS.secret).toEqual({ 1: 0, 2: 61_650 });
    expect(maxStarsFor("secret")).toBe(SECRET_MAX_STAR);
  });

  it("mint segments tile the band and sum to 1", () => {
    expect(MINT_SEGMENTS.reduce((s, m) => s + m.weight, 0)).toBeCloseTo(1, 12);
    for (let i = 1; i < MINT_SEGMENTS.length; i++) {
      expect(MINT_SEGMENTS[i].from).toBe(MINT_SEGMENTS[i - 1].to);
    }
    expect(MINT_SEGMENTS[0].from).toBe(0);
    expect(MINT_SEGMENTS[MINT_SEGMENTS.length - 1].to).toBe(1);
  });

  it("scan base odds and every cookbook/ranked table sums to 1", () => {
    const sum = (o: Record<string, number>) => Object.values(o).reduce((a, b) => a + b, 0);
    expect(near(sum(SCAN_BASE_ODDS), 1)).toBe(true);
    for (const book of COOKBOOKS) {
      expect(near(sum(book.odds), 1)).toBe(true);
    }
    for (const rank of Object.keys(RANKED_CASE_ODDS)) {
      expect(near(sum(RANKED_CASE_ODDS[rank as keyof typeof RANKED_CASE_ODDS]), 1)).toBe(true);
    }
  });

  it("task economy caps at 1,250 coins/day", () => {
    expect(TASK_DAILY_MAX).toBe(1250);
  });
});

describe("monster contract", () => {
  const baseMove = {
    id: "verdant-slam", name: "Verdant Slam", power: 1.4, accuracy: 95, manaCost: 0
  };
  const catalog = {
    id: "broccoli-bud", name: "Broccoli Bud", colorHex: "#5FCB82",
    imageKey: "broccoli-bud", baseHealth: 120, baseAttack: 40,
    moves: [baseMove, { ...baseMove, id: "move-two", name: "Two" }, { ...baseMove, id: "move-three", name: "Three" }]
  };

  it("accepts a valid catalog character", () => {
    expect(catalogCharacterSchema.safeParse(catalog).success).toBe(true);
  });

  it("rejects a mana-costed standard move and a special without baseMana", () => {
    const badMove = { ...catalog, moves: [...catalog.moves.slice(0, 2), { ...baseMove, id: "move-four", name: "Four", manaCost: 5 }] };
    expect(catalogCharacterSchema.safeParse(badMove).success).toBe(false);
    const badSpecial = { ...catalog, special: { ...baseMove, id: "sp-bud", name: "SP", manaCost: 10 } };
    expect(catalogCharacterSchema.safeParse(badSpecial).success).toBe(false);
  });

  const monster = {
    id: "3f6f2599-0d6d-4b3f-9e37-9b1e1d0a2c51",
    characterId: "broccoli-bud", rarity: "common", stars: 1,
    baseHealth: 120, baseAttack: 40, baseMintValue: 700,
    source: "cookbook", mintedAt: new Date().toISOString()
  };

  it("accepts a valid instance; enforces secret ★2 cap and mana gating", () => {
    expect(monsterInstanceSchema.safeParse(monster).success).toBe(true);
    expect(monsterInstanceSchema.safeParse({ ...monster, rarity: "secret", stars: 3 }).success).toBe(false);
    expect(monsterInstanceSchema.safeParse({ ...monster, baseMana: 50 }).success).toBe(false);
    expect(monsterInstanceSchema.safeParse({
      ...monster, rarity: "epic", baseMana: 50
    }).success).toBe(true);
  });

  it("requires provenance on scan mints", () => {
    const scan = { ...monster, source: "scan" };
    expect(monsterInstanceSchema.safeParse(scan).success).toBe(false);
    expect(monsterInstanceSchema.safeParse({
      ...scan, provenance: { barcode: "0123456", nutrition: { protein_g: 10 }, nutritionSource: "openfoodfacts" }
    }).success).toBe(true);
  });
});
