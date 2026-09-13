import { describe, it, expect } from "vitest";
import express from "express";
import { createScanRouter, OFFProduct } from "./scan";

// ============================================================================
// Scan -> character -> collection pipeline (issue #24).
//
// Covers the round-trip the app depends on: POST /scan mints a character,
// GET /scan/collection/:playerId returns it, the one-barcode-per-day rule
// holds, and every store is scoped to the X-Player-Id header (the #22 fix).
// Open Food Facts is stubbed so the suite is hermetic; each test boots its
// own router with fresh player ids so neither in-memory nor persisted state
// leaks between cases.
// ============================================================================

const NUTELLA = "3017620422003";
const COKE = "5449000000996";
const MISSING = "0000000000000";

let playerCounter = 0;

/** Fresh player pair per test — scan state persists in SQLite, so reusing ids
 *  across tests (or across test runs) would leak the one-barcode-per-day rule
 *  between cases. */
function freshPlayers() {
  const run = Date.now().toString(36);
  const a = `player_${run}_${(playerCounter += 1)}`;
  const b = `player_${run}_${(playerCounter += 1)}`;
  return {
    a,
    b,
    headersA: { "content-type": "application/json", "x-player-id": a },
    headersB: { "content-type": "application/json", "x-player-id": b }
  };
}

function offProduct(name: string): OFFProduct {
  return {
    status: 1,
    product: {
      product_name_en: name,
      nutriments: { proteins_100g: 8, fiber_100g: 3, sugars_100g: 5, "energy-kcal_100g": 120 },
      vitamins_tags: ["en:vitamin-c"]
    }
  };
}

const catalog: Record<string, OFFProduct | null> = {
  [NUTELLA]: offProduct("Nutella"),
  [COKE]: offProduct("Coca Cola"),
  [MISSING]: null
};

type Call = (method: string, path: string, headers: Record<string, string>, body?: unknown) => Promise<Response>;

/** Response.json() is unknown under Node types; tests read fixed shapes. */
async function json<T>(res: Response): Promise<T> {
  return (await res.json()) as T;
}

interface ScanResponseBody {
  result: {
    barcode: string;
    foodName: string;
    summonedCharacter?: { id: string; name: string };
    duplicate: boolean;
  };
}

interface CollectionResponseBody {
  characters: { id: string; name: string }[];
}

/** Boots a fresh scan router (isolated state) on an ephemeral port. */
async function withScanApp(
  run: (call: Call, players: ReturnType<typeof freshPlayers>) => Promise<void>
): Promise<void> {
  const players = freshPlayers();
  const app = express();
  app.use(express.json());
  app.use("/scan", createScanRouter(async (barcode) => catalog[barcode] ?? null));

  const server = app.listen(0);
  await new Promise<void>((resolve) => server.once("listening", resolve));
  const port = (server.address() as { port: number }).port;
  const call: Call = (method, path, headers, body) =>
    fetch(`http://127.0.0.1:${port}${path}`, {
      method,
      headers,
      body: body === undefined ? undefined : JSON.stringify(body)
    });

  try {
    await run(call, players);
  } finally {
    await new Promise<void>((resolve) => server.close(() => resolve()));
  }
}

describe("scan -> character -> collection pipeline", () => {
  it("mints a character from a scan and returns it in the collection", async () => {
    await withScanApp(async (call, { a, headersA }) => {
      const post = await call("POST", "/scan", headersA, { barcode: NUTELLA });
      expect(post.status).toBe(200);
      const postBody = await json<ScanResponseBody>(post);
      expect(postBody.result.foodName).toBe("Nutella");
      expect(postBody.result.summonedCharacter!.id).toBe(`scan-${NUTELLA}`);
      expect(postBody.result.duplicate).toBe(false);

      const get = await call("GET", `/scan/collection/${a}`, { "x-player-id": a });
      expect(get.status).toBe(200);
      const getBody = await json<CollectionResponseBody>(get);
      expect(getBody.characters).toHaveLength(1);
      expect(getBody.characters[0]).toMatchObject({ id: `scan-${NUTELLA}`, name: "Nutella" });
    });
  });

  it("applies the one-barcode-per-day rule: same barcode does not mint twice", async () => {
    await withScanApp(async (call, { a, headersA }) => {
      const first = await call("POST", "/scan", headersA, { barcode: COKE });
      expect((await json<ScanResponseBody>(first)).result.duplicate).toBe(false);

      const second = await call("POST", "/scan", headersA, { barcode: COKE });
      expect(second.status).toBe(200);
      const body = await json<ScanResponseBody>(second);
      expect(body.result.duplicate).toBe(true);
      expect(body.result.summonedCharacter).toBeUndefined();

      const get = await call("GET", `/scan/collection/${a}`, { "x-player-id": a });
      const characters = (await json<CollectionResponseBody>(get)).characters;
      expect(characters.filter((c) => c.id === `scan-${COKE}`)).toHaveLength(1);
    });
  });

  it("scopes collections per player: one player never sees another's scans", async () => {
    await withScanApp(async (call, { a, b, headersA, headersB }) => {
      await call("POST", "/scan", headersA, { barcode: NUTELLA });
      await call("POST", "/scan", headersB, { barcode: COKE });

      const collectionA = await json<CollectionResponseBody>(
        await call("GET", `/scan/collection/${a}`, { "x-player-id": a })
      );
      const collectionB = await json<CollectionResponseBody>(
        await call("GET", `/scan/collection/${b}`, { "x-player-id": b })
      );

      const idsA = collectionA.characters.map((c) => c.id);
      const idsB = collectionB.characters.map((c) => c.id);
      expect(idsA).toContain(`scan-${NUTELLA}`);
      expect(idsA).not.toContain(`scan-${COKE}`);
      expect(idsB).toContain(`scan-${COKE}`);
      expect(idsB).not.toContain(`scan-${NUTELLA}`);
    });
  });

  it("rejects a :playerId that does not match the X-Player-Id header (403)", async () => {
    await withScanApp(async (call, { a, b }) => {
      const res = await call("GET", `/scan/collection/${a}`, { "x-player-id": b });
      expect(res.status).toBe(403);
      expect((await json<{ error: { code: string } }>(res)).error.code).toBe("PLAYER_ID_MISMATCH");
    });
  });

  it("rejects malformed barcodes and unknown products", async () => {
    await withScanApp(async (call, { headersA }) => {
      const badBarcode = await call("POST", "/scan", headersA, { barcode: "abc" });
      expect(badBarcode.status).toBe(400);

      const unknown = await call("POST", "/scan", headersA, { barcode: MISSING });
      expect(unknown.status).toBe(404);
    });
  });

  it("rejects requests with no X-Player-Id header", async () => {
    await withScanApp(async (call) => {
      const res = await call("POST", "/scan", { "content-type": "application/json" }, { barcode: NUTELLA });
      expect(res.status).toBe(400);
      expect((await json<{ error: { code: string } }>(res)).error.code).toBe("PLAYER_ID_REQUIRED");
    });
  });
});
