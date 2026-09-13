import { describe, it, expect, beforeAll, afterAll } from "vitest";
import express from "express";
import { rmSync } from "fs";
import { tmpdir } from "os";
import path from "path";

// ============================================================================
// Kitchen Mines — the transactional rules and the one secret.
//
// The secret is where the mines are. Everything else about a round is
// published, so these tests care mostly about two things: that the layout
// never reaches a client while the board is live, and that a committed
// monster is gone exactly once.
// ============================================================================

const DB_FILE = path.join(tmpdir(), `nutriquest-mines-${process.pid}-${Date.now()}.db`);

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
  run: (call: Call, monsters: { id: string; netWorth: number }[]) => Promise<void>
): Promise<void> {
  const { minesRouter } = await import("./mines");
  const { stateFor } = await import("../services/lootboxState");
  const { testDrop, testCharacter } = await import("../testkit");

  const playerId = `mines_${counter++}_${Date.now()}`;
  const session = stateFor(playerId);

  const seeded = ["salmon-striker", "broccoli-bud"].map((characterId, i) =>
    session.record(testDrop({
      crateId: "starter-crate",
      character: testCharacter("common", characterId),
      value: [12_000, 600][i],
      rolls: { rarity: 0.1, character: 0.1, mintSegment: 0, mintPosition: 0.1 },
      fairness: { serverSeedHash: "hash", clientSeed: "seed", nonce: i },
      openedAt: new Date().toISOString()
    })).drop
  );

  const app = express();
  app.use(express.json());
  app.use("/mines", minesRouter);

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

interface Round {
  roundId: string;
  status: string;
  mines: number;
  safeDishes: number;
  picks: number;
  revealed: number[];
  multiplier: number;
  netWorth: number;
  wagerValue: number;
  cleared: boolean;
  next: { multiplier: number; netWorth: number; safeChance: number } | null;
  layout?: number[];
  finalNetWorth?: number | null;
  lostNetWorth?: number;
  reward?: { id: string; stars: number } | null;
}

/** Turn dishes over until the round ends or the board is cleared. */
async function playUntilDone(call: Call, round: Round): Promise<Round> {
  let current = round;
  for (let tile = 0; tile < 25 && current.status === "ACTIVE"; tile++) {
    if (current.revealed.includes(tile)) continue;
    const body = (await (
      await call("POST", `/mines/rounds/${current.roundId}/reveal`, { tile })
    ).json()) as { round: Round };
    current = body.round;
  }
  return current;
}

describe("starting a board", () => {
  it("commits one monster and locks the mine count", async () => {
    await withPlayer(async (call, monsters) => {
      const response = await call("POST", "/mines/rounds", { dropId: monsters[0].id, mines: 5 });
      expect(response.status).toBe(201);
      const { round } = (await response.json()) as { round: Round };

      expect(round.status).toBe("ACTIVE");
      expect(round.mines).toBe(5);
      expect(round.safeDishes).toBe(20);
      expect(round.wagerValue).toBe(12_000);
      expect(round.multiplier).toBe(1);
      expect(round.netWorth).toBe(12_000);

      // Gone from the bank the moment the board is laid.
      const state = (await (await call("GET", "/mines/state")).json()) as {
        wagerable: { id: string }[];
      };
      expect(state.wagerable.map((m) => m.id)).not.toContain(monsters[0].id);
    });
  });

  it("never discloses where the mines are while the board is live", async () => {
    await withPlayer(async (call, monsters) => {
      const { round } = (await (
        await call("POST", "/mines/rounds", { dropId: monsters[0].id, mines: 12 })
      ).json()) as { round: Round };
      expect(Object.keys(round)).not.toContain("layout");

      // Still silent after a safe reveal, and in /state.
      await call("POST", `/mines/rounds/${round.roundId}/reveal`, { tile: 0 });
      const state = (await (await call("GET", "/mines/state")).json()) as { round: Round | null };
      if (state.round?.status === "ACTIVE") {
        expect(Object.keys(state.round)).not.toContain("layout");
      }
    });
  });

  it("refuses an illegal mine count", async () => {
    await withPlayer(async (call, monsters) => {
      for (const mines of [0, 25, 99, -1]) {
        const response = await call("POST", "/mines/rounds", { dropId: monsters[0].id, mines });
        expect(response.status).toBe(400);
      }
      // ...and nothing was consumed by the attempts.
      const state = (await (await call("GET", "/mines/state")).json()) as {
        wagerable: { id: string }[];
      };
      expect(state.wagerable.map((m) => m.id)).toContain(monsters[0].id);
    });
  });

  it("refuses a second board while one is live", async () => {
    await withPlayer(async (call, monsters) => {
      await call("POST", "/mines/rounds", { dropId: monsters[0].id, mines: 3 });
      const second = await call("POST", "/mines/rounds", { dropId: monsters[1].id, mines: 3 });
      expect(second.status).toBe(409);
    });
  });

  it("refuses a monster that isn't yours", async () => {
    await withPlayer(async (call) => {
      const response = await call("POST", "/mines/rounds", { dropId: "not-a-real-drop", mines: 5 });
      expect(response.status).toBe(409);
    });
  });
});

describe("lifting dishes", () => {
  it("pays the published ladder as safe dishes come up", async () => {
    await withPlayer(async (call, monsters) => {
      const { multiplierAfter } = await import("../services/minesEngine");
      const { round } = (await (
        await call("POST", "/mines/rounds", { dropId: monsters[0].id, mines: 1 })
      ).json()) as { round: Round };

      let current = round;
      for (let tile = 0; tile < 25 && current.status === "ACTIVE"; tile++) {
        const body = (await (
          await call("POST", `/mines/rounds/${current.roundId}/reveal`, { tile })
        ).json()) as { round: Round; safe: boolean };
        current = body.round;
        if (body.safe) {
          // The multiplier is exactly the one the payout table publishes for
          // this many picks -- never a number invented mid-round.
          expect(current.multiplier).toBe(multiplierAfter(1, current.picks));
          expect(current.netWorth).toBe(Math.floor(12_000 * current.multiplier));
        }
      }
      expect(["BURNT", "ACTIVE", "SERVED"]).toContain(current.status);
    });
  });

  it("previews the next dish without saying which one is safe", async () => {
    await withPlayer(async (call, monsters) => {
      const { round } = (await (
        await call("POST", "/mines/rounds", { dropId: monsters[0].id, mines: 5 })
      ).json()) as { round: Round };

      expect(round.next).not.toBeNull();
      expect(round.next!.multiplier).toBeGreaterThan(round.multiplier);
      expect(round.next!.netWorth).toBeGreaterThan(round.netWorth);
      expect(round.next!.safeChance).toBeCloseTo(20 / 25, 6);
      // The preview is a number, not a location.
      expect(JSON.stringify(round.next)).not.toContain("tile");
    });
  });

  it("refuses the same dish twice and rejects tiles off the board", async () => {
    await withPlayer(async (call, monsters) => {
      const { round } = (await (
        await call("POST", "/mines/rounds", { dropId: monsters[0].id, mines: 1 })
      ).json()) as { round: Round };

      const first = (await (
        await call("POST", `/mines/rounds/${round.roundId}/reveal`, { tile: 4 })
      ).json()) as { safe: boolean; round: Round };

      if (first.safe) {
        const repeat = await call("POST", `/mines/rounds/${round.roundId}/reveal`, { tile: 4 });
        expect(repeat.status).toBe(409);
      }
      expect((await call("POST", `/mines/rounds/${round.roundId}/reveal`, { tile: 25 })).status).toBe(400);
      expect((await call("POST", `/mines/rounds/${round.roundId}/reveal`, { tile: -1 })).status).toBe(400);
    });
  });

  it("opens the board once the round is over", async () => {
    await withPlayer(async (call, monsters) => {
      const { round } = (await (
        await call("POST", "/mines/rounds", { dropId: monsters[0].id, mines: 20 })
      ).json()) as { round: Round };

      const finished = await playUntilDone(call, round);
      expect(finished.status).not.toBe("ACTIVE");
      // Now, and only now, the layout is disclosed so the result screen can
      // show what was where.
      expect(finished.layout).toBeDefined();
      expect(finished.layout).toHaveLength(20);
    });
  });
});

describe("serving and burning", () => {
  it("destroys the wager and mints one new monster on a cash-out", async () => {
    await withPlayer(async (call, monsters) => {
      const { round } = (await (
        await call("POST", "/mines/rounds", { dropId: monsters[0].id, mines: 1 })
      ).json()) as { round: Round };

      const served = (await (
        await call("POST", `/mines/rounds/${round.roundId}/cashout`)
      ).json()) as { round: Round };

      expect(served.round.status).toBe("SERVED");
      expect(served.round.finalNetWorth).toBe(12_000); // 1.00x at zero picks
      expect(served.round.reward).not.toBeNull();
      expect(served.round.reward!.stars).toBe(1);

      const state = (await (await call("GET", "/mines/state")).json()) as {
        wagerable: { id: string }[];
      };
      const owned = state.wagerable.map((m) => m.id);
      expect(owned).not.toContain(monsters[0].id); // wager gone
      expect(owned).toContain(served.round.reward!.id); // reward is a NEW instance
      expect(served.round.reward!.id).not.toBe(monsters[0].id);
    });
  });

  it("pays exactly once, however many times it is asked", async () => {
    await withPlayer(async (call, monsters) => {
      const { round } = (await (
        await call("POST", "/mines/rounds", { dropId: monsters[0].id, mines: 2 })
      ).json()) as { round: Round };

      const first = (await (await call("POST", `/mines/rounds/${round.roundId}/cashout`)).json()) as { round: Round };
      const second = (await (await call("POST", `/mines/rounds/${round.roundId}/cashout`)).json()) as { round: Round };

      expect(second.round.status).toBe(first.round.status);
      expect(second.round.reward?.id ?? null).toBe(first.round.reward?.id ?? null);

      const state = (await (await call("GET", "/mines/state")).json()) as {
        wagerable: { id: string }[];
      };
      const rewardId = first.round.reward?.id ?? "none";
      expect(state.wagerable.filter((m) => m.id === rewardId)).toHaveLength(1);
    });
  });

  it("gives nothing back when a dish comes up burnt", async () => {
    await withPlayer(async (call, monsters) => {
      // 24 mines: the first pick is burnt 96% of the time.
      const { round } = (await (
        await call("POST", "/mines/rounds", { dropId: monsters[1].id, mines: 24 })
      ).json()) as { round: Round };

      const finished = await playUntilDone(call, round);

      if (finished.status === "BURNT") {
        expect(finished.reward ?? null).toBeNull();
        expect(finished.lostNetWorth).toBe(600);

        // Cashing out afterwards cannot resurrect it.
        const attempted = (await (
          await call("POST", `/mines/rounds/${finished.roundId}/cashout`)
        ).json()) as { round: Round };
        expect(attempted.round.status).toBe("BURNT");
        expect(attempted.round.reward ?? null).toBeNull();
      }

      const state = (await (await call("GET", "/mines/state")).json()) as {
        wagerable: { id: string }[];
      };
      expect(state.wagerable.map((m) => m.id)).not.toContain(monsters[1].id);
    });
  });
});

describe("published rules", () => {
  it("serves the board shape, the edge and the payout ladder", async () => {
    await withPlayer(async (call) => {
      const config = (await (await call("GET", "/mines/config")).json()) as {
        houseEdge: number;
        tileCount: number;
        minMines: number;
        maxMines: number;
        rarityRanges: unknown[];
      };
      expect(config.houseEdge).toBe(0.05);
      expect(config.tileCount).toBe(25);
      expect(config.minMines).toBe(1);
      expect(config.maxMines).toBe(24);
      expect(config.rarityRanges).toHaveLength(7);

      const payouts = (await (await call("GET", "/mines/payouts?mines=5")).json()) as {
        mines: number;
        safeDishes: number;
        rungs: { picks: number; multiplier: number }[];
      };
      expect(payouts.safeDishes).toBe(20);
      expect(payouts.rungs).toHaveLength(20);
      expect(payouts.rungs[0].multiplier).toBe(1.18);
      expect((await call("GET", "/mines/payouts?mines=99")).status).toBe(400);
    });
  });
});
