import { describe, it, expect } from "vitest";
import express from "express";
import { createScanRouter, OFFProduct } from "./scan";
import { db } from "../db";
import { ROSTER } from "../data/roster";
import { RARITY_BANDS } from "../game/rarityBands";

// ============================================================================
// Scan -> monster -> collection pipeline (spec §1).
//
// Covers the round-trip the app depends on: POST /scan mints a ★1 catalog
// monster on the FIRST scan of a barcode, never again afterwards (once per
// user, ever — not per day), every scan still logs a meal, and every mint
// leaves its anti-cheat record (barcode + nutrition snapshot + source +
// timestamp) in scan_mint. Open Food Facts is stubbed so the suite is
// hermetic; each test boots its own router with fresh player ids so neither
// in-memory nor persisted state leaks between cases.
// ============================================================================

const NUTELLA = "3017620422003";
const COKE = "5449000000996";
const MISSING = "0000000000000";
const IMPOSSIBLE = "9999999999999";
// A product whose OFF entry carries its per-100g numbers as strings.
const STRINGY = "4000417025005";

let playerCounter = 0;

/** Fresh player pair per test — scan state persists in SQLite, so reusing ids
 *  across tests (or across test runs) would leak the once-per-user rule
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

function offProduct(
  name: string,
  nutriments?: Record<string, number | string>,
  brands?: string
): OFFProduct {
  return {
    status: 1,
    product: {
      product_name_en: name,
      ...(brands ? { brands } : {}),
      nutriments: {
        proteins_100g: 8,
        carbohydrates_100g: 10,
        fat_100g: 4,
        fiber_100g: 3,
        sugars_100g: 5,
        "saturated-fat_100g": 1.5,
        sodium_100g: 0.04,
        "energy-kcal_100g": 120,
        ...nutriments
      }
    }
  };
}

const catalog: Record<string, OFFProduct | null> = {
  [NUTELLA]: offProduct("Nutella", undefined, "Ferrero"),
  [COKE]: offProduct("Coca Cola"),
  [MISSING]: null,
  // Physically impossible: 200g of protein per 100g of food.
  [IMPOSSIBLE]: offProduct("Lie Powder", { proteins_100g: 200 }),
  // Community-entered OFF rows arrive with numeric strings often enough that
  // the feed has to read them; an empty string is "unknown", not zero. The
  // macros are chosen so the Atwater cross-check in checkPlausibility passes.
  [STRINGY]: offProduct("Hazelnut Spread", {
    "energy-kcal_100g": "539",
    proteins_100g: "6.3",
    carbohydrates_100g: "57.5",
    fat_100g: "30.9",
    sugars_100g: "56.3",
    fiber_100g: "",
    sodium_100g: "0.0428",
    "saturated-fat_100g": "10.6"
  })
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
    brands?: string;
    nutritionScore?: number;
    summonedCharacter?: {
      id: string;
      name: string;
      rarity: string;
      baseHealth: number;
      baseAttack: number;
      baseMana?: number;
    };
    mint?: { dropId: string; netWorth: number; stars: number };
    nutrition?: {
      calories?: number;
      proteinG?: number;
      fiberG?: number;
      sodiumMg?: number;
      satFatG?: number;
    };
    mealId: string;
    duplicate: boolean;
  };
}

interface CollectionResponseBody {
  characters: { id: string; name: string }[];
}

interface MealsBody {
  date: string;
  meals: { mealId: string; source: string; name: string; calories: number | null }[];
  totals: { calories: number; proteinG: number; carbsG: number; fatG: number };
}

const ROSTER_IDS = new Set(ROSTER.map((c) => c.id));

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

describe("scan -> monster -> collection pipeline", () => {
  it("mints a ★1 catalog monster on the first scan and logs the meal", async () => {
    await withScanApp(async (call, { a, headersA }) => {
      const post = await call("POST", "/scan", headersA, { barcode: NUTELLA });
      expect(post.status).toBe(200);
      const { result } = await json<ScanResponseBody>(post);

      expect(result.foodName).toBe("Nutella");
      expect(result.brands).toBe("Ferrero");
      expect(result.duplicate).toBe(false);
      expect(result.nutritionScore).toBeGreaterThanOrEqual(0);
      expect(result.nutritionScore).toBeLessThanOrEqual(100);

      // The mint is a catalog design at ★1 with a real combat base.
      const summoned = result.summonedCharacter!;
      expect(ROSTER_IDS.has(summoned.id)).toBe(true);
      expect(summoned.baseHealth).toBeGreaterThan(0);
      expect(summoned.baseAttack).toBeGreaterThan(0);
      expect(result.mint!.stars).toBe(1);
      const band = RARITY_BANDS[summoned.rarity as keyof typeof RARITY_BANDS];
      expect(result.mint!.netWorth).toBeGreaterThanOrEqual(band.min);
      expect(result.mint!.netWorth).toBeLessThanOrEqual(band.max);

      // Anti-cheat: the mint record holds barcode + exact snapshot + source.
      const mint = db
        .prepare(`SELECT * FROM scan_mint WHERE player_id = ? AND barcode = ?`)
        .get(a, NUTELLA) as { character_id: string; nutrition: string; source: string; created_at: string };
      expect(mint.character_id).toBe(summoned.id);
      expect(mint.source).toBe("openfoodfacts");
      expect(JSON.parse(mint.nutrition).proteinG).toBe(8);
      expect(mint.created_at).toBeTruthy();

      // The scan logged a meal.
      const meals = await json<MealsBody>(await call("GET", "/scan/meals", { "x-player-id": a }));
      expect(meals.meals).toHaveLength(1);
      expect(meals.meals[0].source).toBe("barcode");
      expect(meals.meals[0].mealId).toBe(result.mealId);

      const get = await call("GET", `/scan/collection/${a}`, { "x-player-id": a });
      const characters = (await json<CollectionResponseBody>(get)).characters;
      expect(characters).toHaveLength(1);
      expect(characters[0].id).toBe(summoned.id);
    });
  });

  it("mints once per user ever — re-scans log nutrition but never re-mint", async () => {
    await withScanApp(async (call, { a, headersA }) => {
      const first = await json<ScanResponseBody>(await call("POST", "/scan", headersA, { barcode: COKE }));
      expect(first.result.duplicate).toBe(false);
      expect(first.result.summonedCharacter).toBeDefined();

      const second = await json<ScanResponseBody>(await call("POST", "/scan", headersA, { barcode: COKE }));
      expect(second.result.duplicate).toBe(true);
      expect(second.result.summonedCharacter).toBeUndefined();
      expect(second.result.mint).toBeUndefined();

      // Both scans logged; only one monster exists.
      const meals = await json<MealsBody>(await call("GET", "/scan/meals", { "x-player-id": a }));
      expect(meals.meals).toHaveLength(2);

      const mints = db
        .prepare(`SELECT COUNT(*) AS n FROM scan_mint WHERE player_id = ? AND barcode = ?`)
        .get(a, COKE) as { n: number };
      expect(mints.n).toBe(1);

      const characters = (await json<CollectionResponseBody>(
        await call("GET", `/scan/collection/${a}`, { "x-player-id": a })
      )).characters;
      expect(characters).toHaveLength(1);
    });
  });

  it("lets different players mint from the same barcode independently", async () => {
    await withScanApp(async (call, { headersA, headersB }) => {
      const a = await json<ScanResponseBody>(await call("POST", "/scan", headersA, { barcode: NUTELLA }));
      const b = await json<ScanResponseBody>(await call("POST", "/scan", headersB, { barcode: NUTELLA }));
      expect(a.result.duplicate).toBe(false);
      expect(b.result.duplicate).toBe(false);
      expect(a.result.mint!.dropId).not.toBe(b.result.mint!.dropId);
    });
  });

  it("rejects impossible nutrition before anything mints", async () => {
    await withScanApp(async (call, { a, headersA }) => {
      const res = await call("POST", "/scan", headersA, { barcode: IMPOSSIBLE });
      expect(res.status).toBe(422);
      expect((await json<{ error: { code: string } }>(res)).error.code).toBe("IMPLAUSIBLE_NUTRITION");

      // Nothing minted, nothing logged.
      const mints = db
        .prepare(`SELECT COUNT(*) AS n FROM scan_mint WHERE player_id = ?`)
        .get(a) as { n: number };
      expect(mints.n).toBe(0);
      const meals = await json<MealsBody>(await call("GET", "/scan/meals", { "x-player-id": a }));
      expect(meals.meals).toHaveLength(0);
    });
  });

  it("reads numeric-string OFF nutriments so calories survive the feed", async () => {
    await withScanApp(async (call, { a, headersA }) => {
      const res = await call("POST", "/scan", headersA, { barcode: STRINGY });
      expect(res.status).toBe(200);
      const { result } = await json<ScanResponseBody>(res);

      expect(result.nutrition?.calories).toBe(539);
      expect(result.nutrition?.proteinG).toBe(6.3);
      expect(result.nutrition?.satFatG).toBe(10.6);
      expect(result.nutrition?.sodiumMg).toBeCloseTo(42.8, 6);
      // "" is unknown, not 0.
      expect(result.nutrition?.fiberG).toBeUndefined();
      expect(result.brands).toBeUndefined();

      // The anti-cheat snapshot stores the coerced numbers, not the strings.
      const row = db
        .prepare(`SELECT nutrition FROM scan_mint WHERE player_id = ? AND barcode = ?`)
        .get(a, STRINGY) as { nutrition: string };
      const snapshot = JSON.parse(row.nutrition) as { calories?: number; fiberG?: number };
      expect(snapshot.calories).toBe(539);
      expect(snapshot.fiberG).toBeUndefined();

      // And the meal log got real calories, so the dashboard totals move.
      const meals = await json<MealsBody>(await call("GET", "/scan/meals", { "x-player-id": a }));
      expect(meals.totals.calories).toBe(539);
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

      // Each player's collection is exactly their own mint (the minted design
      // is a random catalog pick, so ids may coincide — counts are the point).
      expect(collectionA.characters).toHaveLength(1);
      expect(collectionB.characters).toHaveLength(1);
      const mintsA = db.prepare(`SELECT COUNT(*) AS n FROM scan_mint WHERE player_id = ?`).get(a) as { n: number };
      const mintsB = db.prepare(`SELECT COUNT(*) AS n FROM scan_mint WHERE player_id = ?`).get(b) as { n: number };
      expect(mintsA.n).toBe(1);
      expect(mintsB.n).toBe(1);
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

describe("manual meal logging", () => {
  it("logs, edits and removes manual entries; today feeds the four dashboard macros", async () => {
    await withScanApp(async (call, { a, headersA }) => {
      const created = await call("POST", "/scan/meals", headersA, {
        name: "Greek yoghurt",
        calories: 97,
        proteinG: 9,
        carbsG: 3.6,
        fatG: 5
      });
      expect(created.status).toBe(201);
      const { mealId } = await json<{ mealId: string }>(created);

      const edited = await call("PATCH", `/scan/meals/${mealId}`, headersA, { proteinG: 10 });
      expect(edited.status).toBe(200);

      const today = await json<{ totals: { calories: number; protein: number; carbs: number; fat: number } }>(
        await call("GET", "/scan/meals/today", { "x-player-id": a })
      );
      expect(today.totals).toEqual({ calories: 97, protein: 10, carbs: 3.6, fat: 5 });

      const removed = await call("DELETE", `/scan/meals/${mealId}`, headersA);
      expect(removed.status).toBe(200);
      const after = await json<MealsBody>(await call("GET", "/scan/meals", { "x-player-id": a }));
      expect(after.meals).toHaveLength(0);
    });
  });

  it("never mints anything from a manual meal", async () => {
    await withScanApp(async (call, { a, headersA }) => {
      await call("POST", "/scan/meals", headersA, { name: "x", calories: 100, proteinG: 10, carbsG: 5, fatG: 3 });
      const mints = db.prepare(`SELECT COUNT(*) AS n FROM scan_mint WHERE player_id = ?`).get(a) as { n: number };
      expect(mints.n).toBe(0);
    });
  });
});
