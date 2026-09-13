import { describe, it, expect, beforeAll, afterAll, vi } from "vitest";
import express from "express";
import { rmSync } from "fs";
import { tmpdir } from "os";
import path from "path";
import type { DatabaseSync } from "node:sqlite";

// ============================================================================
// Persistence round-trips (issue #23).
//
// Every player-scoped store must survive a backend restart. "Restart" here is
// simulated by resetting the module registry and re-importing: fresh module
// instances open a fresh SQLite connection to the same file, so anything a
// test wrote before the "restart" must still be there afterwards.
// ============================================================================

const DB_FILE = path.join(tmpdir(), `nutriquest-test-${process.pid}-${Date.now()}.db`);
const PLAYER = "player_persist";
let currentDb: DatabaseSync | undefined;

beforeAll(() => {
  process.env.NUTRIQUEST_DB = DB_FILE;
});

afterAll(() => {
  if (currentDb?.isOpen) currentDb.close();
  rmSync(DB_FILE, { force: true });
  rmSync(`${DB_FILE}-wal`, { force: true });
  rmSync(`${DB_FILE}-shm`, { force: true });
});

/** Fresh module graph + fresh DB connection to the same file = a "restart". */
async function restart() {
  if (currentDb?.isOpen) currentDb.close();
  vi.resetModules();
  const [lootbox, scan, vitals, index, database] = await Promise.all([
    import("../services/lootboxState"),
    import("../routes/scan"),
    import("../vitals/vitalsStore"),
    import("../index"),
    import("../db")
  ]);
  currentDb = database.db;
  return { lootbox, scan, vitals, index };
}

function offProduct(name: string) {
  return {
    status: 1,
    product: {
      product_name_en: name,
      nutriments: { proteins_100g: 8, fiber_100g: 3, sugars_100g: 5 },
      vitamins_tags: ["en:vitamin-c"]
    }
  };
}

describe("state survives a restart", () => {
  it("keeps lootbox keys and inventory", async () => {
    const first = await restart();
    const session = first.lootbox.stateFor(PLAYER);
    session.grantKeys(30);
    expect(session.keys).toBe(55); // 25 starting + 30 granted
    session.record({
      crateId: "starter-crate",
      character: { id: "water-droplet", name: "Water Droplet", colorHex: "#7CC5E8", rarity: "common", statType: "hydration", isLocked: false },
      power: 33.3,
      powerLabel: "Feeble",
      shiny: false,
      value: 9,
      rolls: { rarity: 1, character: 2, power: 3, shiny: 4 },
      fairness: { serverSeedHash: "hash", clientSeed: "seed", nonce: 0 },
      openedAt: new Date().toISOString()
    });

    const second = await restart();
    const rehydrated = second.lootbox.stateFor(PLAYER);
    expect(rehydrated.keys).toBe(55);
    // Every fresh player also owns the starter roster now (crateId
    // "starter-roster", seeded once on first attach — lootboxState.ts) —
    // filter to just what this test itself recorded.
    const own = rehydrated.inventory.filter((d) => d.crateId === "starter-crate");
    expect(own).toHaveLength(1);
    expect(own[0].character.id).toBe("water-droplet");
  });

  it("keeps scan collections and the one-barcode rule", async () => {
    const first = await restart();
    const router = first.scan.createScanRouter(async () => offProduct("Nutella") as never);
    const app = express();
    app.use(express.json());
    app.use("/scan", router);
    const server = app.listen(0);
    const port = (server.address() as { port: number }).port;
    const headers = { "content-type": "application/json", "x-player-id": PLAYER };
    await fetch(`http://127.0.0.1:${port}/scan`, { method: "POST", headers, body: JSON.stringify({ barcode: "3017620422003" }) });
    await new Promise<void>((resolve) => server.close(() => resolve()));

    const second = await restart();
    const router2 = second.scan.createScanRouter(async () => offProduct("Nutella") as never);
    const app2 = express();
    app2.use(express.json());
    app2.use("/scan", router2);
    const server2 = app2.listen(0);
    const port2 = (server2.address() as { port: number }).port;

    const collection = (await (await fetch(`http://127.0.0.1:${port2}/scan/collection/${PLAYER}`, { headers })).json()) as { characters: { id: string }[] };
    expect(collection.characters.map((c: { id: string }) => c.id)).toContain("scan-3017620422003");

    // The one-barcode rule also survives: same barcode is a duplicate now.
    const rescan = await fetch(`http://127.0.0.1:${port2}/scan`, { method: "POST", headers, body: JSON.stringify({ barcode: "3017620422003" }) });
    expect(((await rescan.json()) as { result: { duplicate: boolean } }).result.duplicate).toBe(true);
    await new Promise<void>((resolve) => server2.close(() => resolve()));
  });

  it("keeps profiles", async () => {
    const first = await restart();
    const server = first.index.buildApp().listen(0);
    const port = (server.address() as { port: number }).port;
    const headers = { "content-type": "application/json", "x-player-id": PLAYER };
    const put = await fetch(`http://127.0.0.1:${port}/user/${PLAYER}`, {
      method: "PUT",
      headers,
      body: JSON.stringify({ displayName: "Persisted Trainer" })
    });
    expect(put.status).toBe(200);
    await new Promise<void>((resolve) => server.close(() => resolve()));

    const second = await restart();
    const server2 = second.index.buildApp().listen(0);
    const port2 = (server2.address() as { port: number }).port;
    const get = await fetch(`http://127.0.0.1:${port2}/user/${PLAYER}`, { headers });
    const body = (await get.json()) as { profile: { displayName: string } };
    expect(body.profile.displayName).toBe("Persisted Trainer");
    await new Promise<void>((resolve) => server2.close(() => resolve()));
  });

  it("keeps vitals history", async () => {
    const first = await restart();
    const snapshot = {
      receivedAt: new Date().toISOString(),
      snapshot: {
        timestamp: new Date().toISOString(),
        testerId: PLAYER,
        heartRateBpm: 72,
        restingHeartRateBpm: null,
        hrvMs: null,
        stepsToday: 8000,
        activeCaloriesToday: null,
        exerciseMinutesToday: null,
        exerciseGoalMinutes: null,
        standHoursToday: null,
        standGoalHours: null,
        recentWorkouts: []
      },
      analysis: {}
    };
    first.vitals.vitalsStoreFor(PLAYER).add(snapshot);

    const second = await restart();
    const store = second.vitals.vitalsStoreFor(PLAYER);
    expect(store.count).toBe(1);
    expect(store.latest()?.snapshot.heartRateBpm).toBe(72);
  });
});
