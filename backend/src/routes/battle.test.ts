import { describe, it, expect } from "vitest";
import { simulate, SimUnit } from "./battle";

// ============================================================================
// Battle engine determinism + cross-port parity tests.
//
// The Swift BattleEngine (ios/Sources/BattleKit/BattleEngine.swift) is the
// reference implementation. This TypeScript port
// (backend/src/routes/battle.ts) MUST produce identical outcomes for the same
// squads + seed, because docs/BATTLE-SYSTEM.md §5 makes the server
// authoritative for PvP: "Both clients replay the identical event list.
// Clients never compute outcomes." If the two ports drift, a PvP battle
// resolved on the server would not match the replay the clients animate,
// which is a correctness contract violation.
//
// The fixtures below mirror BattleFixtures in
// ios/Tests/BattleKitTests/BattleEngineTests.swift. The Swift test suite
// records the canonical winner/rounds for each seed; the assertions here
// check the TS port agrees.
// ============================================================================

// --- Fixtures (mirror BattleFixtures in BattleEngineTests.swift) ---
// Stats are PRE rarity/fusion scaling, matching the Swift baseStats. The
// Swift engine scales by rarity * star inside FoodCharacter.stats and the TS
// port now does too (B-001 fixed); we feed already-scaled stats here to
// isolate the parity check to the simulation loop itself.

function scaled(rarityMult: number, fusionTier: number, base: { power: number; guard: number; vitality: number; tempo: number }) {
  const m = rarityMult * (1 + 0.08 * fusionTier);
  return { power: base.power * m, guard: base.guard * m, vitality: base.vitality * m, tempo: base.tempo * m };
}

const RARITY_MULT = { common: 1.0, rare: 1.12, epic: 1.25, legendary: 1.4 } as const;

const proteinHero = scaled(RARITY_MULT.rare, 0, { power: 80, guard: 40, vitality: 50, tempo: 60 });
const fiberGuardian = scaled(RARITY_MULT.epic, 0, { power: 40, guard: 90, vitality: 60, tempo: 30 });
const vitaminSage = scaled(RARITY_MULT.common, 0, { power: 30, guard: 30, vitality: 80, tempo: 50 });
const hydrationRogue = scaled(RARITY_MULT.legendary, 0, { power: 50, guard: 50, vitality: 50, tempo: 90 });
const proteinBruiser = scaled(RARITY_MULT.common, 0, { power: 70, guard: 50, vitality: 40, tempo: 40 });
const fiberScout = scaled(RARITY_MULT.rare, 0, { power: 35, guard: 60, vitality: 55, tempo: 45 });

const squadA: SimUnit[] = [
  { id: "00000000-0000-0000-0000-000000000001", name: "Protein Hero", element: "protein", ...proteinHero },
  { id: "00000000-0000-0000-0000-000000000002", name: "Fiber Guardian", element: "fiber", ...fiberGuardian },
  { id: "00000000-0000-0000-0000-000000000003", name: "Vitamin Sage", element: "vitamin", ...vitaminSage }
];

const squadB: SimUnit[] = [
  { id: "00000000-0000-0000-0000-000000000004", name: "Hydration Rogue", element: "hydration", ...hydrationRogue },
  { id: "00000000-0000-0000-0000-000000000005", name: "Protein Bruiser", element: "protein", ...proteinBruiser },
  { id: "00000000-0000-0000-0000-000000000006", name: "Fiber Scout", element: "fiber", ...fiberScout }
];

// --- Canonical outcomes from the Swift reference engine ---
// These were produced by running BattleEngineTests.swift on the Swift engine
// with the same fixtures + seeds. The TS port MUST agree. If it does not,
// the drift is a blocker (see QA report B-001..B-005).
//
// Swift winnerSide: 0 = squadA wins, 1 = squadB wins.
// TS winner: "A" | "B".
const SWIFT_RESULTS: Record<string, { winner: "A" | "B"; rounds: number }> = {
  // Recorded from BattleEngineTests.testZZZ_recordCanonicalOutcomes on the
  // Swift reference engine (ios/Sources/BattleKit/BattleEngine.swift) using
  // the same fixtures above. The TS port MUST agree.
  //
  // These assertions previously recorded known drift (B-001..B-005) and were
  // expected to fail; the port now agrees with the Swift reference on every
  // fixture. If one starts failing, the drift is back and is a blocker.
  "0xDEADBEEFCAFEBABE": { winner: "A", rounds: 3 },
  "42": { winner: "A", rounds: 6 },
  "1": { winner: "B", rounds: 6 },
  "100": { winner: "A", rounds: 4 },
  "9999": { winner: "B", rounds: 7 }
};

describe("battle engine — determinism (TS port)", () => {
  it("same seed + same squads produces identical output", () => {
    const seed = 0xDEADBEEFCAFEBABEn;
    const r1 = simulate(squadA, squadB, seed);
    const r2 = simulate(squadA, squadB, seed);
    expect(r1).toEqual(r2);
  });

  it("different seeds produce different event streams", () => {
    const r1 = simulate(squadA, squadB, 1n);
    const r2 = simulate(squadA, squadB, 2n);
    expect(r1.events).not.toEqual(r2.events);
  });

  it("winner is always A or B", () => {
    for (const seed of [1n, 100n, 9999n, 0xFFFFFFFFn]) {
      const r = simulate(squadA, squadB, seed);
      expect(["A", "B"]).toContain(r.winner);
    }
  });

  it("rounds are bounded by maxRounds + 1", () => {
    const r = simulate(squadA, squadB, 0xCAFEn);
    expect(r.rounds).toBeGreaterThanOrEqual(1);
    expect(r.rounds).toBeLessThanOrEqual(13);
  });

  it("replay starts with battleStart and ends with victory", () => {
    const r = simulate(squadA, squadB, 42n);
    expect(r.events[0]).toMatchObject({ event: "battleStart" });
    expect(r.events[r.events.length - 1]).toMatchObject({ event: "victory" });
  });
});

describe("battle engine — Swift/TS parity (BLOCKER if fails)", () => {
  // These tests assert the TS port agrees with the Swift reference engine.
  // They are EXPECTED TO FAIL until the port drift is fixed (see QA report
  // B-001..B-005). The failure is the point: it surfaces the drift.
  for (const [seedStr, expected] of Object.entries(SWIFT_RESULTS)) {
    it(`seed ${seedStr}: TS winner matches Swift winner=${expected.winner} rounds=${expected.rounds}`, () => {
      const r = simulate(squadA, squadB, BigInt(seedStr));
      // NOTE: this will fail until B-001..B-005 are fixed.
      expect(r.winner).toBe(expected.winner);
      expect(r.rounds).toBe(expected.rounds);
    });
  }

  it("attack events include move name and typeMod (parity with Swift)", () => {
    const r = simulate(squadA, squadB, 42n);
    const attacks = r.events.filter((e) => (e as { event: string }).event === "attack");
    expect(attacks.length).toBeGreaterThan(0);
    for (const a of attacks) {
      // Swift emits: attackerID, defenderID, move, damage, crit, typeMod.
      // TS currently emits only: attacker, defender, damage, crit (B-004).
      expect(a).toHaveProperty("move");
      expect(a).toHaveProperty("typeMod");
    }
  });

  it("uses both basic and signature moves (parity with Swift 50/50 pick)", () => {
    // Swift picks basic vs signature with 50% chance (BattleEngine.swift:108).
    // TS always uses signature move power 1.45 (battle.ts:102) — B-003.
    const r = simulate(squadA, squadB, 42n);
    const attacks = r.events.filter((e) => (e as { event: string }).event === "attack");
    const moveNames = new Set(attacks.map((a) => (a as { move?: string }).move).filter(Boolean));
    // Swift would produce both "Strike" (basic) and "<name> Special" (signature).
    expect(moveNames.has("Strike")).toBe(true);
  });
});
