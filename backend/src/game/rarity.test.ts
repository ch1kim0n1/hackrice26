import { describe, it, expect } from "vitest";
import { assignRarity } from "./rarity";

describe("rarity assignment (BATTLE-SYSTEM §2)", () => {
  it("scarcity percentile sets the base tier", () => {
    expect(assignRarity(0.03, false, 1)).toBe("legendary"); // bottom 5%
    expect(assignRarity(0.15, false, 1)).toBe("epic"); // bottom 20%
    expect(assignRarity(0.4, false, 1)).toBe("rare"); // bottom 50%
    expect(assignRarity(0.8, false, 1)).toBe("common"); // common
  });

  it("high price bumps rarity one step", () => {
    expect(assignRarity(0.8, true, 1)).toBe("rare"); // common -> rare
    expect(assignRarity(0.4, true, 1)).toBe("epic"); // rare -> epic
    expect(assignRarity(0.03, true, 1)).toBe("legendary"); // already max, stays
  });

  it("NOVA 4 caps at Epic unless scarcity is extreme (cursed legendary)", () => {
    // would be legendary by price bump, but NOVA 4 caps at epic
    expect(assignRarity(0.15, true, 4)).toBe("epic");
    // extreme scarcity overrides the NOVA cap -> cursed legendary
    expect(assignRarity(0.03, false, 4)).toBe("legendary");
  });
});
