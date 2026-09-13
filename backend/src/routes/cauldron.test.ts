import { describe, it, expect, beforeAll, afterAll, vi } from "vitest";
import express from "express";
import { rmSync } from "fs";
import { tmpdir } from "os";
import path from "path";

// ============================================================================
// Cauldron Crash — the transactional rules.
//
// These are the tests that matter for a feature that destroys owned items: a
// wager must leave the inventory exactly once, a round must resolve exactly
// once, and closing the app must not be a way to get a monster back.
// ============================================================================

const DB_FILE = path.join(tmpdir(), `nutriquest-cauldron-${process.pid}-${Date.now()}.db`);

beforeAll(() => {
  process.env.NUTRIQUEST_DB = DB_FILE;
});

afterAll(() => {
  rmSync(DB_FILE, { force: true });
  rmSync(`${DB_FILE}-wal`, { force: true });
  rmSync(`${DB_FILE}-shm`, { force: true });
});

type Call = (method: string, path: string, body?: unknown) => Promise<Response>;

let playerCounter = 0;

/** A player with `count` monsters in the bank, and a caller bound to them. */
async function withPlayer(
  run: (call: Call, monsters: { id: string; netWorth: number }[]) => Promise<void>,
  count = 3
): Promise<void> {
  const { cauldronRouter } = await import("./cauldron");
  const { stateFor } = await import("../services/lootboxState");
  const { CHARACTERS } = await import("../data/lootTable");

  const playerId = `cauldron_${playerCounter++}_${Date.now()}`;
  const session = stateFor(playerId);

  // Stock the inventory directly: this suite is about the wager, not about
  // how the monsters were acquired.
  const values = [8_500, 6_200, 2_800, 120];
  const seeded = ["salmon-striker", "quinoa-quill", "avocado-aegis", "broccoli-bud"]
    .slice(0, count)
    .map((characterId, i) =>
      session.record({
        crateId: "starter-crate",
        character: CHARACTERS[characterId],
        power: 55,
        powerLabel: "Steady",
        shiny: false,
        value: values[i],
        rolls: { rarity: 0.1, character: 0.1, power: 0.1, shiny: 0.9 },
        fairness: { serverSeedHash: "hash", clientSeed: "seed", nonce: i },
        openedAt: new Date().toISOString()
      })
    );

  const app = express();
  app.use(express.json());
  app.use("/cauldron", cauldronRouter);

  const server = app.listen(0);
  await new Promise<void>((resolve) => server.once("listening", resolve));
  const port = (server.address() as { port: number }).port;

  const call: Call = (method, url, body) =>
    fetch(`http://127.0.0.1:${port}${url}`, {
      method,
      headers: { "Content-Type": "application/json", "X-Player-Id": playerId },
      body: body === undefined ? undefined : JSON.stringify(body)
    });

  try {
    await run(
      call,
      seeded.map((drop) => ({ id: drop.id, netWorth: drop.value }))
    );
  } finally {
    await new Promise<void>((resolve) => server.close(() => resolve()));
  }
}

interface RoundBody {
  round: {
    roundId: string;
    status: string;
    startingNetWorth: number;
    multiplier: number;
    netWorth: number;
    wager: { id: string; netWorth: number }[];
    crashMultiplier?: number;
    cashOutMultiplier?: number | null;
    finalNetWorth?: number | null;
    lostNetWorth?: number;
    reward?: { id: string; netWorth: number; stars: number; character: { rarity: string } } | null;
  };
}

interface StateBody {
  round: RoundBody["round"] | null;
  lastRound: RoundBody["round"] | null;
  wagerable: { id: string; netWorth: number }[];
}

describe("starting a round", () => {
  it("combines the wagered monsters into one pot", async () => {
    await withPlayer(async (call, monsters) => {
      const response = await call("POST", "/cauldron/rounds", {
        dropIds: monsters.slice(0, 3).map((m) => m.id)
      });
      expect(response.status).toBe(201);
      const { round } = (await response.json()) as RoundBody;
      expect(round.status).toBe("ACTIVE");
      expect(round.startingNetWorth).toBe(17_500);
      expect(round.wager).toHaveLength(3);
      expect(round.multiplier).toBeGreaterThanOrEqual(1);
    });
  });

  it("never discloses the crash point while the round is live", async () => {
    await withPlayer(async (call, monsters) => {
      const response = await call("POST", "/cauldron/rounds", { dropIds: [monsters[0].id] });
      const body = (await response.json()) as { round: Record<string, unknown> };
      expect(body.round.status).toBe("ACTIVE");
      expect(Object.keys(body.round)).not.toContain("crashMultiplier");

      // A live round in /state is equally silent. (A round that already
      // crashed — 5% of them do so instantly, by design — is a *finished*
      // round, and finished rounds are supposed to show where they blew up.)
      const state = (await (await call("GET", "/cauldron/state")).json()) as {
        round: Record<string, unknown> | null;
      };
      if (state.round) {
        expect(Object.keys(state.round)).not.toContain("crashMultiplier");
      }
    });
  });

  it("takes the wagered monsters out of the inventory immediately", async () => {
    await withPlayer(async (call, monsters) => {
      await call("POST", "/cauldron/rounds", { dropIds: [monsters[0].id, monsters[1].id] });
      const state = (await (await call("GET", "/cauldron/state")).json()) as StateBody;
      const owned = state.wagerable.map((m) => m.id);
      expect(owned).not.toContain(monsters[0].id);
      expect(owned).not.toContain(monsters[1].id);
      expect(owned).toContain(monsters[2].id);
    });
  });

  it("refuses a second round while one is bubbling", async () => {
    // Driven through the service with a fixed clock rather than over HTTP.
    // A round can crash on contact -- that is the 5% house edge -- and a
    // player whose cauldron has already exploded is entitled to start
    // another, so asserting "the second call is always refused" is only true
    // 95% of the time. The real invariant is that two rounds are never live
    // at once, which is what this checks.
    const { startRound, activeRound, CAULDRON_ERRORS } = await import("../services/cauldronState");
    const { stateFor } = await import("../services/lootboxState");
    const { CHARACTERS } = await import("../data/lootTable");

    const playerId = `cauldron_concurrent_${Date.now()}`;
    const session = stateFor(playerId);
    const drops = Array.from({ length: 12 }, () =>
      session.record({
        crateId: "starter-crate",
        character: CHARACTERS["broccoli-bud"],
        power: 55,
        powerLabel: "Steady",
        shiny: false,
        value: 600,
        rolls: { rarity: 0.1, character: 0.1, power: 0.1, shiny: 0.9 },
        fairness: { serverSeedHash: "hash", clientSeed: "seed", nonce: 0 },
        openedAt: new Date().toISOString()
      })
    );

    // Find a round that did not crash instantly. Twelve tries makes an
    // all-instant-crash run (0.05^12) impossible in practice.
    const now = Date.now();
    let live = false;
    let used = 0;
    while (used < drops.length - 1 && !live) {
      const round = startRound(playerId, [drops[used++].id], now);
      live = round.crashMultiplier > 1;
    }
    expect(live).toBe(true);
    expect(activeRound(playerId, now)).not.toBeNull();

    // With one genuinely live, a second must be refused at the same instant.
    expect(() => startRound(playerId, [drops[used].id], now)).toThrow(
      CAULDRON_ERRORS.ROUND_IN_PROGRESS
    );
    // ...and the refused wager is still owned.
    expect(session.inventory.map((d) => d.id)).toContain(drops[used].id);
  });

  it("refuses the same monster twice in one wager", async () => {
    await withPlayer(async (call, monsters) => {
      const response = await call("POST", "/cauldron/rounds", {
        dropIds: [monsters[0].id, monsters[0].id]
      });
      expect(response.status).toBe(409);
      // And nothing was consumed by the attempt.
      const state = (await (await call("GET", "/cauldron/state")).json()) as StateBody;
      expect(state.wagerable.map((m) => m.id)).toContain(monsters[0].id);
    });
  });

  it("refuses a monster that isn't yours", async () => {
    await withPlayer(async (call, monsters) => {
      const response = await call("POST", "/cauldron/rounds", {
        dropIds: [monsters[0].id, "not-a-real-drop"]
      });
      expect(response.status).toBe(409);
      const state = (await (await call("GET", "/cauldron/state")).json()) as StateBody;
      // All-or-nothing: the valid half of the wager survives.
      expect(state.wagerable.map((m) => m.id)).toContain(monsters[0].id);
    });
  });

  it("enforces the 1-3 monster wager size", async () => {
    await withPlayer(async (call, monsters) => {
      expect((await call("POST", "/cauldron/rounds", { dropIds: [] })).status).toBe(400);
      expect(
        (await call("POST", "/cauldron/rounds", { dropIds: monsters.map((m) => m.id) })).status
      ).toBe(400);
    }, 4);
  });
});

describe("cashing out", () => {
  it("pays the server's multiplier and awards one monster", async () => {
    await withPlayer(async (call, monsters) => {
      const { round } = (await (
        await call("POST", "/cauldron/rounds", { dropIds: [monsters[0].id] })
      ).json()) as RoundBody;

      const cashed = (await (
        await call("POST", `/cauldron/rounds/${round.roundId}/cashout`)
      ).json()) as RoundBody;

      // A round can crash instantly (5% of the time, by design) — both
      // outcomes are legal, but the bookkeeping must match the one that
      // happened.
      if (cashed.round.status === "CASHED_OUT") {
        expect(cashed.round.finalNetWorth).toBeGreaterThanOrEqual(round.startingNetWorth);
        expect(cashed.round.reward).not.toBeNull();
        expect(cashed.round.reward!.stars).toBe(1);
        const state = (await (await call("GET", "/cauldron/state")).json()) as StateBody;
        expect(state.wagerable.map((m) => m.id)).toContain(cashed.round.reward!.id);
      } else {
        expect(cashed.round.status).toBe("CRASHED");
        expect(cashed.round.reward ?? null).toBeNull();
        expect(cashed.round.lostNetWorth).toBe(round.startingNetWorth);
      }
    });
  });

  it("pays exactly once, however many times it is asked", async () => {
    await withPlayer(async (call, monsters) => {
      const { round } = (await (
        await call("POST", "/cauldron/rounds", { dropIds: [monsters[0].id] })
      ).json()) as RoundBody;

      const first = (await (
        await call("POST", `/cauldron/rounds/${round.roundId}/cashout`)
      ).json()) as RoundBody;
      const second = (await (
        await call("POST", `/cauldron/rounds/${round.roundId}/cashout`)
      ).json()) as RoundBody;
      const third = (await (
        await call("POST", `/cauldron/rounds/${round.roundId}/cashout`)
      ).json()) as RoundBody;

      // Every repeat returns what actually happened, and mints nothing new.
      expect(second.round.status).toBe(first.round.status);
      expect(second.round.finalNetWorth ?? null).toBe(first.round.finalNetWorth ?? null);
      expect(third.round.reward?.id ?? null).toBe(first.round.reward?.id ?? null);

      const state = (await (await call("GET", "/cauldron/state")).json()) as StateBody;
      const rewardCount = state.wagerable.filter(
        (m) => m.id === (first.round.reward?.id ?? "none")
      ).length;
      expect(rewardCount).toBeLessThanOrEqual(1);
    });
  });

  it("404s a round that isn't yours", async () => {
    await withPlayer(async (call) => {
      const response = await call("POST", "/cauldron/rounds/00000000-0000-0000-0000-000000000000/cashout");
      expect(response.status).toBe(404);
    });
  });
});

describe("crashing", () => {
  it("destroys the wager and returns nothing", async () => {
    const { startRound, cashOut, settle, roundById } = await import("../services/cauldronState");
    const { stateFor } = await import("../services/lootboxState");
    const { CHARACTERS } = await import("../data/lootTable");

    const playerId = `cauldron_crash_${Date.now()}`;
    const session = stateFor(playerId);
    const drop = session.record({
      crateId: "starter-crate",
      character: CHARACTERS["salmon-striker"],
      power: 55,
      powerLabel: "Steady",
      shiny: false,
      value: 9_000,
      rolls: { rarity: 0.1, character: 0.1, power: 0.1, shiny: 0.9 },
      fairness: { serverSeedHash: "hash", clientSeed: "seed", nonce: 0 },
      openedAt: new Date().toISOString()
    });

    const round = startRound(playerId, [drop.id]);
    // Jump past any possible crash point.
    const later = Date.parse(round.startedAt) + 60 * 60 * 1000;

    const settled = settle(round, later);
    expect(settled.status).toBe("CRASHED");
    expect(session.inventory.find((d) => d.id === drop.id)).toBeUndefined();

    // Cashing out afterwards cannot resurrect it.
    const attempted = cashOut(playerId, round.roundId, later);
    expect(attempted.status).toBe("CRASHED");
    expect(attempted.reward).toBeNull();
    expect(roundById(playerId, round.roundId)!.status).toBe("CRASHED");
    expect(session.inventory.find((d) => d.id === drop.id)).toBeUndefined();
  });

  it("keeps the crash point fixed across a reconnect", async () => {
    const { startRound, roundById } = await import("../services/cauldronState");
    const { stateFor } = await import("../services/lootboxState");
    const { CHARACTERS } = await import("../data/lootTable");

    const playerId = `cauldron_reconnect_${Date.now()}`;
    const drop = stateFor(playerId).record({
      crateId: "starter-crate",
      character: CHARACTERS["broccoli-bud"],
      power: 55,
      powerLabel: "Steady",
      shiny: false,
      value: 40,
      rolls: { rarity: 0.1, character: 0.1, power: 0.1, shiny: 0.9 },
      fairness: { serverSeedHash: "hash", clientSeed: "seed", nonce: 0 },
      openedAt: new Date().toISOString()
    });

    const round = startRound(playerId, [drop.id]);
    const reloaded = roundById(playerId, round.roundId)!;
    expect(reloaded.crashMultiplier).toBe(round.crashMultiplier);
    expect(reloaded.startedAt).toBe(round.startedAt);
  });
});

// ============================================================================
// Addendum contract (cauldron_crash_project_addendum.md).
//
// The wager is destroyed either way — a cash-out is not a trade-in — the
// reward is a brand new instance, and duplicates of one character are
// separate monsters that must be destroyable one at a time.
// ============================================================================

describe("wager destruction semantics", () => {
  it("destroys the wager on a cash-out too, and mints a new instance", async () => {
    await withPlayer(async (call, monsters) => {
      const wagered = monsters.slice(0, 3).map((m) => m.id);
      const { round } = (await (
        await call("POST", "/cauldron/rounds", { dropIds: wagered })
      ).json()) as RoundBody;
      const cashed = (await (
        await call("POST", `/cauldron/rounds/${round.roundId}/cashout`)
      ).json()) as RoundBody;

      const state = (await (await call("GET", "/cauldron/state")).json()) as StateBody;
      const owned = state.wagerable.map((m) => m.id);

      // Gone, whichever way the round went.
      for (const id of wagered) expect(owned).not.toContain(id);

      if (cashed.round.status === "CASHED_OUT") {
        const reward = cashed.round.reward!;
        // A new monster, not one of the wagered ones handed back.
        expect(wagered).not.toContain(reward.id);
        expect(owned).toContain(reward.id);
        expect(reward.stars).toBe(1);
      }
    });
  });

  it("treats duplicate copies of one character as separate monsters", async () => {
    const { stateFor } = await import("../services/lootboxState");
    const { startRound } = await import("../services/cauldronState");
    const { CHARACTERS } = await import("../data/lootTable");

    const playerId = `cauldron_dupes_${Date.now()}`;
    const session = stateFor(playerId);
    const copies = [0, 1, 2].map(() =>
      session.record({
        crateId: "starter-crate",
        character: CHARACTERS["salmon-striker"],
        power: 55,
        powerLabel: "Steady",
        shiny: false,
        value: 220,
        rolls: { rarity: 0.1, character: 0.1, power: 0.1, shiny: 0.9 },
        fairness: { serverSeedHash: "hash", clientSeed: "seed", nonce: 0 },
        openedAt: new Date().toISOString()
      })
    );

    // Same character, same rarity, same value — three distinct instances.
    expect(new Set(copies.map((c) => c.id)).size).toBe(3);

    startRound(playerId, [copies[1].id]);

    const remaining = session.inventory.map((d) => d.id);
    expect(remaining).not.toContain(copies[1].id);
    expect(remaining).toContain(copies[0].id);
    expect(remaining).toContain(copies[2].id);
  });

  it("cannot be undone by a restart", async () => {
    // "Restart" = a fresh module graph reopening the same database file,
    // the same simulation persistence.test.ts uses.
    const { stateFor } = await import("../services/lootboxState");
    const { startRound } = await import("../services/cauldronState");
    const { CHARACTERS } = await import("../data/lootTable");

    const playerId = `cauldron_restart_${Date.now()}`;
    const drop = stateFor(playerId).record({
      crateId: "starter-crate",
      character: CHARACTERS["salmon-striker"],
      power: 55,
      powerLabel: "Steady",
      shiny: false,
      value: 220,
      rolls: { rarity: 0.1, character: 0.1, power: 0.1, shiny: 0.9 },
      fairness: { serverSeedHash: "hash", clientSeed: "seed", nonce: 0 },
      openedAt: new Date().toISOString()
    });
    const round = startRound(playerId, [drop.id]);

    vi.resetModules();
    const rebooted = await import("../services/lootboxState");
    const rebootedCauldron = await import("../services/cauldronState");

    // The monster did not come back, and the round kept its crash point.
    expect(rebooted.stateFor(playerId).inventory.map((d) => d.id)).not.toContain(drop.id);
    const reloaded = rebootedCauldron.roundById(playerId, round.roundId);
    expect(reloaded).not.toBeNull();
    expect(reloaded!.crashMultiplier).toBe(round.crashMultiplier);
    expect(reloaded!.wager[0].id).toBe(drop.id);
  });
});

describe("published rules", () => {
  it("serves the edge, the wager limits and the rarity brackets", async () => {
    await withPlayer(async (call) => {
      const config = (await (await call("GET", "/cauldron/config")).json()) as {
        houseEdge: number;
        minWagerMonsters: number;
        maxWagerMonsters: number;
        rarityRanges: { rarity: string; min: number; max: number | null }[];
        survivalOdds: { multiplier: number; chance: number }[];
      };
      expect(config.houseEdge).toBe(0.05);
      expect(config.minWagerMonsters).toBe(1);
      expect(config.maxWagerMonsters).toBe(3);
      expect(config.rarityRanges).toHaveLength(7);
      expect(config.rarityRanges.at(-1)!.max).toBeNull();
      expect(config.survivalOdds.find((o) => o.multiplier === 2)!.chance).toBeCloseTo(0.475, 3);
    });
  });
});
