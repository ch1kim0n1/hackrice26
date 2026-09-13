import { describe, it, expect, beforeEach } from "vitest";
import { runDungeonFloors, DUNGEON_MAX_FLOOR } from "./battle";
import type { SimUnit } from "./battle";

// Infinite dungeon: floors escalate until the party wipes; boss every 5th;
// depth becomes idle income.

const STRONG: SimUnit[] = [0, 1, 2, 3, 4].map((i) => ({
  id: `s${i}`, name: `Strong ${i}`, element: (["protein", "fiber", "vitamin", "hydration"] as const)[i % 4],
  power: 220, guard: 220, vitality: 220, tempo: 220, fusionTier: 5
}));
const WEAK: SimUnit[] = [
  { id: "w1", name: "Weak", element: "fiber", power: 5, guard: 5, vitality: 5, tempo: 5, fusionTier: 0 }
];

describe("dungeon — floors until wipe", () => {
  it("a weak unit dies on floor 1; feed records the losing floor", () => {
    const { floorsCleared, feed } = runDungeonFloors(WEAK, "dead-run");
    expect(floorsCleared).toBe(0);
    expect(feed).toHaveLength(1);
    expect(feed[0].won).toBe(false);
  });

  it("a strong party clears deep floors incl. bosses, and rewards scale", () => {
    const { floorsCleared, feed } = runDungeonFloors(STRONG, "hero-run");
    expect(floorsCleared).toBeGreaterThanOrEqual(10);
    expect(feed.some((f) => f.boss && f.won)).toBe(true);
  });

  it("same seed replays identically", () => {
    const a = runDungeonFloors(STRONG, "same-seed");
    const b = runDungeonFloors(STRONG, "same-seed");
    expect(a.floorsCleared).toBe(b.floorsCleared);
    expect(a.feed).toEqual(b.feed);
  });

  it("no run exceeds the floor cap", () => {
    const { floorsCleared } = runDungeonFloors(STRONG.map((u) => ({ ...u, power: 999, vitality: 999 })), "god-run");
    expect(floorsCleared).toBeLessThanOrEqual(DUNGEON_MAX_FLOOR);
  });
});
