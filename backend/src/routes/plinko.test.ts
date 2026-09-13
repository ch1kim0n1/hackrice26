import { describe, it, expect, beforeAll, afterAll } from "vitest";
import express from "express";
import { rmSync } from "fs";
import { tmpdir } from "os";
import path from "path";

// ============================================================================
// Plinko — one call, one outcome.
//
// There is no live round to protect, so what matters here is that the monster
// is spent exactly once, that the answer the client gets is internally
// consistent (the path really does lead to the slot it claims), and that a 0x
// landing genuinely returns nothing.
// ============================================================================

const DB_FILE = path.join(tmpdir(), `nutriquest-plinko-${process.pid}-${Date.now()}.db`);

beforeAll(() => {
  process.env.NUTRIQUEST_DB = DB_FILE;
});

afterAll(() => {
  rmSync(DB_FILE, { force: true });
  rmSync(`${DB_FILE}-wal`, { force: true });
  rmSync(`${DB_FILE}-shm`, { force: true });
});

type Call = (method: string, path: string, body?: unknown) => Promise<Response>;

let counter = 0;

async function withPlayer(
  run: (call: Call, monsters: { id: string; netWorth: number }[]) => Promise<void>,
  count = 12
): Promise<void> {
  const { plinkoRouter } = await import("./plinko");
  const { stateFor } = await import("../services/lootboxState");
  const { CHARACTERS } = await import("../data/lootTable");

  const playerId = `plinko_${counter++}_${Date.now()}`;
  const session = stateFor(playerId);

  const seeded = Array.from({ length: count }, (_, i) =>
    session.record({
      crateId: "starter-crate",
      character: CHARACTERS["salmon-striker"],
      power: 55,
      powerLabel: "Steady",
      shiny: false,
      value: 20_000,
      rolls: { rarity: 0.1, character: 0.1, power: 0.1, shiny: 0.9 },
      fairness: { serverSeedHash: "hash", clientSeed: "seed", nonce: i },
      openedAt: new Date().toISOString()
    })
  );

  const app = express();
  app.use(express.json());
  app.use("/plinko", plinkoRouter);

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
    await run(call, seeded.map((d) => ({ id: d.id, netWorth: d.value })));
  } finally {
    await new Promise<void>((resolve) => server.close(() => resolve()));
  }
}

interface Drop {
  dropId: string;
  wagerValue: number;
  path: boolean[];
  slot: number;
  multiplier: number;
  finalNetWorth: number;
  busted: boolean;
  rarity: string | null;
  reward: { id: string; stars: number; netWorth: number } | null;
}

describe("dropping", () => {
  it("spends the monster and returns a consistent outcome", async () => {
    await withPlayer(async (call, monsters) => {
      const response = await call("POST", "/plinko/drops", { dropId: monsters[0].id });
      expect(response.status).toBe(201);
      const { drop } = (await response.json()) as { drop: Drop };

      // The path must actually lead to the slot the result claims -- this is
      // what lets the client animate the outcome instead of faking one.
      expect(drop.path).toHaveLength(12);
      expect(drop.path.filter(Boolean)).toHaveLength(drop.slot);
      expect(drop.finalNetWorth).toBe(Math.floor(20_000 * drop.multiplier));

      const state = (await (await call("GET", "/plinko/state")).json()) as {
        wagerable: { id: string }[];
      };
      expect(state.wagerable.map((m) => m.id)).not.toContain(monsters[0].id);
    });
  });

  it("mints a new monster whenever the landing is worth anything", async () => {
    await withPlayer(async (call, monsters) => {
      // Drop several so at least one lands off the bust slot (77% each).
      let paid = 0;
      for (const monster of monsters) {
        const { drop } = (await (
          await call("POST", "/plinko/drops", { dropId: monster.id })
        ).json()) as { drop: Drop };

        if (drop.busted) {
          expect(drop.finalNetWorth).toBe(0);
          expect(drop.reward).toBeNull();
          expect(drop.rarity).toBeNull();
        } else {
          paid++;
          expect(drop.finalNetWorth).toBeGreaterThan(0);
          expect(drop.reward).not.toBeNull();
          expect(drop.reward!.stars).toBe(1);
          expect(drop.rarity).not.toBeNull();
          // The reward is a NEW instance, never the wagered one handed back.
          expect(drop.reward!.id).not.toBe(monster.id);
        }
      }
      expect(paid).toBeGreaterThan(0);
    });
  });

  it("destroys the wager on a bust and returns nothing", async () => {
    // Driven through the service so the bust case is exercised directly
    // rather than waited for: a 0x landing is 22.5% per drop.
    const { drop } = await import("../services/plinkoState");
    const { stateFor } = await import("../services/lootboxState");
    const { CHARACTERS } = await import("../data/lootTable");

    const playerId = `plinko_bust_${Date.now()}`;
    const session = stateFor(playerId);
    let busted = false;

    for (let i = 0; i < 60 && !busted; i++) {
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
      const resolved = drop(playerId, monster.id);
      expect(session.inventory.map((d) => d.id)).not.toContain(monster.id);

      if (resolved.multiplier === 0) {
        busted = true;
        expect(resolved.finalNetWorth).toBe(0);
        expect(resolved.reward).toBeNull();
      }
    }
    // 60 drops without a bust is a 1-in-10^6 event; if it happens the board
    // has drifted, not the test.
    expect(busted).toBe(true);
  });

  it("refuses a monster that isn't yours, and spends nothing", async () => {
    await withPlayer(async (call, monsters) => {
      const response = await call("POST", "/plinko/drops", { dropId: "not-a-real-monster" });
      expect(response.status).toBe(409);

      const state = (await (await call("GET", "/plinko/state")).json()) as {
        wagerable: { id: string }[];
      };
      expect(state.wagerable.map((m) => m.id)).toContain(monsters[0].id);
    });
  });

  it("cannot spend the same monster twice", async () => {
    await withPlayer(async (call, monsters) => {
      const first = await call("POST", "/plinko/drops", { dropId: monsters[0].id });
      expect(first.status).toBe(201);
      // The monster is gone, so a replayed request has nothing to spend.
      const replay = await call("POST", "/plinko/drops", { dropId: monsters[0].id });
      expect(replay.status).toBe(409);
    });
  });

  it("rejects a malformed wager", async () => {
    await withPlayer(async (call) => {
      expect((await call("POST", "/plinko/drops", {})).status).toBe(400);
      expect((await call("POST", "/plinko/drops", { dropId: "" })).status).toBe(400);
    });
  });
});

describe("published rules", () => {
  it("serves the board, the table and the real edge", async () => {
    await withPlayer(async (call) => {
      const config = (await (await call("GET", "/plinko/config")).json()) as {
        houseEdge: number;
        actualHouseEdge: number;
        expectedMultiplier: number;
        pegRows: number;
        slotCount: number;
        totalPaths: number;
        slots: { slot: number; multiplier: number; probability: number; paths: number }[];
      };

      expect(config.pegRows).toBe(12);
      expect(config.slotCount).toBe(13);
      expect(config.totalPaths).toBe(4096);
      expect(config.slots).toHaveLength(13);
      // The published edge is the edge the table actually charges.
      expect(config.actualHouseEdge).toBeCloseTo(config.houseEdge, 2);
      expect(config.expectedMultiplier).toBeCloseTo(0.95, 2);

      const probabilities = config.slots.reduce((sum, s) => sum + s.probability, 0);
      expect(probabilities).toBeCloseTo(1, 10);
    });
  });

  it("keeps a history of drops", async () => {
    await withPlayer(async (call, monsters) => {
      await call("POST", "/plinko/drops", { dropId: monsters[0].id });
      await call("POST", "/plinko/drops", { dropId: monsters[1].id });

      const history = (await (await call("GET", "/plinko/history?limit=5")).json()) as {
        drops: Drop[];
      };
      expect(history.drops.length).toBeGreaterThanOrEqual(2);
      expect((await call("GET", "/plinko/history?limit=0")).status).toBe(400);
    });
  });
});
