import { describe, it, expect } from "vitest";
import { ROSTER, ROSTER_SIZE, rosterByRarity, rosterCharacter, rosterCharacterSchema } from "./roster";
import { CHARACTERS } from "./lootTable";
import { RARITY_ORDER } from "./lootTable";
import { STAT_KEYS } from "../schemas/gameSchemas";

// ============================================================================
// The MVP roster (#92).
//
// The file is authored by hand, so these are the checks a human editing JSON
// at 3am will actually trip over: a missing tier, a stat that contradicts the
// element, an id that no longer matches the art it points at.
// ============================================================================

describe("roster", () => {
  it("has exactly 14 characters with unique ids", () => {
    expect(ROSTER).toHaveLength(ROSTER_SIZE);
    expect(new Set(ROSTER.map((c) => c.id)).size).toBe(ROSTER_SIZE);
  });

  it("spreads across every rarity tier", () => {
    // Acceptance criterion on #92 — a roster that skips Mythic would leave a
    // reward bracket with nothing to award.
    for (const rarity of RARITY_ORDER) {
      expect(rosterByRarity(rarity).length).toBeGreaterThan(0);
    }
  });

  it("gives every character a complete Pokédex entry", () => {
    for (const character of ROSTER) {
      expect(rosterCharacterSchema.safeParse(character).success).toBe(true);
      expect(character.bio.length).toBeGreaterThan(40);
      expect(character.tagline.endsWith(".")).toBe(true);
    }
  });

  it("keeps every stat inside the canonical 10..100 range", () => {
    for (const character of ROSTER) {
      for (const key of STAT_KEYS) {
        expect(character.baseStats[key]).toBeGreaterThanOrEqual(10);
        expect(character.baseStats[key]).toBeLessThanOrEqual(100);
        expect(Number.isInteger(character.baseStats[key])).toBe(true);
      }
    }
  });

  it("makes each character's element match its own strongest stat", () => {
    // loadRoster() throws on import if this is violated, so reaching this test
    // at all is most of the proof; assert it explicitly anyway.
    const expected: Record<string, string> = {
      power: "protein",
      guard: "fiber",
      vitality: "vitamin",
      tempo: "hydration"
    };
    for (const character of ROSTER) {
      const dominant = STAT_KEYS.reduce((best, key) =>
        character.baseStats[key] > character.baseStats[best] ? key : best
      );
      expect(expected[dominant]).toBe(character.element);
    }
  });

  it("gets stronger as rarity climbs", () => {
    // Base stats are pre-rarity-multiplier, but a Secret should still read as
    // a better creature than a Common before any scaling is applied.
    const totalFor = (rarity: string) => {
      const members = ROSTER.filter((c) => c.rarity === rarity);
      const sum = members.reduce(
        (acc, c) => acc + STAT_KEYS.reduce((s, k) => s + c.baseStats[k], 0),
        0
      );
      return sum / members.length;
    };
    let previous = 0;
    for (const rarity of RARITY_ORDER) {
      const average = totalFor(rarity);
      expect(average).toBeGreaterThan(previous);
      previous = average;
    }
  });

  it("points every image key at its own id", () => {
    // #93 checks art in under these keys; a mismatch is a silently missing
    // picture rather than a crash, so pin it here.
    for (const character of ROSTER) {
      expect(character.imageKey).toBe(character.id);
    }
  });

  it("names only characters the loot table already knows", () => {
    // The roster curates the existing catalogue rather than forking it, so
    // crates, art seeds and flavour text all keep working.
    for (const character of ROSTER) {
      expect(CHARACTERS[character.id]).toBeDefined();
      expect(CHARACTERS[character.id].rarity).toBe(character.rarity);
      expect(CHARACTERS[character.id].statType).toBe(character.element);
    }
  });

  it("looks up by id", () => {
    expect(rosterCharacter("the-first-seed")?.rarity).toBe("secret");
    expect(rosterCharacter("not-a-character")).toBeUndefined();
  });
});
