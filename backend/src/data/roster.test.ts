import { describe, it, expect } from "vitest";
import { ROSTER, ROSTER_SIZE, rosterCharacter, rosterCharacterSchema, asCharacter } from "./roster";
import { attacksFor } from "./attacks";
import { RARITY_ORDER } from "./lootTable";

// ============================================================================
// The master catalog (spec §2 checklist).
//
// The file is authored by hand, so these are the checks a human editing JSON
// at 3am will actually trip over: a 15th character, a reused or renamed id,
// a missing special, a stat outside the design envelope — and the fields the
// spec removed (element, baseStats, statType) creeping back in.
// ============================================================================

describe("master catalog", () => {
  it("has exactly 14 characters with unique permanent ids", () => {
    expect(ROSTER_SIZE).toBe(14);
    expect(new Set(ROSTER.map((c) => c.id)).size).toBe(14);
    for (const c of ROSTER) {
      // Lower-kebab, never derived from the display name.
      expect(c.id).toMatch(/^[a-z][a-z0-9-]{2,39}$/);
      expect(rosterCharacter(c.id)).toBe(c);
    }
  });

  it("gives every character the complete spec record", () => {
    for (const c of ROSTER) {
      expect(rosterCharacterSchema.safeParse(c).success).toBe(true);
      expect(c.baseHealth).toBeGreaterThanOrEqual(40);
      expect(c.baseHealth).toBeLessThanOrEqual(200);
      expect(c.baseAttack).toBeGreaterThanOrEqual(20);
      expect(c.baseAttack).toBeLessThanOrEqual(100);
      expect(c.baseMana).toBeGreaterThan(0);
      expect(c.tagline.length).toBeGreaterThan(0);
      expect(c.bio.length).toBeGreaterThanOrEqual(10);
      expect(c.imageKey).toBeTruthy();
      expect(c.colorHex).toMatch(/^#[0-9a-fA-F]{6}$/);
    }
  });

  it("carries no legacy fields — no element, no baseStats blob, no statType, no intrinsic rarity", () => {
    for (const c of ROSTER) {
      const raw = c as unknown as Record<string, unknown>;
      expect(raw).not.toHaveProperty("element");
      expect(raw).not.toHaveProperty("baseStats");
      expect(raw).not.toHaveProperty("statType");
      // Rarity is rolled per instance at mint; the design itself has none.
      expect(raw).not.toHaveProperty("rarity");
    }
  });

  it("authors exactly 3 standard moves + 1 Mana Special per character", () => {
    for (const c of ROSTER) {
      expect(c.moves).toHaveLength(3);
      for (const move of c.moves) {
        expect(move.manaCost).toBe(0);
        expect(move.accuracy).toBeGreaterThanOrEqual(1);
        expect(move.accuracy).toBeLessThanOrEqual(100);
        expect(move.id.startsWith(`${c.id}-`)).toBe(true);
        if (move.statusChance !== undefined) expect(move.statusEffect).toBeDefined();
      }
      expect(c.special).toBeDefined();
      expect(c.special!.manaCost).toBeGreaterThan(0);
      expect(c.special!.id.startsWith(`${c.id}-`)).toBe(true);
    }
  });

  it("attacksFor returns 3 standards for everyone, +1 Special at Epic and above", () => {
    for (const c of ROSTER) {
      for (const rarity of RARITY_ORDER) {
        const legal = attacksFor(c.id, rarity);
        const epicPlus = ["epic", "legendary", "mythic", "secret"].includes(rarity);
        expect(legal).toHaveLength(epicPlus ? 4 : 3);
        expect(legal.some((m) => m.kind === "special")).toBe(epicPlus);
        expect(legal.filter((m) => m.kind === "standard")).toHaveLength(3);
      }
    }
  });

  it("has globally unique move ids across the catalog", () => {
    const ids = ROSTER.flatMap((c) => [...c.moves.map((m) => m.id), c.special!.id]);
    expect(new Set(ids).size).toBe(ids.length);
  });

  it("asCharacter stamps the rolled rarity onto the instance and keeps Mana Epic+-only", () => {
    const bud = rosterCharacter("broccoli-bud")!;
    const common = asCharacter(bud, "common");
    expect(common.rarity).toBe("common");
    expect(common.baseHealth).toBe(bud.baseHealth);
    expect(common.baseMana).toBeUndefined();
    expect(common.special).toBeUndefined();
    expect(common.moves).toHaveLength(3);

    const epic = asCharacter(bud, "epic");
    expect(epic.baseMana).toBe(bud.baseMana);
    expect(epic.special).toBe(bud.special!.id);

    // A generated combat base overrides the catalog's (scan mints).
    const generated = asCharacter(bud, "rare", { baseHealth: 140, baseAttack: 70 });
    expect(generated.baseHealth).toBe(140);
    expect(generated.baseAttack).toBe(70);
  });
});
