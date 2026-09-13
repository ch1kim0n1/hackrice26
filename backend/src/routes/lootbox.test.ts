import { describe, it, expect, beforeAll, afterAll } from "vitest";
import express from "express";
import { rmSync } from "fs";
import { tmpdir } from "os";
import path from "path";
import type { Rarity } from "../types";

// ============================================================================
// Cookbooks: four fixed-price books whose published odds pick a rarity Case,
// which then mints a ★1 monster of that rarity. Plus granted Cases (ranked
// wins, promos) and the mailbox that catches inventory overflow.
//
// The properties that matter: the open is atomic (coin debit + mint + both
// ledgers commit or roll back together), a case can never open twice, and a
// full inventory overflows to the mailbox instead of evicting anything.
// ============================================================================

const DB_FILE = path.join(tmpdir(), `nutriquest-cookbooks-${process.pid}-${Date.now()}.db`);

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

  const playerId = `cookbook_${counter++}_${Date.now()}`;
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

interface CookbookSummary {
  id: string;
  name: string;
  price: number;
  odds: { rarity: string; tierChance: number }[];
}

interface OpenBody {
  id: string;
  character: { id: string; rarity: string };
  caseRarity: string;
  baseMintValue: number;
  value: number;
  coinsSpent: number;
  coinBalance: number;
  overflowed: boolean;
  reel: unknown[];
  reelWinnerIndex: number;
}

describe("cookbooks", () => {
  it("offers the spec books at their spec prices", async () => {
    await withPlayer(0, async (call) => {
      const body = (await (await call("GET", "/lootbox/cookbooks")).json()) as {
        cookbooks: CookbookSummary[];
      };
      const byId = Object.fromEntries(body.cookbooks.map((b) => [b.id, b]));

      expect(Object.keys(byId).sort()).toEqual([
        "chefs-cookbook",
        "forbidden-cookbook",
        "home-cookbook",
        "master-cookbook",
        "secret-cookbook",
        "super-simple-cookbook"
      ]);
      expect(byId["super-simple-cookbook"].price).toBe(1_000);
      expect(byId["home-cookbook"].price).toBe(1_600);
      expect(byId["chefs-cookbook"].price).toBe(3_300);
      expect(byId["master-cookbook"].price).toBe(9_200);
      expect(byId["forbidden-cookbook"].price).toBe(33_500);
      expect(byId["secret-cookbook"].price).toBe(100_000);
    });
  });

  it("never pays back more than a book costs on average", async () => {
    // Selling pays full net worth, so a book whose expected drop value beats
    // its price is an infinite coin loop: buy, open, sell, repeat.
    const { COOKBOOKS } = await import("../game/spec");
    const { expectedMintValue } = await import("../game/rarityBands");
    for (const book of COOKBOOKS) {
      const ev = Object.entries(book.odds).reduce(
        (sum, [rarity, p]) => sum + p * expectedMintValue(rarity as Rarity),
        0
      );
      expect(ev, `${book.id} EV ${Math.round(ev)} vs price ${book.price}`).toBeLessThan(book.price);
    }
  });

  it("publishes the spec's 7-tier odds table for each book", async () => {
    const { COOKBOOKS } = await import("../game/spec");
    await withPlayer(0, async (call) => {
      const body = (await (await call("GET", "/lootbox/cookbooks")).json()) as {
        cookbooks: CookbookSummary[];
      };
      for (const book of body.cookbooks) {
        const spec = COOKBOOKS.find((s) => s.id === book.id)!;
        for (const row of book.odds) {
          expect(row.tierChance).toBeCloseTo(
            (spec.odds as Record<string, number>)[row.rarity], 9);
        }
      }
    });
  });

  it("debits the price, mints inside the case rarity's band, writes both ledgers", async () => {
    await withPlayer(10_000, async (call, playerId) => {
      const { coinHistory } = await import("../services/coins");
      const { db } = await import("../db");

      const response = await call("POST", "/lootbox/cookbooks/home-cookbook/open");
      expect(response.status).toBe(200);
      const body = (await response.json()) as OpenBody;

      expect(body.coinsSpent).toBe(1_600);
      expect(body.coinBalance).toBe(10_000 - 1_600);

      const { RARITY_BANDS } = await import("../game/rarityBands");
      const band = RARITY_BANDS[body.caseRarity as keyof typeof RARITY_BANDS];
      expect(body.character.rarity).toBe(body.caseRarity);
      expect(body.baseMintValue).toBeGreaterThanOrEqual(band.min);
      expect(body.baseMintValue).toBeLessThanOrEqual(band.max);
      expect(body.value).toBe(body.baseMintValue);

      const debit = coinHistory(playerId).find((e) => e.reason === "case_open");
      expect(debit?.amount).toBe(-1_600);
      expect(debit?.refId).toBe("home-cookbook");

      const charLedger = db
        .prepare(`SELECT kind, drop_ids FROM character_ledger WHERE player_id = ?`)
        .all(playerId) as { kind: string; drop_ids: string }[];
      expect(charLedger.some((r) => r.kind === "cookbook_open")).toBe(true);
    });
  });

  it("refuses without minting or debiting when coins are short", async () => {
    await withPlayer(0, async (call, playerId) => {
      const { coinBalance } = await import("../services/coins");
      const { stateFor } = await import("../services/lootboxState");

      const before = stateFor(playerId).inventory.length;
      const response = await call("POST", "/lootbox/cookbooks/home-cookbook/open");

      expect(response.status).toBe(402);
      expect(coinBalance(playerId)).toBe(0);
      // The mint rolled back with the debit — nothing half-applied.
      expect(stateFor(playerId).inventory.length).toBe(before);
    });
  });

  it("two racing opens cannot share one balance", async () => {
    // Enough for exactly one Home Cookbook: whichever request commits first
    // wins, and the loser must 402 — the debit and the balance check are one
    // atomic step inside BEGIN IMMEDIATE.
    await withPlayer(1_600, async (call, playerId) => {
      const { coinBalance } = await import("../services/coins");
      const results = await Promise.all([
        call("POST", "/lootbox/cookbooks/home-cookbook/open"),
        call("POST", "/lootbox/cookbooks/home-cookbook/open")
      ]);
      const statuses = results.map((r) => r.status).sort();
      expect(statuses).toEqual([200, 402]);
      expect(coinBalance(playerId)).toBe(0);
    });
  });

  it("404s on an unknown cookbook", async () => {
    await withPlayer(1_000, async (call) => {
      const response = await call("POST", "/lootbox/cookbooks/not-a-book/open");
      expect(response.status).toBe(404);
    });
  });
});

describe("granted cases", () => {
  it("a ranked/promo case opens through the same mint path and can never open twice", async () => {
    await withPlayer(0, async (call, playerId) => {
      const { grantCase } = await import("../services/lootboxState");
      const granted = grantCase(playerId, "epic", "ranked_win");

      const list = (await (await call("GET", "/lootbox/cases")).json()) as {
        cases: { caseId: string; rarity: string; source: string }[];
      };
      expect(list.cases).toHaveLength(1);
      expect(list.cases[0].rarity).toBe("epic");

      const first = await call("POST", `/lootbox/cases/${granted.caseId}/open`);
      expect(first.status).toBe(200);
      const body = (await first.json()) as OpenBody;
      expect(body.caseRarity).toBe("epic");
      expect(body.character.rarity).toBe("epic");
      // A case costs no coins.
      expect(body.coinsSpent ?? 0).toBe(0);

      // The row is gone — a racing or replayed second open sees nothing.
      const second = await call("POST", `/lootbox/cases/${granted.caseId}/open`);
      expect(second.status).toBe(404);
    });
  });
});

describe("mailbox overflow", () => {
  it("a mint over the 200-cap lands in the mailbox, never evicts", async () => {
    await withPlayer(0, async (call, playerId) => {
      const { stateFor } = await import("../services/lootboxState");
      const { testDrop } = await import("../testkit");
      const { INVENTORY_CAP } = await import("../game/spec");
      const session = stateFor(playerId);

      // Fill to the cap on top of the starter roster.
      const starterCount = session.inventory.length;
      for (let i = starterCount; i < INVENTORY_CAP; i++) {
        session.record(testDrop());
      }
      expect(session.inventory.length).toBe(INVENTORY_CAP);
      const oldestId = session.inventory[0].id;

      const extra = session.record(testDrop());
      expect(extra.overflowed).toBe(true);
      expect(session.mailbox).toHaveLength(1);
      // Nothing was evicted — the first monster is still there.
      expect(session.dropById(oldestId)).toBeDefined();
    });
  });

  it("claim moves mailbox drops into free inventory space", async () => {
    await withPlayer(0, async (call, playerId) => {
      const { stateFor } = await import("../services/lootboxState");
      const { testDrop } = await import("../testkit");
      const { INVENTORY_CAP } = await import("../game/spec");
      const session = stateFor(playerId);

      for (let i = session.inventory.length; i < INVENTORY_CAP; i++) {
        session.record(testDrop());
      }
      const overflow = session.record(testDrop()).drop;

      // Free one slot, then claim.
      session.removeDrops([session.inventory[0].id]);
      const response = await call("POST", "/lootbox/mailbox/claim", { dropIds: [overflow.id] });
      expect(response.status).toBe(200);
      const body = (await response.json()) as { claimed: string[]; mailboxCount: number };
      expect(body.claimed).toEqual([overflow.id]);
      expect(body.mailboxCount).toBe(0);
      expect(session.dropById(overflow.id)).toBeDefined();
    });
  });

  it("claim refuses when there is no room — the drop stays in the mailbox", async () => {
    await withPlayer(0, async (call, playerId) => {
      const { stateFor } = await import("../services/lootboxState");
      const { testDrop } = await import("../testkit");
      const { INVENTORY_CAP } = await import("../game/spec");
      const session = stateFor(playerId);

      for (let i = session.inventory.length; i < INVENTORY_CAP; i++) {
        session.record(testDrop());
      }
      const overflow = session.record(testDrop()).drop;

      const response = await call("POST", "/lootbox/mailbox/claim", { dropIds: [overflow.id] });
      expect(response.status).toBe(200);
      const body = (await response.json()) as { claimed: string[]; remaining: number };
      expect(body.claimed).toEqual([]);
      expect(body.remaining).toBe(1);
    });
  });

  it("locked stakes still occupy their slot — the cap counts every row", async () => {
    await withPlayer(0, async (call, playerId) => {
      const { stateFor } = await import("../services/lootboxState");
      const { testDrop } = await import("../testkit");
      const { INVENTORY_CAP } = await import("../game/spec");
      const session = stateFor(playerId);

      // Fill to the cap, then lock a stake: available drops dip under 200
      // but the inventory rows still count.
      for (let i = session.inventory.length; i < INVENTORY_CAP; i++) {
        session.record(testDrop());
      }
      const staked = session.inventory[session.inventory.length - 1];
      session.lockDrop(staked.id, "cauldron");

      const mint = session.record(testDrop());
      expect(mint.overflowed).toBe(true);
      expect(session.inventory.length).toBe(INVENTORY_CAP);
      expect(session.mailbox).toHaveLength(1);

      // The full inventory still fits the /inventory page — no row is
      // truncated out of the payload.
      const response = await call("GET", "/lootbox/inventory?limit=200");
      const body = (await response.json()) as { count: number; items: unknown[] };
      expect(body.count).toBe(INVENTORY_CAP);
      expect(body.items).toHaveLength(INVENTORY_CAP);
    });
  });
});

describe("verification", () => {
  it("replays a past open from the disclosed inputs", async () => {
    await withPlayer(10_000, async (call, playerId) => {
      const { stateFor } = await import("../services/lootboxState");
      const { hashSeed } = await import("../services/lootboxEngine");

      const session = stateFor(playerId);
      const pair = session.current;
      const opened = (await (
        await call("POST", "/lootbox/cookbooks/chefs-cookbook/open")
      ).json()) as OpenBody & { fairness: { nonce: number; clientSeed: string } };

      const response = await call("POST", "/lootbox/verify", {
        bookId: "chefs-cookbook",
        serverSeed: pair.serverSeed,
        clientSeed: opened.fairness.clientSeed,
        nonce: opened.fairness.nonce
      });
      expect(response.status).toBe(200);
      const body = (await response.json()) as {
        serverSeedHash: string;
        result: { caseRarity: string; baseMintValue: number; character: { id: string } };
      };
      expect(body.serverSeedHash).toBe(hashSeed(pair.serverSeed));
      expect(body.result.caseRarity).toBe(opened.caseRarity);
      expect(body.result.baseMintValue).toBe(opened.baseMintValue);
      expect(body.result.character.id).toBe(opened.character.id);
    });
  });
});
