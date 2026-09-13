import { describe, it, expect, beforeAll, afterAll } from "vitest";
import express from "express";
import { rmSync } from "fs";
import { tmpdir } from "os";
import path from "path";

// ============================================================================
// Selling a monster for coins (#115), and the lock that protects a staked one.
//
// Selling destroys something the player earned in exchange for a balance, so
// the two failure modes that matter are: paying without destroying, and
// destroying without paying. Both are tested here, along with the rule that a
// monster committed elsewhere is not the player's to liquidate.
// ============================================================================

const DB_FILE = path.join(tmpdir(), `nutriquest-sell-${process.pid}-${Date.now()}.db`);

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
  run: (call: Call, ctx: { playerId: string; monsters: { id: string; value: number }[] }) => Promise<void>
): Promise<void> {
  const { charactersRouter } = await import("./characters");
  const { stateFor } = await import("../services/lootboxState");
  const { testDrop, testCharacter } = await import("../testkit");

  const playerId = `sell_${counter++}_${Date.now()}`;
  const session = stateFor(playerId);

  const seeded = [
    { character: "salmon-striker", rarity: "rare", value: 3_000, stars: 1 },
    { character: "kale-colossus", rarity: "epic", value: 7_500, stars: 3 },
    { character: "broccoli-bud", rarity: "common", value: 600, stars: 1 }
  ].map((spec, i) =>
    session.record(
      testDrop({
        crateId: "test",
        character: testCharacter(spec.rarity as never, spec.character),
        stars: spec.stars,
        value: spec.value,
        baseMintValue: spec.value,
        fairness: { serverSeedHash: "hash", clientSeed: "seed", nonce: i }
      })
    ).drop
  );

  const app = express();
  app.use(express.json());
  app.use("/characters", charactersRouter);

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
    await run(call, { playerId, monsters: seeded.map((d) => ({ id: d.id, value: d.value })) });
  } finally {
    await new Promise<void>((resolve) => server.close(() => resolve()));
  }
}

interface SellBody {
  sold: { id: string; stars: number; netWorth: number };
  coins: number;
  balance: number;
  entryId: string;
}

describe("selling", () => {
  it("destroys the monster and credits its net worth", async () => {
    await withPlayer(async (call, { playerId, monsters }) => {
      const { stateFor } = await import("../services/lootboxState");

      const response = await call("POST", "/characters/sell", { dropId: monsters[0].id });
      expect(response.status).toBe(200);
      const body = (await response.json()) as SellBody;

      expect(body.coins).toBe(3_000);
      expect(body.balance).toBe(3_000);
      expect(stateFor(playerId).dropById(monsters[0].id)).toBeUndefined();
    });
  });

  it("pays a mastered monster's stored net worth exactly, without re-applying the star bonus", async () => {
    await withPlayer(async (call, { monsters }) => {
      const body = (await (
        await call("POST", "/characters/sell", { dropId: monsters[1].id })
      ).json()) as SellBody;

      // kale-colossus was seeded ★3 with value 7_500 -- exactly like
      // mergeDrops stores a fused monster, that 7_500 is already the current
      // total (base + mastery), not a pre-mastery base. Selling must pay
      // that total back unchanged; running it through revalue() again as if
      // it were still a base would tack the star-3 bonus on a second time.
      expect(body.coins).toBe(7_500);
    });
  });

  it("writes one ledger row per sale, pointing at what was sold", async () => {
    await withPlayer(async (call, { playerId, monsters }) => {
      const { coinHistory } = await import("../services/coins");

      await call("POST", "/characters/sell", { dropId: monsters[0].id });
      await call("POST", "/characters/sell", { dropId: monsters[2].id });

      const history = coinHistory(playerId);
      expect(history).toHaveLength(2);
      for (const entry of history) {
        expect(entry.reason).toBe("sell");
        expect([monsters[0].id, monsters[2].id]).toContain(entry.refId);
      }
      // Balance is the sum of the rows, never a stored number.
      expect(history.reduce((sum, e) => sum + e.amount, 0)).toBe(3_600);
    });
  });

  it("cannot sell the same monster twice", async () => {
    await withPlayer(async (call, { playerId, monsters }) => {
      const { coinBalance } = await import("../services/coins");

      expect((await call("POST", "/characters/sell", { dropId: monsters[0].id })).status).toBe(200);
      const replay = await call("POST", "/characters/sell", { dropId: monsters[0].id });
      expect(replay.status).toBe(404);
      // Paid once, not twice.
      expect(coinBalance(playerId)).toBe(3_000);
    });
  });

  it("refuses a monster that isn't yours, and pays nothing", async () => {
    await withPlayer(async (call, { playerId }) => {
      const { coinBalance } = await import("../services/coins");
      const response = await call("POST", "/characters/sell", { dropId: "not-a-monster" });
      expect(response.status).toBe(404);
      expect(coinBalance(playerId)).toBe(0);
    });
  });

  it("rejects a malformed request", async () => {
    await withPlayer(async (call) => {
      expect((await call("POST", "/characters/sell", {})).status).toBe(400);
      expect((await call("POST", "/characters/sell", { dropId: "" })).status).toBe(400);
    });
  });

  it("reports the balance and the rows behind it", async () => {
    await withPlayer(async (call, { monsters }) => {
      await call("POST", "/characters/sell", { dropId: monsters[2].id });
      const coins = (await (await call("GET", "/characters/coins")).json()) as {
        balance: number;
        history: { reason: string; amount: number }[];
      };
      expect(coins.balance).toBe(600);
      expect(coins.history[0].reason).toBe("sell");
    });
  });
});

describe("locked monsters", () => {
  it("cannot be sold", async () => {
    await withPlayer(async (call, { playerId, monsters }) => {
      const { stateFor } = await import("../services/lootboxState");
      const { coinBalance } = await import("../services/coins");
      const session = stateFor(playerId);

      expect(session.lockDrop(monsters[0].id, "arena:battle-1")).toBe(true);

      const response = await call("POST", "/characters/sell", { dropId: monsters[0].id });
      expect(response.status).toBe(409);
      expect(((await response.json()) as { error: { code: string } }).error.code).toBe("LOCKED");

      // Still owned, still nothing paid.
      expect(session.dropById(monsters[0].id)).toBeDefined();
      expect(coinBalance(playerId)).toBe(0);
    });
  });

  it("cannot be gambled either — the guard is in one place", async () => {
    await withPlayer(async (call, { playerId, monsters }) => {
      const { stateFor } = await import("../services/lootboxState");
      const session = stateFor(playerId);
      session.lockDrop(monsters[0].id, "arena:battle-1");

      // consumeDrops is what every game spends through, so locking once
      // protects the monster from all of them.
      expect(session.consumeDrops([monsters[0].id])).toBeNull();
      expect(session.consumeDrops([monsters[0].id, monsters[2].id])).toBeNull();
      // ...and the unlocked one in that rejected pair is untouched.
      expect(session.dropById(monsters[2].id)).toBeDefined();
    });
  });

  it("can be sold again once released", async () => {
    await withPlayer(async (call, { playerId, monsters }) => {
      const { stateFor } = await import("../services/lootboxState");
      const session = stateFor(playerId);

      session.lockDrop(monsters[0].id, "arena:battle-1");
      expect((await call("POST", "/characters/sell", { dropId: monsters[0].id })).status).toBe(409);

      session.unlockDrop(monsters[0].id);
      expect((await call("POST", "/characters/sell", { dropId: monsters[0].id })).status).toBe(200);
    });
  });

  it("refuses to be locked twice", async () => {
    await withPlayer(async (call, { playerId, monsters }) => {
      const { stateFor } = await import("../services/lootboxState");
      const session = stateFor(playerId);

      expect(session.lockDrop(monsters[0].id, "arena:battle-1")).toBe(true);
      // A second holder must not be able to believe it took the same monster.
      expect(session.lockDrop(monsters[0].id, "arena:battle-2")).toBe(false);
      expect(session.availableDrops().map((d) => d.id)).not.toContain(monsters[0].id);
    });
  });
});

describe("the coin ledger", () => {
  it("refuses to go negative", async () => {
    await withPlayer(async (call, { playerId }) => {
      const { COIN_ERRORS, recordCoins, coinBalance } = await import("../services/coins");
      expect(() => recordCoins(playerId, -100, "gamble_stake")).toThrow(COIN_ERRORS.INSUFFICIENT);
      expect(coinBalance(playerId)).toBe(0);
    });
  });

  it("refuses a zero or fractional amount", async () => {
    await withPlayer(async (call, { playerId }) => {
      const { COIN_ERRORS, recordCoins } = await import("../services/coins");
      expect(() => recordCoins(playerId, 0, "grant")).toThrow(COIN_ERRORS.BAD_AMOUNT);
      expect(() => recordCoins(playerId, 1.5, "grant")).toThrow(COIN_ERRORS.BAD_AMOUNT);
    });
  });

  it("spends only down to zero", async () => {
    await withPlayer(async (call, { playerId }) => {
      const { recordCoins, coinBalance } = await import("../services/coins");
      recordCoins(playerId, 500, "grant");
      recordCoins(playerId, -500, "battle_stake", "battle-1");
      expect(coinBalance(playerId)).toBe(0);
      expect(() => recordCoins(playerId, -1, "battle_stake")).toThrow();
    });
  });
});
