import { describe, it, expect, beforeAll, afterAll } from "vitest";
import express from "express";
import { rmSync } from "fs";
import { tmpdir } from "os";
import path from "path";

// ============================================================================
// Squad trust boundary.
//
// A battle request names WHICH units fight; the server alone decides what they
// are. These tests pin that contract: fabricated stats, star levels, rarities
// and unowned monsters must never reach the simulator, and a self-refereed
// match must not mint progression.
// ============================================================================

const DB_FILE = path.join(tmpdir(), `nutriquest-battlesquads-${process.pid}-${Date.now()}.db`);

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

/** An express app with the battle router and a unique player id. */
async function withBattle(
  run: (call: Call, playerId: string) => Promise<void>,
  stock: { characterId: string; stars?: number; value?: number }[] = []
): Promise<void> {
  const { battleRouter } = await import("./battle");
  const { stateFor } = await import("../services/lootboxState");
  const { testDrop, testCharacter } = await import("../testkit");

  const playerId = `btl_${counter++}_${Date.now()}`;
  const session = stateFor(playerId);
  for (const s of stock) {
    session.record(testDrop({
      crateId: "starter-crate",
      character: testCharacter("common", s.characterId),
      stars: s.stars ?? 1,
      value: s.value ?? 500,
      rolls: { rarity: 0.1, character: 0.1, mintSegment: 0, mintPosition: 0.1 },
      fairness: { serverSeedHash: "hash", clientSeed: "seed", nonce: 0 },
      openedAt: new Date().toISOString()
    })).drop;
  }

  const app = express();
  app.use(express.json());
  app.use("/battle", battleRouter);
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
    await run(call, playerId);
  } finally {
    await new Promise<void>((resolve) => server.close(() => resolve()));
  }
}

const STARTER = { id: "broccoli-bud", name: "Broccoli Bud", statType: "fiber" };
const STARTER_OPP = { id: "sprout-wisp", name: "Sprout Wisp", statType: "fiber" };

interface SimResult {
  winner: string;
  rounds: number;
  events: { event: string; [k: string]: unknown }[];
}

describe("squad trust boundary", () => {
  it("rejects a catalogue monster the player does not own", async () => {
    await withBattle(async (call) => {
      const response = await call("POST", "/battle/simulate", {
        yourSquad: [{ id: "the-first-seed", name: "The First Seed", statType: "fiber" }],
        opponentSquad: [STARTER_OPP],
        seed: 42
      });
      expect(response.status).toBe(400);
      const body = (await response.json()) as { error: string };
      expect(body.error).toContain("the-first-seed");
    });
  });

  it("rejects an entirely fabricated unit id", async () => {
    await withBattle(async (call) => {
      const response = await call("POST", "/battle/simulate", {
        yourSquad: [{ id: "god-mode", name: "God", statType: "protein", power: 500, star: 5, rarity: "secret" }],
        opponentSquad: [STARTER_OPP],
        seed: 42
      });
      expect(response.status).toBe(400);
    });
  });

  it("ignores fabricated stats, star and rarity on a starter", async () => {
    await withBattle(async (call) => {
      const honest = (await (
        await call("POST", "/battle/simulate", {
          yourSquad: [STARTER],
          opponentSquad: [STARTER_OPP],
          seed: 42
        })
      ).json()) as SimResult;
      const inflated = (await (
        await call("POST", "/battle/simulate", {
          yourSquad: [{ ...STARTER, power: 500, guard: 500, vitality: 500, tempo: 500, star: 5, rarity: "secret" }],
          opponentSquad: [STARTER_OPP],
          seed: 42
        })
      ).json()) as SimResult;
      // Bit-for-bit identical: the client's numbers never reached the sim.
      expect(inflated.events).toEqual(honest.events);
      expect(inflated.winner).toBe(honest.winner);
    });
  });

  it("degrades an unknown opponent to a ★1 common, whatever the body claims", async () => {
    await withBattle(async (call) => {
      const plain = (await (
        await call("POST", "/battle/simulate", {
          yourSquad: [STARTER],
          opponentSquad: [{ id: "fabricated-enemy", name: "Enemy", statType: "protein" }],
          seed: 42
        })
      ).json()) as SimResult;
      const inflated = (await (
        await call("POST", "/battle/simulate", {
          yourSquad: [STARTER],
          opponentSquad: [
            { id: "fabricated-enemy", name: "Enemy", statType: "protein", power: 500, guard: 500, vitality: 500, tempo: 500, star: 5, rarity: "secret" }
          ],
          seed: 42
        })
      ).json()) as SimResult;
      expect(inflated.events).toEqual(plain.events);
      expect(inflated.winner).toBe(plain.winner);
    });
  });

  it("derives an owned monster's star from the inventory, not the body", async () => {
    await withBattle(async (call) => {
      const owned = { id: "salmon-striker", name: "Salmon Striker", statType: "protein" };
      const low = (await (
        await call("POST", "/battle/simulate", {
          yourSquad: [{ ...owned, star: 1 }],
          opponentSquad: [STARTER_OPP],
          seed: 42
        })
      ).json()) as SimResult;
      const high = (await (
        await call("POST", "/battle/simulate", {
          yourSquad: [{ ...owned, star: 5 }],
          opponentSquad: [STARTER_OPP],
          seed: 42
        })
      ).json()) as SimResult;
      // Both resolve to the owned ★3 — the claimed star is ignored either way.
      expect(low.events).toEqual(high.events);
    }, [{ characterId: "salmon-striker", stars: 3 }]);
  });

  it("pays no XP and records no win for a self-refereed match", async () => {
    await withBattle(async (call, playerId) => {
      const { getOrCreate } = await import("./user");
      const response = await call("POST", "/battle/simulate", {
        yourSquad: [STARTER, { id: "bean-sprout", name: "Bean Sprout" }, { id: "carrot-cadet", name: "Carrot Cadet" }],
        opponentSquad: [STARTER_OPP],
        seed: 42
      });
      expect(response.status).toBe(200);
      const profile = getOrCreate(playerId);
      expect(profile.xp ?? 0).toBe(0);
      expect(profile.battlesWon ?? 0).toBe(0);
    });
  });

  it("re-resolves a legacy fabricated defender snapshot at load time", async () => {
    const { db } = await import("../db");
    const defenderId = `btl_def_${counter++}_${Date.now()}`;
    // A pre-fix payload: the client wrote itself a ★5 "secret" monster.
    db.prepare(
      `INSERT INTO friend_squad (player_id, payload, updated_at) VALUES (?, ?, datetime('now'))`
    ).run(
      defenderId,
      JSON.stringify([
        { id: "salmon-striker", name: "Salmon Striker", statType: "protein", rarity: "secret", star: 5, power: 500 }
      ])
    );

    await withBattle(async (call) => {
      const response = await call("POST", "/battle/friendly", {
        opponentId: defenderId,
        squad: [STARTER, { id: "bean-sprout", name: "Bean Sprout" }, { id: "carrot-cadet", name: "Carrot Cadet" }]
      });
      expect(response.status).toBe(200);
      const body = (await response.json()) as {
        opponentSquad: { id: string; rarity: string; star: number }[];
      };
      // Instance truth, defender-owned ★ (none → 1, none → common): never the
      // stored claims.
      expect(body.opponentSquad[0].rarity).toBe("common");
      expect(body.opponentSquad[0].star).toBe(1);
    });
  });

  it("ranked refuses a squad built from unowned monsters", async () => {
    await withBattle(async (call) => {
      const response = await call("POST", "/battle/ranked", {
        squad: [{ id: "cacao-phantom", name: "Cacao Phantom", statType: "vitamin" }]
      });
      expect(response.status).toBe(400);
    });
  });

  it("dungeon refuses a squad built from unowned monsters", async () => {
    await withBattle(async (call) => {
      const response = await call("POST", "/battle/dungeon/run", {
        squad: [{ id: "the-first-seed", name: "The First Seed", statType: "fiber" }]
      });
      expect(response.status).toBe(400);
    });
  });

});
