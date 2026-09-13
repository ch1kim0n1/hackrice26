import { describe, it, expect } from "vitest";
import express from "express";
import { createScanRouter } from "./scan";
import { normalizeAnalysis } from "../nutrition/analyze";
import { DishAnalysis, NotFoodError, VisionUnavailableError } from "../nutrition/types";
import { db } from "../db";

// ============================================================================
// Dish photo -> review -> meal log. NEVER a monster.
//
// Covers the two-step contract the app depends on: analyze produces a draft
// and logs nothing, confirm applies the user's corrections server-side and
// writes exactly one meal-log entry. Per spec §1 a photographed dish can
// never mint a character — barcode is the only food path that mints — so
// every confirm test here also proves the collection stays empty. The vision
// call is stubbed so the suite is hermetic.
// ============================================================================

const PLATE = {
  dishName: "Chicken, rice and broccoli",
  colorHex: "#C8A45C",
  nova: 1,
  items: [
    { name: "Grilled chicken breast", portionGrams: 160, calories: 264, proteinG: 49, carbsG: 0, fatG: 6, foodGroup: "protein", micronutrients: ["iron", "potassium"], confidence: 0.86 },
    { name: "White rice", portionGrams: 160, calories: 208, proteinG: 4.3, carbsG: 45, fatG: 0.4, fiberG: 0.6, foodGroup: "grain", micronutrients: ["iron"], confidence: 0.78 },
    { name: "Steamed broccoli", portionGrams: 90, calories: 31, proteinG: 2.6, carbsG: 6, fatG: 0.3, fiberG: 2.4, sugarG: 1.4, foodGroup: "produce", micronutrients: ["vitamin-c", "calcium"], confidence: 0.82 }
  ]
};

let playerCounter = 0;
function freshPlayer() {
  const id = `dish_${Date.now().toString(36)}_${(playerCounter += 1)}`;
  return { id, headers: { "content-type": "application/json", "x-player-id": id } };
}

type Call = (method: string, path: string, headers: Record<string, string>, body?: unknown) => Promise<Response>;

async function json<T>(res: Response): Promise<T> {
  return (await res.json()) as T;
}

interface AnalyzeBody {
  analysis: DishAnalysis;
}
interface ConfirmBody {
  result: {
    source: string;
    foodName: string;
    mealId: string;
    nutrition: { calories: number; portionG: number; microScore: number; dominantFoodGroup: string };
    items: { id: string; name: string; portionG: number }[];
    lowConfidence: boolean;
    implausible: boolean;
    flagged: boolean;
  };
}
interface ErrorBody {
  error: { code: string; message: string };
}

/** Boots a scan router whose vision call is stubbed. */
async function withDishApp(
  run: (call: Call, player: ReturnType<typeof freshPlayer>) => Promise<void>,
  vision: (image: string) => Promise<DishAnalysis> = async () => normalizeAnalysis(PLATE)
): Promise<void> {
  const player = freshPlayer();
  const app = express();
  app.use(express.json({ limit: "8mb" }));
  app.use("/scan", createScanRouter(async () => null, vision));

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
    await run(call, player);
  } finally {
    await new Promise<void>((resolve) => server.close(() => resolve()));
  }
}

// A base64 string that decodes to a jpeg magic header (FFD8FF) + filler.
const IMAGE = "/9j/" + "x".repeat(600);

describe("POST /scan/photo/analyze", () => {
  it("returns an itemised draft breakdown", async () => {
    await withDishApp(async (call, player) => {
      const res = await call("POST", "/scan/photo/analyze", player.headers, { image: IMAGE });
      expect(res.status).toBe(200);
      const { analysis } = await json<AnalyzeBody>(res);
      expect(analysis.items).toHaveLength(3);
      expect(analysis.items[0].name).toBe("Grilled chicken breast");
      expect(analysis.totals.calories).toBe(503);
      expect(analysis.totals.dominantFoodGroup).toBe("protein");
      expect(analysis.analysisId).toBeTruthy();
    });
  });

  it("mints nothing — the collection stays empty until confirm", async () => {
    await withDishApp(async (call, player) => {
      await call("POST", "/scan/photo/analyze", player.headers, { image: IMAGE });
      const collection = await json<{ characters: unknown[] }>(
        await call("GET", `/scan/collection/${player.id}`, { "x-player-id": player.id })
      );
      expect(collection.characters).toHaveLength(0);
    });
  });

  it("rejects a missing or undersized image", async () => {
    await withDishApp(async (call, player) => {
      expect((await call("POST", "/scan/photo/analyze", player.headers, {})).status).toBe(400);
      expect((await call("POST", "/scan/photo/analyze", player.headers, { image: "tiny" })).status).toBe(400);
    });
  });

  it("rejects a payload that isn't a jpeg/png/webp before calling vision", async () => {
    let visionCalls = 0;
    await withDishApp(
      async (call, player) => {
        const res = await call("POST", "/scan/photo/analyze", player.headers, { image: "x".repeat(600) });
        expect(res.status).toBe(400);
        expect((await json<ErrorBody>(res)).error.code).toBe("NOT_AN_IMAGE");
        expect(visionCalls).toBe(0);
      },
      async () => {
        visionCalls += 1;
        return normalizeAnalysis(PLATE);
      }
    );
  });

  it("returns 422 when the photo isn't food", async () => {
    await withDishApp(
      async (call, player) => {
        const res = await call("POST", "/scan/photo/analyze", player.headers, { image: IMAGE });
        expect(res.status).toBe(422);
        expect((await json<ErrorBody>(res)).error.code).toBe("NOT_FOOD");
      },
      async () => {
        throw new NotFoodError();
      }
    );
  });

  it("returns 503, not 'not food', when the analyser itself is unavailable", async () => {
    // A dead/unpaid provider must never be reported to someone holding up
    // their dinner as "there's no food in that photo".
    await withDishApp(
      async (call, player) => {
        const res = await call("POST", "/scan/photo/analyze", player.headers, { image: IMAGE });
        expect(res.status).toBe(503);
        const body = await json<ErrorBody>(res);
        expect(body.error.code).toBe("VISION_UNAVAILABLE");
        expect(body.error.message).toMatch(/credentials or quota/);
      },
      async () => {
        throw new VisionUnavailableError(
          "Photo analysis is unavailable: the analyser rejected our credentials or quota (set VISION_API_KEY / VISION_API_URL)",
          402
        );
      }
    );
  });

  it("requires a player id", async () => {
    await withDishApp(async (call) => {
      const res = await call("POST", "/scan/photo/analyze", { "content-type": "application/json" }, { image: IMAGE });
      expect(res.status).toBe(400);
      expect((await json<ErrorBody>(res)).error.code).toBe("PLAYER_ID_REQUIRED");
    });
  });
});

describe("POST /scan/photo/confirm", () => {
  it("logs the confirmed plate as a meal and never mints a character", async () => {
    await withDishApp(async (call, player) => {
      const { analysis } = await json<AnalyzeBody>(
        await call("POST", "/scan/photo/analyze", player.headers, { image: IMAGE })
      );

      const res = await call("POST", "/scan/photo/confirm", player.headers, { analysisId: analysis.analysisId });
      expect(res.status).toBe(200);
      const { result } = await json<ConfirmBody>(res);

      expect(result.source).toBe("photo");
      expect(result.foodName).toBe("Chicken, rice and broccoli");
      expect(result.mealId).toBeTruthy();
      expect(result.nutrition.calories).toBe(503);
      expect(result.nutrition.dominantFoodGroup).toBe("protein");
      expect(result.lowConfidence).toBe(false);
      expect(result.implausible).toBe(false);
      expect(result.flagged).toBe(false);
      // No character fields exist on a photo result at all.
      expect("summonedCharacter" in result).toBe(false);

      // The collection is still empty — the photo path cannot mint.
      const collection = await json<{ characters: { id: string }[] }>(
        await call("GET", `/scan/collection/${player.id}`, { "x-player-id": player.id })
      );
      expect(collection.characters).toHaveLength(0);

      // And no scan_mint row exists for the player.
      const mints = db
        .prepare(`SELECT COUNT(*) AS n FROM scan_mint WHERE player_id = ?`)
        .get(player.id) as { n: number };
      expect(mints.n).toBe(0);

      // The meal is in the log with the confirmed totals.
      const meals = await json<{ meals: { mealId: string; source: string; calories: number }[] }>(
        await call("GET", "/scan/meals", { "x-player-id": player.id })
      );
      expect(meals.meals).toHaveLength(1);
      expect(meals.meals[0].source).toBe("photo");
      expect(meals.meals[0].mealId).toBe(result.mealId);
      expect(meals.meals[0].calories).toBe(503);
    });
  });

  it("applies the user's portion correction before scoring", async () => {
    await withDishApp(async (call, player) => {
      const { analysis } = await json<AnalyzeBody>(
        await call("POST", "/scan/photo/analyze", player.headers, { image: IMAGE })
      );
      const res = await call("POST", "/scan/photo/confirm", player.headers, {
        analysisId: analysis.analysisId,
        edits: [{ id: "i0", portionG: 80 }] // half the chicken
      });
      const { result } = await json<ConfirmBody>(res);
      expect(result.nutrition.calories).toBe(503 - 132);
      expect(result.items.find((i) => i.id === "i0")!.portionG).toBe(80);
    });
  });

  it("drops an item the user removed", async () => {
    await withDishApp(async (call, player) => {
      const { analysis } = await json<AnalyzeBody>(
        await call("POST", "/scan/photo/analyze", player.headers, { image: IMAGE })
      );
      const { result } = await json<ConfirmBody>(
        await call("POST", "/scan/photo/confirm", player.headers, {
          analysisId: analysis.analysisId,
          edits: [{ id: "i0", removed: true }]
        })
      );
      expect(result.items.map((i) => i.id)).toEqual(["i1", "i2"]);
      // Without the chicken the plate is grain-dominant.
      expect(result.nutrition.dominantFoodGroup).toBe("grain");
    });
  });

  it("ignores nutrition smuggled into the edits payload", async () => {
    await withDishApp(async (call, player) => {
      const { analysis } = await json<AnalyzeBody>(
        await call("POST", "/scan/photo/analyze", player.headers, { image: IMAGE })
      );
      const { result } = await json<ConfirmBody>(
        await call("POST", "/scan/photo/confirm", player.headers, {
          analysisId: analysis.analysisId,
          edits: [{ id: "i0", proteinG: 100000, calories: 100000 }]
        })
      );
      // Totals are unchanged: only rename/re-portion/remove are honoured.
      expect(result.nutrition.calories).toBe(503);
    });
  });

  it("refuses to log twice from the same analysis", async () => {
    await withDishApp(async (call, player) => {
      const { analysis } = await json<AnalyzeBody>(
        await call("POST", "/scan/photo/analyze", player.headers, { image: IMAGE })
      );
      const first = await call("POST", "/scan/photo/confirm", player.headers, { analysisId: analysis.analysisId });
      expect(first.status).toBe(200);

      const second = await call("POST", "/scan/photo/confirm", player.headers, { analysisId: analysis.analysisId });
      expect(second.status).toBe(409);
      expect((await json<ErrorBody>(second)).error.code).toBe("ANALYSIS_ALREADY_USED");
    });
  });

  it("rejects an unknown analysis id", async () => {
    await withDishApp(async (call, player) => {
      const res = await call("POST", "/scan/photo/confirm", player.headers, { analysisId: "made-up" });
      expect(res.status).toBe(404);
      expect((await json<ErrorBody>(res)).error.code).toBe("ANALYSIS_NOT_FOUND");
    });
  });

  it("will not let one player confirm another player's analysis", async () => {
    await withDishApp(async (call, player) => {
      const { analysis } = await json<AnalyzeBody>(
        await call("POST", "/scan/photo/analyze", player.headers, { image: IMAGE })
      );
      const intruder = freshPlayer();
      const res = await call("POST", "/scan/photo/confirm", intruder.headers, { analysisId: analysis.analysisId });
      expect(res.status).toBe(404);
    });
  });

  it("rejects edits that empty the plate", async () => {
    await withDishApp(async (call, player) => {
      const { analysis } = await json<AnalyzeBody>(
        await call("POST", "/scan/photo/analyze", player.headers, { image: IMAGE })
      );
      const res = await call("POST", "/scan/photo/confirm", player.headers, {
        analysisId: analysis.analysisId,
        edits: [{ id: "i0", removed: true }, { id: "i1", removed: true }, { id: "i2", removed: true }]
      });
      expect(res.status).toBe(400);
      expect((await json<ErrorBody>(res)).error.code).toBe("EMPTY_PLATE");
    });
  });

  it("requires an analysisId", async () => {
    await withDishApp(async (call, player) => {
      const res = await call("POST", "/scan/photo/confirm", player.headers, {});
      expect(res.status).toBe(400);
      expect((await json<ErrorBody>(res)).error.code).toBe("ANALYSIS_ID_REQUIRED");
    });
  });
});
