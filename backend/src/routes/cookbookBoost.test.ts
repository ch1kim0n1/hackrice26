import { describe, it, expect, beforeAll, afterAll } from "vitest";
import express from "express";
import { rmSync } from "fs";
import { tmpdir } from "os";
import path from "path";

// ============================================================================
// Cookbook Boost (spec §6): a stored boost — earned every 5th nutrition-streak
// day — multiplies Rare+ odds ×1.15 on ONE cookbook open, renormalized. The
// spend happens inside the open transaction, so a failed open refunds it, and
// the boosted flag lands on the drop + ledger so /lootbox/verify can
// recompute against the same odds table.
// ============================================================================

const DB_FILE = path.join(tmpdir(), `nutriquest-boost-${process.pid}-${Date.now()}.db`);

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
  run: (call: Call, playerId: string) => Promise<void>
): Promise<void> {
  const { lootboxRouter } = await import("./lootbox");
  const { recordCoins } = await import("../services/coins");

  const playerId = `boost_${counter++}_${Date.now()}`;
  recordCoins(playerId, 100_000, "grant");

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

async function grantBoosts(playerId: string, n: number) {
  const { getOrCreate, saveProfile } = await import("./user");
  const profile = getOrCreate(playerId);
  profile.cookbookBoosts = n;
  saveProfile(playerId, profile);
}

async function boostCount(playerId: string) {
  const { cookbookBoosts } = await import("./user");
  return cookbookBoosts(playerId);
}

const CHEAPEST = "home-cookbook";

describe("boostedOdds", () => {
  it("scales Rare+ by 1.15 and renormalizes to 1", async () => {
    const { boostedOdds } = await import("../services/lootboxEngine");
    const { COOKBOOKS } = await import("../data/lootTable");
    const book = COOKBOOKS[0];
    const boosted = boostedOdds(book.odds);

    const total = Object.values(boosted).reduce((a, b) => a + b, 0);
    expect(total).toBeCloseTo(1, 10);
    // The pre-normalization scale factor: Σ published × (1 or 1.15).
    const exempt = new Set(["common", "uncommon"]);
    const scaled = Object.entries(book.odds).reduce(
      (sum, [r, w]) => sum + (w ?? 0) * (exempt.has(r) ? 1 : 1.15),
      0
    );
    // Every Rare+ tier is exactly ×(1.15/scaled) relative to its published share.
    for (const r of ["rare", "epic", "legendary", "mythic", "secret"] as const) {
      const published = book.odds[r] ?? 0;
      if (published === 0) continue;
      expect(boosted[r]! / published).toBeCloseTo(1.15 / scaled, 5);
      expect(boosted[r]!).toBeGreaterThan(published);
    }
    // Exempt tiers shrink relative to the book (mass moved upward).
    for (const r of ["common", "uncommon"] as const) {
      const published = book.odds[r] ?? 0;
      if (published === 0) continue;
      expect(boosted[r]!).toBeLessThan(published);
    }
  });
});

describe("POST /lootbox/cookbooks/:id/open with useBoost", () => {
  it("consumes one boost and flags the open", async () => {
    await withPlayer(async (call, playerId) => {
      await grantBoosts(playerId, 2);

      const res = await call("POST", `/lootbox/cookbooks/${CHEAPEST}/open`, { useBoost: true });
      expect(res.status).toBe(200);
      const body = (await res.json()) as { boostApplied: boolean };
      expect(body.boostApplied).toBe(true);
      expect(await boostCount(playerId)).toBe(1);
    });
  });

  it("opens unboosted when none are held — never a dead end", async () => {
    await withPlayer(async (call, playerId) => {
      const res = await call("POST", `/lootbox/cookbooks/${CHEAPEST}/open`, { useBoost: true });
      expect(res.status).toBe(200);
      const body = (await res.json()) as { boostApplied: boolean };
      expect(body.boostApplied).toBe(false);
      expect(await boostCount(playerId)).toBe(0);
    });
  });

  it("does not spend a held boost unless asked", async () => {
    await withPlayer(async (call, playerId) => {
      await grantBoosts(playerId, 1);

      const res = await call("POST", `/lootbox/cookbooks/${CHEAPEST}/open`, {});
      expect(res.status).toBe(200);
      const body = (await res.json()) as { boostApplied: boolean };
      expect(body.boostApplied).toBe(false);
      expect(await boostCount(playerId)).toBe(1);
    });
  });

  it("a boosted open verifies against the boosted table", async () => {
    await withPlayer(async (call, playerId) => {
      await grantBoosts(playerId, 1);
      const clientSeed = "verify-me-please";

      const open = await call("POST", `/lootbox/cookbooks/${CHEAPEST}/open`, { useBoost: true, clientSeed });
      expect(open.status).toBe(200);
      const opened = (await open.json()) as {
        boostApplied: boolean;
        caseRarity: string;
        fairness: { serverSeedHash: string; nonce: number };
      };
      expect(opened.boostApplied).toBe(true);

      // The session's seed isn't revealed until rotation — verify through the
      // engine directly with the recorded inputs instead of the route.
      const { db } = await import("../db");
      const session = db
        .prepare(`SELECT server_seed, nonce FROM lootbox_session WHERE player_id = ?`)
        .get(playerId) as { server_seed: string; nonce: number };
      const verify = await call("POST", "/lootbox/verify", {
        bookId: CHEAPEST,
        serverSeed: session.server_seed,
        clientSeed,
        nonce: opened.fairness.nonce,
        boosted: true
      });
      expect(verify.status).toBe(200);
      const verified = (await verify.json()) as { result: { caseRarity: string } };
      expect(verified.result.caseRarity).toBe(opened.caseRarity);
    });
  });
});
