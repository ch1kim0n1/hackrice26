import { describe, it, expect, beforeAll } from "vitest";
import type {
  runDungeonFloors as runDungeonFloorsT,
  dungeonFloorReward as dungeonFloorRewardT,
  dungeonFloorMultiplier as dungeonFloorMultiplierT,
  SimUnit
} from "./battle";

// Endless dungeon (spec §5): exactly 3 monsters, floors escalate until the
// party wipes; boss every 5th; HP persists in-run and faints are run-scoped.
// FloorReward = 100 + 25×(floor−1), ×3 on boss floors.

let runDungeonFloors: typeof runDungeonFloorsT;
let dungeonFloorReward: typeof dungeonFloorRewardT;
let dungeonFloorMultiplier: typeof dungeonFloorMultiplierT;
let DUNGEON_SAFETY_CAP: number;

beforeAll(async () => {
  process.env.NUTRIQUEST_DB = "memory";
  ({ runDungeonFloors, dungeonFloorReward, dungeonFloorMultiplier, DUNGEON_SAFETY_CAP } = await import("./battle"));
});

const STRONG: SimUnit[] = [0, 1, 2].map((i) => ({
  id: `s${i}`,
  name: `Strong ${i}`,
  baseHealth: 400,
  baseAttack: 200,
  rarity: "legendary",
  star: 5
}));
const WEAK: SimUnit[] = [0, 1, 2].map((i) => ({
  id: `w${i}`,
  name: `Weak ${i}`,
  baseHealth: 5,
  baseAttack: 5,
  rarity: "common",
  star: 1
}));

describe("dungeon — floors until wipe", () => {
  it("a weak party dies on floor 1; feed records the losing floor", () => {
    const { floorsCleared, feed } = runDungeonFloors(WEAK, "dead-run");
    expect(floorsCleared).toBe(0);
    expect(feed).toHaveLength(1);
    expect(feed[0].won).toBe(false);
    expect(feed[0].reward).toBe(0);
  });

  it("a strong party clears deep floors incl. bosses", () => {
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

  it("no run exceeds the safety cap", () => {
    const god = STRONG.map((u) => ({ ...u, baseHealth: 9999, baseAttack: 9999 }));
    const { floorsCleared } = runDungeonFloors(god, "god-run");
    expect(floorsCleared).toBeLessThanOrEqual(DUNGEON_SAFETY_CAP);
  });
});

describe("dungeon — spec formulas", () => {
  it("floor reward is 100 + 25×(floor−1), ×3 on boss floors", () => {
    expect(dungeonFloorReward(1)).toBe(100);
    expect(dungeonFloorReward(2)).toBe(125);
    expect(dungeonFloorReward(4)).toBe(175);
    expect(dungeonFloorReward(5)).toBe(600); // boss: (100 + 25×4) × 3
    expect(dungeonFloorReward(10)).toBe(975); // boss: (100 + 25×9) × 3
    expect(dungeonFloorReward(11)).toBe(350);
  });

  it("enemy multiplier is 1 + 0.05×(floor−1), ×1.25 on boss floors", () => {
    expect(dungeonFloorMultiplier(1)).toBeCloseTo(1);
    expect(dungeonFloorMultiplier(2)).toBeCloseTo(1.05);
    expect(dungeonFloorMultiplier(5)).toBeCloseTo(1.2 * 1.25);
    expect(dungeonFloorMultiplier(21)).toBeCloseTo(2.0);
  });
});
