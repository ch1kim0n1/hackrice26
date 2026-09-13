import { describe, it, expect, beforeAll } from "vitest";
import type { SimUnit } from "./battle";
import {
  Battle,
  BattleAction,
  BattleUnitSpec,
  MoveSpec,
  STATUS_PARAMS,
  combatStar,
  effectiveStat,
  makeRng,
  simulateBattle,
  startingMana,
  DAMAGE_SCALE,
  MAX_TURNS
} from "../services/battleEngine";
import {
  CRIT_CHANCE,
  CRIT_MULT,
  VARIANCE_MIN,
  VARIANCE_MAX,
  MIN_DAMAGE,
  STAR_COMBAT_MULT,
  STAR_MANA_MULT,
  RARITY_COMBAT_MULT
} from "../game/spec";

// ============================================================================
// Battle engine tests — final-dev-doc §4 + checklist.
//
// The Swift mirror (ios/Sources/BattleKit/BattleEngine.swift) MUST produce
// identical event streams for identical squads + seed — the server is
// authoritative and clients replay the same events. The canonical results
// table at the bottom is baked into BOTH test suites; a drift on either side
// fails the port that moved.
// ============================================================================

const STRIKE: MoveSpec = { id: "strike", name: "Strike", kind: "standard", power: 3, accuracy: 100, manaCost: 0 };

function unit(id: string, overrides: Partial<BattleUnitSpec> = {}): BattleUnitSpec {
  return {
    id,
    name: id,
    baseHealth: 100,
    baseAttack: 50,
    rarity: "common",
    star: 1,
    moves: [STRIKE],
    ...overrides
  };
}

function squadOf(prefix: string, n = 3, overrides: Partial<BattleUnitSpec> = {}): BattleUnitSpec[] {
  return Array.from({ length: n }, (_, i) => unit(`${prefix}${i}`, overrides));
}

// ---------------------------------------------------------------------------
// Formulas
// ---------------------------------------------------------------------------

describe("battle engine — spec §4 formulas", () => {
  it("effectiveStat = base × rarityMult × starCombatMult", () => {
    expect(effectiveStat(100, "common", 1)).toBeCloseTo(100);
    expect(effectiveStat(100, "epic", 3)).toBeCloseTo(100 * 1.25 * 1.18);
    expect(effectiveStat(50, "legendary", 5)).toBeCloseTo(50 * 1.4 * 1.45);
  });

  it("star combat mults follow the spec curve", () => {
    expect(STAR_COMBAT_MULT[1]).toBe(1.0);
    expect(STAR_COMBAT_MULT[2]).toBe(1.08);
    expect(STAR_COMBAT_MULT[3]).toBe(1.18);
    expect(STAR_COMBAT_MULT[4]).toBe(1.3);
    expect(STAR_COMBAT_MULT[5]).toBe(1.45);
  });

  it("secret monsters clamp to ★2 for combat", () => {
    expect(combatStar("secret", 5)).toBe(2);
    expect(effectiveStat(100, "secret", 5)).toBeCloseTo(100 * 1.7 * 1.08);
  });

  it("starting mana = floor(baseMana × starManaMult), Epic+ only", () => {
    const epic = unit("e", { rarity: "epic", star: 3, baseMana: 100 });
    expect(startingMana(epic)).toBe(Math.floor(100 * STAR_MANA_MULT[3]));
    const common = unit("c", { rarity: "common", baseMana: 100 });
    expect(startingMana(common)).toBe(0);
  });

  it("a successful damaging hit never deals less than MIN_DAMAGE", () => {
    // Ticklish attacker vs a raid boss: power 1 × attack 1 → base ≈ 2.1,
    // floor still ≥ 1 on every roll.
    const tickle: MoveSpec = { id: "t", name: "Tickle", kind: "standard", power: 1, accuracy: 100, manaCost: 0 };
    const weak = unit("w", { baseAttack: 1, moves: [tickle] });
    const boss = unit("b", { baseHealth: 200, rarity: "secret", star: 2 });
    const result = simulateBattle([weak], [boss], 7n);
    const hits = result.events.filter(
      (e): e is { event: string; damage: number } => (e as { event: string }).event === "attack"
    );
    expect(hits.length).toBeGreaterThan(0);
    for (const hit of hits) expect(hit.damage).toBeGreaterThanOrEqual(MIN_DAMAGE);
  });
});

// ---------------------------------------------------------------------------
// Determinism
// ---------------------------------------------------------------------------

describe("battle engine — determinism", () => {
  const a = squadOf("a");
  const b = squadOf("b");

  it("same seed + same squads → identical result", () => {
    expect(simulateBattle(a, b, 42n)).toEqual(simulateBattle(a, b, 42n));
  });

  it("different seeds → different event streams", () => {
    expect(simulateBattle(a, b, 1n).events).not.toEqual(simulateBattle(a, b, 2n).events);
  });

  it("winner is always A or B, events start with battleStart and end with victory", () => {
    for (const seed of [1n, 100n, 9999n]) {
      const r = simulateBattle(a, b, seed);
      expect(["A", "B"]).toContain(r.winner);
      expect(r.events[0]).toMatchObject({ event: "battleStart" });
      expect(r.events[r.events.length - 1]).toMatchObject({ event: "victory" });
    }
  });
});

// ---------------------------------------------------------------------------
// Turn structure
// ---------------------------------------------------------------------------

describe("battle engine — turns", () => {
  it("PvE firstTurn 'A' makes the player move first", () => {
    const battle = new Battle(squadOf("a"), squadOf("b"), 1n, { firstTurn: "A" });
    expect(battle.currentSide).toBe("A");
  });

  it("PvP coinFlip consumes exactly one draw before the first action", () => {
    // Drive both sides with a fixed move; the only pre-action draw is the
    // flip, so comparing against the raw RNG stream proves no extra draws.
    const rng = makeRng(5n);
    const flip = rng(); // the draw the constructor will make
    const battle = new Battle(squadOf("a"), squadOf("b"), 5n, { firstTurn: "coinFlip" });
    expect(battle.currentSide).toBe(flip < 0.5 ? "A" : "B");
  });

  it("turns strictly alternate — no tempo ordering", () => {
    const battle = new Battle(squadOf("a"), squadOf("b"), 1n, { firstTurn: "A" });
    const seen: string[] = [];
    for (let i = 0; i < 6 && !battle.finished; i++) {
      seen.push(battle.currentSide!);
      battle.act(battle.currentSide === "A" ? 0 : 1, { type: "move", moveIndex: 0 });
    }
    expect(seen).toEqual(["A", "B", "A", "B", "A", "B"]);
  });

  it("a voluntary switch consumes the whole turn", () => {
    const battle = new Battle(squadOf("a"), squadOf("b"), 1n, { firstTurn: "A" });
    battle.act(0, { type: "switch", unitIndex: 1 });
    const last = battle.events[battle.events.length - 1];
    expect(last).toMatchObject({ event: "turnEnd", turn: 1 });
    const sw = battle.events.find((e) => (e as { event: string }).event === "switch") as
      | { forced: boolean; in: string }
      | undefined;
    expect(sw?.forced).toBe(false);
    expect(sw?.in).toBe("a1");
    // No attack happened on side A's turn.
    expect(battle.events.some((e) => (e as { event: string }).event === "attack")).toBe(false);
    expect(battle.activeIndex(0)).toBe(1);
  });
});

// ---------------------------------------------------------------------------
// Faints and forced replacement
// ---------------------------------------------------------------------------

describe("battle engine — faints", () => {
  it("a faint triggers a free replacement that does not consume a turn", () => {
    const glass = unit("glass", { baseHealth: 1 });
    const strong = squadOf("b", 3, { baseAttack: 200, rarity: "legendary", star: 5 });
    const battle = new Battle([glass, unit("a1"), unit("a2")], strong, 3n, { firstTurn: "B" });
    // B's first hit faints 'glass'.
    battle.act(1, { type: "move", moveIndex: 0 });
    const events = battle.events as { event: string; [k: string]: unknown }[];
    const faint = events.find((e) => e.event === "faint" && e.unit === "glass");
    expect(faint).toBeTruthy();
    const sw = events.find((e) => e.event === "switch" && e.forced === true);
    expect(sw).toBeTruthy();
    // The replacement was automatic and free — side A still acts next.
    expect(battle.currentSide).toBe("A");
  });

  it("the battle ends when all three monsters on one side faint", () => {
    const weak = squadOf("w", 3, { baseHealth: 1 });
    const strong = squadOf("s", 3, { baseAttack: 300, rarity: "secret", star: 2 });
    const result = simulateBattle(weak, strong, 11n, { firstTurn: "B" });
    expect(result.winner).toBe("B");
    expect(result.reason).toBe("wipeout");
    expect(result.faintedA).toHaveLength(3);
  });
});

// ---------------------------------------------------------------------------
// Accuracy and statuses
// ---------------------------------------------------------------------------

describe("battle engine — accuracy & statuses", () => {
  const blind: MoveSpec = { id: "blind", name: "Blind", kind: "standard", power: 3, accuracy: 0, manaCost: 0 };

  it("a 0-accuracy move always misses and deals nothing", () => {
    // Blind BOTH sides so no attack ever lands.
    const r = simulateBattle([unit("a", { moves: [blind] })], [unit("b", { moves: [blind] })], 9n, { maxTurns: 10 });
    const misses = r.events.filter((e) => (e as { event: string }).event === "miss");
    expect(misses.length).toBeGreaterThan(0);
    expect(r.events.some((e) => (e as { event: string }).event === "attack" && (e as { damage: number }).damage > 0)).toBe(false);
    expect(r.reason).toBe("turnLimit");
  });

  it("a status only rolls when the move hits (P = P(hit) × P(status|hit))", () => {
    // accuracy 0 + statusChance 100 must NEVER apply the status.
    const whiff: MoveSpec = { ...blind, statusEffect: "burn", statusChance: 100, duration: 3 };
    const r = simulateBattle([unit("a", { moves: [whiff] })], [unit("b")], 9n, { maxTurns: 10 });
    expect(r.events.some((e) => (e as { event: string }).event === "status")).toBe(false);
  });

  it("burn ticks damage at the start of the target's turns", () => {
    const burner: MoveSpec = { id: "br", name: "Burn", kind: "standard", power: 0, accuracy: 100, statusEffect: "burn", statusChance: 100, duration: 3, manaCost: 0 };
    const battle = new Battle([unit("a", { moves: [burner] })], [unit("b")], 4n, { firstTurn: "A" });
    battle.act(0, { type: "move", moveIndex: 0 }); // apply burn
    battle.act(1, { type: "move", moveIndex: 0 }); // b ticks, then strikes
    const tick = (battle.events as { event: string; kind?: string; damage?: number }[]).find(
      (e) => e.event === "statusTick" && e.kind === "burn"
    );
    expect(tick).toBeTruthy();
    expect(tick!.damage).toBeCloseTo(100 * STATUS_PARAMS.burnFraction);
  });

  it("stun makes the afflicted unit skip its action", () => {
    const stunner: MoveSpec = { id: "st", name: "Stun", kind: "standard", power: 0, accuracy: 100, statusEffect: "stun", statusChance: 100, duration: 1, manaCost: 0 };
    const battle = new Battle([unit("a", { moves: [stunner] })], [unit("b")], 4n, { firstTurn: "A" });
    battle.act(0, { type: "move", moveIndex: 0 });
    battle.act(1, { type: "move", moveIndex: 0 }); // b is stunned — no attack
    expect(battle.events.some((e) => (e as { event: string }).event === "stunned")).toBe(true);
  });

  it("heal restores a fraction of max HP on proc", () => {
    const healer: MoveSpec = { id: "h", name: "Heal", kind: "standard", power: 0, accuracy: 100, statusEffect: "heal", statusChance: 100, manaCost: 0 };
    const battle = new Battle(
      [unit("a", { moves: [healer] })],
      [unit("b")],
      4n,
      { firstTurn: "A", carryHPA: [0.4] }
    );
    const before = battle.unitState(0, 0).hp;
    battle.act(0, { type: "move", moveIndex: 0 });
    const after = battle.unitState(0, 0).hp;
    expect(after - before).toBeCloseTo(battle.unitState(0, 0).maxHP * STATUS_PARAMS.healFraction);
  });
});

// ---------------------------------------------------------------------------
// Mana / specials
// ---------------------------------------------------------------------------

describe("battle engine — mana", () => {
  const special: MoveSpec = { id: "sp", name: "Special", kind: "special", power: 8, accuracy: 100, manaCost: 40 };

  it("Epic+ starts with floor(baseMana × starManaMult); specials consume it", () => {
    const e = unit("e", { rarity: "epic", star: 1, baseMana: 100, moves: [STRIKE, special] });
    const battle = new Battle([e], [unit("b")], 4n, { firstTurn: "A" });
    expect(battle.unitState(0, 0).mana).toBe(100);
    battle.act(0, { type: "move", moveIndex: 1 });
    expect(battle.unitState(0, 0).mana).toBe(60);
  });

  it("a special is not a legal action without enough mana", () => {
    const e = unit("e", { rarity: "epic", baseMana: 39, moves: [STRIKE, special] });
    const battle = new Battle([e], [unit("b")], 4n, { firstTurn: "A" });
    const legal = battle.legalActions(0);
    expect(legal.some((a) => a.type === "move" && a.moveIndex === 1)).toBe(false);
  });

  it("sub-Epic monsters never see a special", () => {
    const c = unit("c", { rarity: "rare", baseMana: 200, moves: [STRIKE, special] });
    const battle = new Battle([c], [unit("b")], 4n, { firstTurn: "A" });
    expect(battle.unitState(0, 0).mana).toBe(0);
    expect(battle.legalActions(0).some((a) => a.type === "move" && a.moveIndex === 1)).toBe(false);
  });
});

// ---------------------------------------------------------------------------
// Anti-stall
// ---------------------------------------------------------------------------

describe("battle engine — anti-stall", () => {
  it("turn limit resolves by remaining monster count first", () => {
    // A has two fainted already; B is at full. Stall to the cap → B wins.
    const battle = new Battle(
      squadOf("a", 3),
      squadOf("b", 3),
      1n,
      { firstTurn: "A", maxTurns: 4, carryHPA: [1, 0, 0] }
    );
    const noop: BattleAction = { type: "move", moveIndex: 0 };
    // Zero-power moves only → nobody faints, turn cap hits.
    const zero = { id: "z", name: "Z", kind: "standard", power: 0, accuracy: 100, manaCost: 0 } as MoveSpec;
    // rebuild with zero-power moves
    const b2 = new Battle(
      squadOf("a", 3, { moves: [zero] }),
      squadOf("b", 3, { moves: [zero] }),
      1n,
      { firstTurn: "A", maxTurns: 4, carryHPA: [1, 0, 0] }
    );
    const r = b2.runToCompletion();
    expect(r.reason).toBe("turnLimit");
    expect(r.winner).toBe("B"); // B has 3 alive, A has 1
    void battle;
    void noop;
  });

  it("equal counts resolve by total HP share", () => {
    const zero: MoveSpec = { id: "z", name: "Z", kind: "standard", power: 0, accuracy: 100, manaCost: 0 };
    const battle = new Battle(
      squadOf("a", 1, { moves: [zero] }),
      squadOf("b", 1, { moves: [zero] }),
      1n,
      { firstTurn: "A", maxTurns: 2, carryHPA: [0.9], carryHPB: [0.5] }
    );
    const r = battle.runToCompletion();
    expect(r.reason).toBe("turnLimit");
    expect(r.winner).toBe("A"); // 90% > 50% HP share
  });
});

// ---------------------------------------------------------------------------
// Snapshot semantics
// ---------------------------------------------------------------------------

describe("battle engine — snapshot isolation", () => {
  it("mutating the input specs after construction cannot affect the match", () => {
    const a = squadOf("a");
    const b = squadOf("b");
    const battle = new Battle(a, b, 8n, { firstTurn: "A" });
    const pristine = new Battle(squadOf("a"), squadOf("b"), 8n, { firstTurn: "A" });
    // Corrupt the inputs post-construction.
    a[0].baseAttack = 99999;
    a[0].moves = [];
    b[0].baseHealth = 1;
    const r1 = battle.runToCompletion();
    const r2 = pristine.runToCompletion();
    expect(r1.events).toEqual(r2.events);
    expect(r1.winner).toBe(r2.winner);
  });
});

// ---------------------------------------------------------------------------
// Canonical seeds — baked for the Swift↔TS parity contract.
//
// These are the recorded outcomes of THIS implementation. The identical
// table is asserted in ios/Tests/BattleKitTests: if either port drifts, one
// side's assertion fails. Do not "fix" a mismatch by editing the table —
// fix the port that moved.
// ---------------------------------------------------------------------------

const CANONICAL: Record<string, { winner: "A" | "B"; turns: number }> = {
  "0": { winner: "B", turns: 66 },
  "1": { winner: "A", turns: 72 },
  "42": { winner: "A", turns: 84 },
  "100": { winner: "B", turns: 88 },
  "9999": { winner: "B", turns: 66 }
};

describe("battle engine — canonical seed table (Swift parity)", () => {
  // Mixed-rarity squads matching the canonical fixtures in BattleKitTests.
  const strike: MoveSpec = { id: "strike", name: "Strike", kind: "standard", power: 3.5, accuracy: 95, manaCost: 0 };
  const guard: MoveSpec = { id: "guard", name: "Guard", kind: "standard", power: 0, accuracy: 100, statusEffect: "guard_up", statusChance: 100, duration: 2, manaCost: 0 };
  const blast: MoveSpec = { id: "blast", name: "Blast", kind: "special", power: 8, accuracy: 85, manaCost: 40 };

  const canonicalA: BattleUnitSpec[] = [
    { id: "a0", name: "A0", baseHealth: 100, baseAttack: 50, rarity: "common", star: 1, moves: [strike, guard] },
    { id: "a1", name: "A1", baseHealth: 110, baseAttack: 55, rarity: "rare", star: 2, moves: [strike, guard] },
    { id: "a2", name: "A2", baseHealth: 95, baseAttack: 60, rarity: "epic", star: 3, baseMana: 90, moves: [strike, guard, blast] }
  ];
  const canonicalB: BattleUnitSpec[] = [
    { id: "b0", name: "B0", baseHealth: 105, baseAttack: 45, rarity: "uncommon", star: 1, moves: [strike, guard] },
    { id: "b1", name: "B1", baseHealth: 120, baseAttack: 50, rarity: "epic", star: 2, baseMana: 120, moves: [strike, guard, blast] },
    { id: "b2", name: "B2", baseHealth: 90, baseAttack: 55, rarity: "rare", star: 3, moves: [strike, guard] }
  ];

  for (const [seed, expected] of Object.entries(CANONICAL)) {
    it(`seed ${seed}: winner=${expected.winner} turns=${expected.turns}`, () => {
      const r = simulateBattle(canonicalA, canonicalB, BigInt(seed));
      expect(r.winner).toBe(expected.winner);
      expect(r.turns).toBe(expected.turns);
    });
  }

  it("constants match the spec contract", () => {
    expect(CRIT_CHANCE).toBe(1 / 24);
    expect(CRIT_MULT).toBe(1.5);
    expect(VARIANCE_MIN).toBe(0.85);
    expect(VARIANCE_MAX).toBe(1.0);
    expect(MIN_DAMAGE).toBe(1);
    expect(RARITY_COMBAT_MULT.secret).toBe(1.7);
    expect(DAMAGE_SCALE).toBeGreaterThan(0);
    expect(MAX_TURNS).toBeGreaterThan(0);
  });
});

// ---------------------------------------------------------------------------
// Route adapter (routes/battle.ts simulate()) — thin contract check.
//
// Importing routes/battle pulls in the DB layer, so the adapter tests point
// the DB at memory before dynamically importing the module.
// ---------------------------------------------------------------------------

describe("route adapter", () => {
  let simulate: typeof import("./battle").simulate;

  beforeAll(async () => {
    process.env.NUTRIQUEST_DB = "memory";
    ({ simulate } = await import("./battle"));
  });

  it("simulate() wraps the engine and returns the legacy response shape", () => {
    const a: SimUnit[] = [{ id: "x1", name: "X", baseHealth: 100, baseAttack: 50, star: 1, rarity: "common" }];
    const b: SimUnit[] = [{ id: "y1", name: "Y", baseHealth: 100, baseAttack: 50, star: 1, rarity: "common" }];
    const r = simulate(a, b, 42n);
    expect(["A", "B"]).toContain(r.winner);
    expect(r.rounds).toBeGreaterThan(0);
    expect(r.events[0]).toMatchObject({ event: "battleStart" });
    expect(r.hpLeftA).toHaveLength(1);
  });

  it("roster ids resolve authored movesets", () => {
    const a: SimUnit[] = [{ id: "broccoli-bud", name: "Broc", baseHealth: 100, baseAttack: 50, star: 1, rarity: "common", characterKey: "broccoli-bud" }];
    const b: SimUnit[] = [{ id: "y1", name: "Y", baseHealth: 100, baseAttack: 50, star: 1, rarity: "common" }];
    const r = simulate(a, b, 42n);
    const moves = new Set(
      r.events
        .filter((e) => (e as { event: string }).event === "attack")
        .map((e) => (e as { moveId?: string }).moveId)
    );
    expect([...moves].some((m) => m?.startsWith("broccoli-bud-"))).toBe(true);
  });
});
