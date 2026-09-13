import { describe, it, expect, beforeAll, afterAll } from "vitest";
import express from "express";
import { rmSync } from "fs";
import { tmpdir } from "os";
import path from "path";

// ============================================================================
// Merging three copies into one of the next star.
//
// The rule these tests exist to pin: merging raises stars and value, and never
// rarity. A ★5 Common is worth more than the cheapest Uncommon and is still a
// Common — the overlap is intended (net worth spec §9, §14), and promoting the
// tier would also pay the same merge twice in combat, since game/power.ts
// multiplies rarity and stars independently.
// ============================================================================

const DB_FILE = path.join(tmpdir(), `nutriquest-merge-${process.pid}-${Date.now()}.db`);

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

/** A player holding `count` identical copies at `star`. */
async function withCopies(
  spec: { character: string; rarity?: string; value: number; star: number; count: number },
  run: (call: Call, ctx: { playerId: string; ids: string[] }) => Promise<void>
): Promise<void> {
  const { charactersRouter } = await import("./characters");
  const { stateFor } = await import("../services/lootboxState");
  const { testDrop, testCharacter } = await import("../testkit");
  const { rarityForValue } = await import("../game/rarityBands");

  const playerId = `merge_${counter++}_${Date.now()}`;
  const session = stateFor(playerId);

  const character = testCharacter(
    (spec.rarity ?? rarityForValue(spec.value)) as never,
    spec.character
  );
  const ids = Array.from({ length: spec.count }, (_, i) =>
    session.record(
      testDrop({
        crateId: "test",
        character,
        stars: spec.star,
        baseMintValue: spec.value,
        value: spec.value,
        fairness: { serverSeedHash: "hash", clientSeed: "seed", nonce: i }
      })
    ).drop.id
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
    await run(call, { playerId, ids });
  } finally {
    await new Promise<void>((resolve) => server.close(() => resolve()));
  }
}

interface MergeBody {
  merged: { id: string; stars: number; value: number; character: { rarity: string } };
  consumedIds: string[];
  to: { star: number; rarity: string; value: number };
}

describe("merging", () => {
  it("turns three copies into one of the next star", async () => {
    await withCopies({ character: "broccoli-bud", value: 500, star: 1, count: 3 }, async (call, { playerId, ids }) => {
      const { stateFor } = await import("../services/lootboxState");

      const response = await call("POST", "/characters/merge", { dropIds: ids });
      expect(response.status).toBe(200);
      const body = (await response.json()) as MergeBody;

      expect(body.to.star).toBe(2);
      expect(body.consumedIds).toHaveLength(3);
      // All three are gone and exactly one new monster exists.
      const session = stateFor(playerId);
      for (const id of ids) expect(session.dropById(id)).toBeUndefined();
      expect(session.dropById(body.merged.id)).toBeDefined();
    });
  });

  it("raises value by exactly the star bonus for that rarity", async () => {
    await withCopies({ character: "broccoli-bud", value: 500, star: 1, count: 3 }, async (call, { ids }) => {
      const { starBonus } = await import("../game/rarityBands");
      const body = (await (
        await call("POST", "/characters/merge", { dropIds: ids })
      ).json()) as MergeBody;

      expect(body.to.value).toBe(500 + starBonus("common", 2));
    });
  });

  it("never changes rarity, even when the new worth lands in the next band", async () => {
    // The decision this file exists for. A ★4 Common at 950 merges to ★5 and
    // 1,333 — past the Common ceiling of 1,099 — and stays Common.
    await withCopies({ character: "broccoli-bud", value: 950, star: 4, count: 3 }, async (call, { ids }) => {
      const { RARITY_BANDS, rarityForValue } = await import("../game/rarityBands");

      const body = (await (
        await call("POST", "/characters/merge", { dropIds: ids })
      ).json()) as MergeBody;

      expect(body.to.star).toBe(5);
      // The value really does cross the band boundary...
      expect(body.to.value).toBeGreaterThan(RARITY_BANDS.common.max);
      expect(rarityForValue(body.to.value)).toBe("uncommon");
      // ...and the monster is still Common.
      expect(body.to.rarity).toBe("common");
      expect(body.merged.character.rarity).toBe("common");
    });
  });

  it("refuses copies that are not the same character or star", async () => {
    await withCopies({ character: "broccoli-bud", value: 500, star: 1, count: 3 }, async (call, { playerId, ids }) => {
      const { stateFor } = await import("../services/lootboxState");
      const { testDrop, testCharacter } = await import("../testkit");
      const session = stateFor(playerId);

      const different = session.record(
        testDrop({
          crateId: "test",
          character: testCharacter("common", "carrot-cadet"),
          baseMintValue: 500,
          value: 500,
          fairness: { serverSeedHash: "hash", clientSeed: "seed", nonce: 9 }
        })
      ).drop;

      const mismatch = await call("POST", "/characters/merge", {
        dropIds: [ids[0], ids[1], different.id]
      });
      expect(mismatch.status).toBe(409);
      // Nothing consumed by the rejected attempt.
      expect(session.dropById(ids[0])).toBeDefined();
      expect(session.dropById(different.id)).toBeDefined();
    });
  });

  it("refuses copies of the same character at a different rarity", async () => {
    await withCopies({ character: "broccoli-bud", value: 500, star: 1, count: 3 }, async (call, { playerId, ids }) => {
      const { stateFor } = await import("../services/lootboxState");
      const { testDrop, testCharacter } = await import("../testkit");
      const session = stateFor(playerId);

      // Same character, same star — but the rarity is off.
      const offRarity = session.record(
        testDrop({
          crateId: "test",
          character: testCharacter("rare", "broccoli-bud"),
          baseMintValue: 500,
          value: 500,
          fairness: { serverSeedHash: "hash", clientSeed: "seed", nonce: 9 }
        })
      ).drop;

      const mismatch = await call("POST", "/characters/merge", {
        dropIds: [ids[0], ids[1], offRarity.id]
      });
      expect(mismatch.status).toBe(409);
      expect(session.dropById(offRarity.id)).toBeDefined();
    });
  });

  it("refuses a wrong number of copies", async () => {
    await withCopies({ character: "broccoli-bud", value: 500, star: 1, count: 3 }, async (call, { ids }) => {
      expect((await call("POST", "/characters/merge", { dropIds: ids.slice(0, 2) })).status).toBe(400);
      expect((await call("POST", "/characters/merge", { dropIds: [] })).status).toBe(400);
    });
  });

  it("refuses to merge past five stars", async () => {
    await withCopies({ character: "broccoli-bud", value: 1_333, star: 5, count: 3 }, async (call, { ids }) => {
      const response = await call("POST", "/characters/merge", { dropIds: ids });
      expect(response.status).toBe(409);
      expect(((await response.json()) as { error: { code: string } }).error.code).toBe("MAX_STAR");
    });
  });

  it("cannot consume a staked copy", async () => {
    await withCopies({ character: "broccoli-bud", value: 500, star: 1, count: 3 }, async (call, { playerId, ids }) => {
      const { stateFor } = await import("../services/lootboxState");
      const session = stateFor(playerId);
      session.lockDrop(ids[0], "arena:battle-1");

      const response = await call("POST", "/characters/merge", { dropIds: ids });
      expect(response.status).toBe(409);
      // All three survive: consumeDrops is all-or-nothing.
      for (const id of ids) expect(session.dropById(id)).toBeDefined();
    });
  });

  it("inherits the highest baseMintValue of the three consumed copies", async () => {
    // Spec §2: fusion keeps max(baseMintValue) — a valuable copy's worth
    // survives merging, not just the average. Seed three copies of the same
    // character/rarity/star with deliberately different bases.
    const { charactersRouter } = await import("./characters");
    const { stateFor } = await import("../services/lootboxState");
    const { testDrop, testCharacter } = await import("../testkit");
    const { starBonus } = await import("../game/rarityBands");

    const playerId = `merge_inherit_${Date.now()}`;
    const session = stateFor(playerId);
    const character = testCharacter("rare", "salmon-striker");
    const ids = [2_800, 3_400, 2_900].map(
      (base, i) =>
        session.record(
          testDrop({
            crateId: "test",
            character,
            stars: 1,
            baseMintValue: base,
            value: base,
            fairness: { serverSeedHash: "hash", clientSeed: "seed", nonce: i }
          })
        ).drop.id
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
      const body = (await (
        await call("POST", "/characters/merge", { dropIds: ids })
      ).json()) as MergeBody & { merged: { baseMintValue: number } };
      expect(body.merged.baseMintValue).toBe(3_400);
      expect(body.to.value).toBe(3_400 + starBonus("rare", 2));
    } finally {
      await new Promise<void>((resolve) => server.close(() => resolve()));
    }
  });

  it("refuses to fuse a Secret past ★2 — the terminal cap", async () => {
    // Spec §2: Secret is the one rarity that cannot reach ★5.
    await withCopies(
      { character: "the-first-seed", rarity: "secret", value: 200_000, star: 2, count: 3 },
      async (call, { ids }) => {
        const response = await call("POST", "/characters/merge", { dropIds: ids });
        expect(response.status).toBe(409);
        expect(((await response.json()) as { error: { code: string } }).error.code).toBe("MAX_STAR");
      }
    );
  });
});
