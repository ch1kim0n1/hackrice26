import { describe, it, expect } from "vitest";
import { rollRarity, openOnce, freshPity, PityState, EPIC_PITY, LEGENDARY_PITY } from "./pity";

describe("capsule odds + pity (BATTLE-SYSTEM §6)", () => {
  it("base odds boundaries: 70/22/7/1", () => {
    expect(rollRarity(0)).toBe("common");
    expect(rollRarity(0.699)).toBe("common");
    expect(rollRarity(0.7)).toBe("rare");
    expect(rollRarity(0.919)).toBe("rare");
    expect(rollRarity(0.92)).toBe("epic");
    expect(rollRarity(0.989)).toBe("epic");
    expect(rollRarity(0.99)).toBe("legendary");
    expect(rollRarity(0.999999)).toBe("legendary");
  });

  it("guarantees Epic+ on the 15th open when rolling all commons", () => {
    let state = freshPity();
    const rolls: string[] = [];
    for (let i = 0; i < EPIC_PITY; i++) {
      const r = openOnce(state, 0.1); // always a natural common
      rolls.push(r.rarity);
      state = r.state;
    }
    // first 14 commons, 15th forced to epic
    expect(rolls.slice(0, 14).every((r) => r === "common")).toBe(true);
    expect(rolls[14]).toBe("epic");
    expect(state.sinceEpic).toBe(0);
  });

  it("guarantees Legendary on the 40th open (with intervening epic pity)", () => {
    let state = freshPity();
    let fortieth = "";
    for (let i = 0; i < LEGENDARY_PITY; i++) {
      const r = openOnce(state, 0.1);
      state = r.state;
      if (i === LEGENDARY_PITY - 1) fortieth = r.rarity;
    }
    expect(fortieth).toBe("legendary");
    expect(state.sinceLegendary).toBe(0);
  });

  it("a natural legendary resets both counters", () => {
    const prev: PityState = { sinceEpic: 5, sinceLegendary: 10, totalOpens: 20 };
    const r = openOnce(prev, 0.999); // natural legendary
    expect(r.rarity).toBe("legendary");
    expect(r.state.sinceEpic).toBe(0);
    expect(r.state.sinceLegendary).toBe(0);
    expect(r.forced).toBeNull();
  });

  it("a natural epic resets epic counter but advances legendary counter", () => {
    const prev: PityState = { sinceEpic: 5, sinceLegendary: 10, totalOpens: 20 };
    const r = openOnce(prev, 0.95); // natural epic
    expect(r.rarity).toBe("epic");
    expect(r.state.sinceEpic).toBe(0);
    expect(r.state.sinceLegendary).toBe(11);
  });
});
