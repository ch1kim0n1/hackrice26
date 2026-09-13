import { describe, it, expect, beforeAll, afterAll } from "vitest";
import express from "express";
import { rmSync } from "fs";
import { tmpdir } from "os";
import path from "path";

// ============================================================================
// Shop cases: one per rarity, paid in coins, rolled exactly the way the
// Loot-Boxes-Logic branch rolls -- odds renormalised over the tiers a case
// stocks, no rank boost, no pity -- and priced with that branch's BASE_VALUES.
// ============================================================================

const DB_FILE = path.join(tmpdir(), `nutriquest-shop-cases-${process.pid}-${Date.now()}.db`);

beforeAll(() => {
  process.env.NUTRIQUEST_DB = DB_FILE;
});

afterAll(() => {
  rmSync(DB_FILE, { force: true });
  rmSync(`${DB_FILE}-wal`, { force: true });
  rmSync(`${DB_FILE}-shm`, { force: true });
});

type Call = (method: string, url: string, body?: unknown) => Promise<Response>;

let counter = 0;

async function withPlayer(
  coins: number,
  run: (call: Call, playerId: string) => Promise<void>
): Promise<void> {
  const { lootboxRouter } = await import("./lootbox");
  const { recordCoins } = await import("../services/coins");

  const playerId = `shop_case_${counter++}_${Date.now()}`;
  if (coins > 0) recordCoins(playerId, coins, "grant");

  const app = express();
  app.use(express.json());
  app.use("/lootbox", lootboxRouter);

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

interface CaseSummary {
  id: string;
  coinCost: number;
  odds: { rarity: string; tierChance: number }[];
}

interface OpenBody {
  character: { id: string; rarity: string };
  power: number;
  shiny: boolean;
  value: number;
  coinsSpent: number;
  coinBalance: number;
  reel: unknown[];
  reelWinnerIndex: number;
}

async function listCases(call: Call): Promise<CaseSummary[]> {
  const body = (await (await call("GET", "/lootbox/shop-cases")).json()) as { cases: CaseSummary[] };
  return body.cases;
}

describe("shop cases", () => {
  it("offers one case per rarity, each rarer case costing more", async () => {
    await withPlayer(0, async (call) => {
      const { RARITY_ORDER } = await import("../data/lootTable");
      const cases = await listCases(call);

      expect(cases.map((c) => c.id)).toEqual(RARITY_ORDER.map((r) => `${r}-case`));
      for (let i = 1; i < cases.length; i++) {
        expect(cases[i].coinCost).toBeGreaterThan(cases[i - 1].coinCost);
      }
    });
  });

  it("uses the branch odds: a case is its floor tier 80% of the time, renormalised over what it stocks", async () => {
    await withPlayer(0, async (call) => {
      const cases = await listCases(call);

      const rare = cases.find((c) => c.id === "rare-case")!;
      expect(rare.odds[0].rarity).toBe("rare");
      expect(rare.odds[0].tierChance).toBeCloseTo(0.8, 10);
      expect(rare.odds.some((o) => o.rarity === "common" || o.rarity === "uncommon")).toBe(false);

      const secret = cases.find((c) => c.id === "secret-case")!;
      expect(secret.odds).toHaveLength(1);
      expect(secret.odds[0].tierChance).toBe(1);
    });
  });

  it("charges the case's price and prices the drop off BASE_VALUES", async () => {
    const { BASE_VALUES } = await import("../data/lootTable");
    const { powerBandFor, SHINY_MULTIPLIER, REEL_LENGTH, REEL_WINNER_INDEX } = await import("../services/lootboxEngine");

    await withPlayer(1_000_000, async (call) => {
      const rare = (await listCases(call)).find((c) => c.id === "rare-case")!;
      const response = await call("POST", "/lootbox/shop-cases/rare-case/open");
      expect(response.status).toBe(200);
      const body = (await response.json()) as OpenBody;

      expect(body.coinsSpent).toBe(rare.coinCost);
      expect(body.coinBalance).toBe(1_000_000 - rare.coinCost);
      expect(["rare", "epic", "legendary", "mythic", "secret"]).toContain(body.character.rarity);

      const rarity = body.character.rarity as keyof typeof BASE_VALUES;
      const expected = Math.round(
        BASE_VALUES[rarity] * powerBandFor(body.power).valueMultiplier * (body.shiny ? SHINY_MULTIPLIER : 1)
      );
      expect(body.value).toBe(expected);
      expect(body.reel).toHaveLength(REEL_LENGTH);
      expect(body.reelWinnerIndex).toBe(REEL_WINNER_INDEX);
    });
  });

  it("never touches keys or pity", async () => {
    await withPlayer(1_000_000, async (call, playerId) => {
      const { stateFor } = await import("../services/lootboxState");
      const session = stateFor(playerId);
      const before = { keys: session.keys, sinceEpic: session.sinceEpic, sinceLegendary: session.sinceLegendary };

      for (let i = 0; i < 3; i++) {
        expect((await call("POST", "/lootbox/shop-cases/common-case/open")).status).toBe(200);
      }

      expect({ keys: session.keys, sinceEpic: session.sinceEpic, sinceLegendary: session.sinceLegendary }).toEqual(before);
    });
  });

  it("refuses without minting a drop when coins are short", async () => {
    await withPlayer(0, async (call, playerId) => {
      const { coinBalance } = await import("../services/coins");
      const { stateFor } = await import("../services/lootboxState");

      const before = stateFor(playerId).inventory.length;
      const response = await call("POST", "/lootbox/shop-cases/common-case/open");

      expect(response.status).toBe(402);
      expect(coinBalance(playerId)).toBe(0);
      expect(stateFor(playerId).inventory.length).toBe(before);
    });
  });

  it("404s on an unknown case", async () => {
    await withPlayer(1_000, async (call) => {
      const response = await call("POST", "/lootbox/shop-cases/not-a-real-case/open");
      expect(response.status).toBe(404);
    });
  });
});
