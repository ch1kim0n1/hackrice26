import { describe, it, expect, beforeAll, afterAll } from "vitest";
import { rmSync } from "fs";
import { tmpdir } from "os";
import path from "path";

// ============================================================================
// Portal Wheel — the math, and the one guarantee the math cannot make.
//
// The engine tests are the interesting half: everything the player is shown
// (section counts, chances, payouts) has to be derivable from the layout array,
// because the fairness claim in the spec is precisely that the visible wheel and
// the quoted price are the same data. A test that hardcodes 7.60x would pass
// while the two drifted apart, so these assert the RELATIONSHIP instead.
// ============================================================================

const DB_FILE = path.join(tmpdir(), `nutriquest-wheel-svc-${process.pid}-${Date.now()}.db`);

beforeAll(() => {
  process.env.NUTRIQUEST_DB = DB_FILE;
});

afterAll(() => {
  rmSync(DB_FILE, { force: true });
  rmSync(`${DB_FILE}-wal`, { force: true });
  rmSync(`${DB_FILE}-shm`, { force: true });
});

describe("the wheel", () => {
  it("is tiled by the four colours with nothing left over", async () => {
    const { PORTAL_COLORS, SECTION_LAYOUT, TOTAL_SECTIONS } = await import("../data/portalWheel");
    const { sectionCount } = await import("./portalWheelEngine");

    const counted = PORTAL_COLORS.reduce((sum, color) => sum + sectionCount(color), 0);
    expect(counted).toBe(TOTAL_SECTIONS);
    expect(SECTION_LAYOUT).toHaveLength(TOTAL_SECTIONS);
  });

  it("gives every colour a different number of sections, so every bet is a different risk", async () => {
    const { PORTAL_COLORS } = await import("../data/portalWheel");
    const { sectionCount } = await import("./portalWheelEngine");

    const counts = PORTAL_COLORS.map(sectionCount);
    expect(new Set(counts).size).toBe(counts.length);
    for (const count of counts) expect(count).toBeGreaterThan(0);
  });

  it("probabilities are section shares and sum to exactly one", async () => {
    const { PORTAL_COLORS, TOTAL_SECTIONS } = await import("../data/portalWheel");
    const { probabilityOf, sectionCount } = await import("./portalWheelEngine");

    let total = 0;
    for (const color of PORTAL_COLORS) {
      expect(probabilityOf(color)).toBeCloseTo(sectionCount(color) / TOTAL_SECTIONS, 12);
      total += probabilityOf(color);
    }
    expect(total).toBeCloseTo(1, 12);
  });

  it("pays (1 - edge) / P, so fewer sections always pays more", async () => {
    const { HOUSE_EDGE, PORTAL_COLORS } = await import("../data/portalWheel");
    const { multiplierFor, probabilityOf, sectionCount } = await import("./portalWheelEngine");

    for (const color of PORTAL_COLORS) {
      const exact = (1 - HOUSE_EDGE) / probabilityOf(color);
      // Quoted to two decimals, and never rounded up: a payout above the fair
      // price is the house paying for a hundredth nobody earned.
      expect(multiplierFor(color)).toBeLessThanOrEqual(exact + 1e-9);
      expect(multiplierFor(color)).toBeGreaterThan(exact - 0.01);
      // Winning must always be worth more than the wager.
      expect(multiplierFor(color)).toBeGreaterThan(1);
    }

    const byRarity = [...PORTAL_COLORS].sort((a, b) => sectionCount(a) - sectionCount(b));
    for (let i = 1; i < byRarity.length; i++) {
      expect(multiplierFor(byRarity[i - 1])).toBeGreaterThan(multiplierFor(byRarity[i]));
    }
  });

  it("charges the casino's edge on every colour, and never less", async () => {
    const { HOUSE_EDGE, PORTAL_COLORS } = await import("../data/portalWheel");
    const { edgeMatchesHouse, houseEdgeFor, worstHouseEdge } = await import("./portalWheelEngine");

    for (const color of PORTAL_COLORS) {
      // Flooring the payout can only ever move the edge in the house's favour.
      expect(houseEdgeFor(color)).toBeGreaterThanOrEqual(HOUSE_EDGE - 1e-9);
      expect(houseEdgeFor(color)).toBeLessThan(HOUSE_EDGE + 0.005);
    }
    expect(worstHouseEdge()).toBeLessThan(HOUSE_EDGE + 0.005);
    expect(edgeMatchesHouse()).toBe(true);
  });

  it("lands uniformly across the sections, which is where the odds come from", async () => {
    const { SECTION_LAYOUT, TOTAL_SECTIONS } = await import("../data/portalWheel");
    const { colorAtSection, spinSection } = await import("./portalWheelEngine");

    // A roll is a float in [0, 1); each section owns an equal slice of it.
    for (let section = 0; section < TOTAL_SECTIONS; section++) {
      const mid = (section + 0.5) / TOTAL_SECTIONS;
      expect(spinSection(() => mid)).toBe(section);
      expect(colorAtSection(section)).toBe(SECTION_LAYOUT[section]);
    }
    // The top of the range must not fall off the wheel.
    expect(spinSection(() => 0.9999999)).toBe(TOTAL_SECTIONS - 1);
    expect(spinSection(() => 0)).toBe(0);
  });

  it("ignores everything except the roll", async () => {
    const { spinSection, PORTAL_WHEEL_CURSOR } = await import("./portalWheelEngine");

    // The engine may only consult its own cursor: anything else it could read
    // would be something the odds could depend on.
    const seen: number[] = [];
    spinSection((cursor) => {
      seen.push(cursor);
      return 0.5;
    });
    expect(seen).toEqual([PORTAL_WHEEL_CURSOR.section]);
  });
});

describe("spinning", () => {
  it("pays the quoted multiplier on the chosen colour and nothing on any other", async () => {
    const { finalNetWorth, multiplierFor } = await import("./portalWheelEngine");

    const quoted = multiplierFor("blue");
    expect(finalNetWorth(20_000, quoted, true)).toBe(Math.floor(20_000 * quoted));
    expect(finalNetWorth(20_000, quoted, false)).toBe(0);
  });

  it("spends the monster whichever colour wins", async () => {
    const { spin } = await import("./portalWheelState");
    const { stateFor } = await import("./lootboxState");
    const { CHARACTERS } = await import("../data/lootTable");

    const playerId = `wheel_spend_${Date.now()}`;
    const session = stateFor(playerId);
    let won = 0;
    let lost = 0;

    // Blue is 2/16, so 24 spins on blue sees both outcomes with overwhelming
    // probability while exercising the same code path for each.
    for (let i = 0; i < 24; i++) {
      const monster = session.record({
        crateId: "starter-crate",
        character: CHARACTERS["salmon-striker"],
        power: 55,
        powerLabel: "Steady",
        shiny: false,
        value: 20_000,
        rolls: { rarity: 0.1, character: 0.1, power: 0.1, shiny: 0.9 },
        fairness: { serverSeedHash: "hash", clientSeed: "seed", nonce: i },
        openedAt: new Date().toISOString()
      });

      const resolved = spin(playerId, monster.id, "blue");
      expect(session.inventory.map((d) => d.id)).not.toContain(monster.id);

      if (resolved.won) {
        won++;
        expect(resolved.winningColor).toBe("blue");
        expect(resolved.finalNetWorth).toBe(Math.floor(20_000 * resolved.multiplier));
        expect(resolved.reward).not.toBeNull();
        // Winnings are always fresh 1-star monsters, never the wager back.
        expect(resolved.reward!.id).not.toBe(monster.id);
        expect(resolved.reward!.stars).toBe(1);
      } else {
        lost++;
        expect(resolved.winningColor).not.toBe("blue");
        expect(resolved.finalNetWorth).toBe(0);
        expect(resolved.reward).toBeNull();
      }
    }

    expect(lost).toBeGreaterThan(0);
    expect(won + lost).toBe(24);
  });

  it("records the section it stopped on, and the colour that section really is", async () => {
    const { spin } = await import("./portalWheelState");
    const { colorAtSection } = await import("./portalWheelEngine");
    const { TOTAL_SECTIONS } = await import("../data/portalWheel");
    const { stateFor } = await import("./lootboxState");
    const { CHARACTERS } = await import("../data/lootTable");

    const playerId = `wheel_section_${Date.now()}`;
    const session = stateFor(playerId);

    for (let i = 0; i < 20; i++) {
      const monster = session.record({
        crateId: "starter-crate",
        character: CHARACTERS["broccoli-bud"],
        power: 55,
        powerLabel: "Steady",
        shiny: false,
        value: 600,
        rolls: { rarity: 0.1, character: 0.1, power: 0.1, shiny: 0.9 },
        fairness: { serverSeedHash: "hash", clientSeed: "seed", nonce: i },
        openedAt: new Date().toISOString()
      });
      const resolved = spin(playerId, monster.id, "green");

      // The section is what the client stops the pointer on, so it has to be a
      // real wedge and it has to be the colour the result claims won.
      expect(resolved.section).toBeGreaterThanOrEqual(0);
      expect(resolved.section).toBeLessThan(TOTAL_SECTIONS);
      expect(resolved.winningColor).toBe(colorAtSection(resolved.section));
      expect(resolved.won).toBe(resolved.winningColor === "green");
    }
  });

  it("refuses a monster that isn't there, and spends nothing", async () => {
    const { PORTAL_WHEEL_ERRORS, spin } = await import("./portalWheelState");
    const { stateFor } = await import("./lootboxState");

    const playerId = `wheel_missing_${Date.now()}`;
    const session = stateFor(playerId);
    const before = session.inventory.length;

    expect(() => spin(playerId, "not-a-real-monster", "red")).toThrow(
      PORTAL_WHEEL_ERRORS.WAGER_UNAVAILABLE
    );
    expect(session.inventory).toHaveLength(before);
  });

  it("survives a restart: the spin is history the moment it resolves", async () => {
    const { recentSpins, spin } = await import("./portalWheelState");
    const { stateFor } = await import("./lootboxState");
    const { CHARACTERS } = await import("../data/lootTable");

    const playerId = `wheel_history_${Date.now()}`;
    const session = stateFor(playerId);
    const monster = session.record({
      crateId: "starter-crate",
      character: CHARACTERS["salmon-striker"],
      power: 55,
      powerLabel: "Steady",
      shiny: false,
      value: 20_000,
      rolls: { rarity: 0.1, character: 0.1, power: 0.1, shiny: 0.9 },
      fairness: { serverSeedHash: "hash", clientSeed: "seed", nonce: 1 },
      openedAt: new Date().toISOString()
    });

    const resolved = spin(playerId, monster.id, "yellow");
    const stored = recentSpins(playerId, 5).find((entry) => entry.spinId === resolved.spinId);

    expect(stored).toBeDefined();
    expect(stored!.pick).toBe("yellow");
    expect(stored!.section).toBe(resolved.section);
    expect(stored!.won).toBe(resolved.won);
    expect(stored!.multiplier).toBe(resolved.multiplier);
    expect(stored!.finalNetWorth).toBe(resolved.finalNetWorth);
    // The wagered monster survives only inside the row.
    expect(stored!.wager.id).toBe(monster.id);
  });
});
