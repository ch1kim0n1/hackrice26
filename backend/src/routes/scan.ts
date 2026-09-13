import { Router, Response } from "express";
import type { ScanResult, Character, StatType, Rarity } from "../types";
import { PlayerRequest, requirePlayerId } from "../middleware/player";
import { rateLimitByPlayer } from "../middleware/security";
import { db } from "../db";
import { hasDatabaseUrl } from "../db/pg";
import { analyzeDishPhoto, imageKind } from "../nutrition/analyze";
import { applyEdits, parseEdits } from "../nutrition/edits";
import { dishRarity, dishToProduct } from "../nutrition/character";
import { DishAnalysis, NotFoodError, VisionUnavailableError } from "../nutrition/types";
import { awardXP, awardRankPoints } from "./user";
import { RP_PER_SCAN } from "../game/rankPoints";
import { enqueueMirror } from "../services/mirrorQueue";
import { mintCollectionDrop } from "../services/lootboxState";

interface OFFNutriments {
  "energy-kcal_100g"?: number;
  proteins_100g?: number;
  "fiber_100g"?: number;
  sugars_100g?: number;
  [key: string]: number | string | undefined;
}

export interface OFFProduct {
  status?: number;
  product?: {
    product_name?: string;
    product_name_en?: string;
    brands?: string;
    nutriments?: OFFNutriments;
    nova_group?: number;
    labels_tags?: string[];
    vitamins_tags?: string[];
    minerals_tags?: string[];
  };
}

export function createScanRouter(
  fetchProduct?: (barcode: string) => Promise<OFFProduct | null>,
  analyzeDish?: (imageBase64: string) => Promise<DishAnalysis>
): Router {
const scanRouter = Router();
scanRouter.use(requirePlayerId);
const fetchOFFOrDefault = fetchProduct ?? fetchOFF;
// Injectable so the dish-photo tests never make a vision call.
const analyzeDishOrDefault = analyzeDish ?? ((image: string) => analyzeDishPhoto(image));

// Day log + collection are persisted per player in SQLite (issue #23), so
// the one-barcode rule and minted characters survive restarts. The
// one-barcode rule is per-day: a player can re-scan the same barcode on a
// new calendar day (UTC) and mint a fresh character.
const seenBarcode = (playerId: string, barcode: string): boolean =>
  !!db
    .prepare(`SELECT 1 FROM scan_seen WHERE player_id = ? AND barcode = ? AND date(seen_at) = date('now')`)
    .get(playerId, barcode);
const markSeen = (playerId: string, barcode: string) =>
  db.prepare(`INSERT INTO scan_seen (player_id, barcode, seen_at) VALUES (?, ?, datetime('now'))
              ON CONFLICT(player_id, barcode) DO UPDATE SET seen_at = datetime('now')`).run(playerId, barcode);
const loadCharacters = (playerId: string): Character[] =>
  (db.prepare(`SELECT payload FROM scan_character WHERE player_id = ?`).all(playerId) as any[])
    .map((r) => JSON.parse(r.payload) as Character);
const saveCharacter = (playerId: string, character: Character) =>
  db.prepare(`INSERT OR IGNORE INTO scan_character (player_id, char_id, payload) VALUES (?, ?, ?)`)
    .run(playerId, character.id, JSON.stringify(character));

const clamp = (v: number, lo: number, hi: number) => Math.min(hi, Math.max(lo, v));

// Mirrors BattleKit CharacterFactory (ios/Sources/NutriQuest/Scanning).
//
// `microScoreOverride` exists for the dish-photo path: an analysed plate knows
// exactly which of the six tracked micronutrients it carries (0..1), which is
// a far better signal than Open Food Facts' "are there any vitamin tags?"
// heuristic. Barcode scans pass nothing and keep their original behaviour.
function deriveStats(n: OFFProduct["product"], microScoreOverride?: number) {
  const nutriments = (n?.nutriments ?? {}) as OFFNutriments;
  const protein = Number(nutriments.proteins_100g ?? 0);
  const fiber = Number(nutriments["fiber_100g"] ?? 0);
  const sugar = Number(nutriments.sugars_100g ?? 0);

  const microScore =
    microScoreOverride ??
    (((n?.vitamins_tags?.length ?? 0) > 0 ? 0.5 : 0) +
      ((n?.minerals_tags?.length ?? 0) > 0 ? 0.5 : 0) || 0.3);

  return {
    power: clamp(20 + protein * 4, 10, 100),
    guard: clamp(20 + fiber * 5, 10, 100),
    vitality: clamp(20 + microScore * 45, 10, 100),
    tempo: clamp(20 + (protein / Math.max(sugar, 1)) * 10 + (50 - sugar) * 0.6, 10, 100)
  };
}

function rarityFor(n: OFFProduct["product"]): Rarity {
  if (n?.nova_group === 4) return "common";
  const labels = (n?.labels_tags?.length ?? 0) + (n?.vitamins_tags?.length ?? 0);
  if (labels >= 8) return "epic";
  if (labels >= 4) return "rare";
  return "common";
}

function elementFor(stats: { power: number; guard: number; vitality: number; tempo: number }): StatType {
  const pairs: [StatType, number][] = [
    ["protein", stats.power],
    ["fiber", stats.guard],
    ["vitamin", stats.vitality],
    ["hydration", stats.tempo]
  ];
  return pairs.sort((a, b) => b[1] - a[1])[0][0];
}

async function fetchOFF(barcode: string): Promise<OFFProduct | null> {
  try {
    const res = await fetch(
      `https://world.openfoodfacts.org/api/v2/product/${encodeURIComponent(barcode)}.json`,
      { headers: { "User-Agent": "NutriQuest - iOS - v1" } }
    );
    if (!res.ok) return null;
    return (await res.json()) as OFFProduct;
  } catch {
    return null;
  }
}

/** :playerId in the URL must match the caller's X-Player-Id, otherwise one
 *  player could read another player's scanned collection just by naming their
 *  id in the URL. The header is what's actually trusted. */
function requireOwnId(req: PlayerRequest, res: Response): boolean {
  if (req.params.playerId !== req.playerId) {
    res.status(403).json({
      error: {
        code: "PLAYER_ID_MISMATCH",
        message: "The :playerId in the URL must match your X-Player-Id header."
      }
    });
    return false;
  }
  return true;
}

// POST /scan { barcode } -- real Open Food Facts lookup, derives battle stats
// server-side (mirrors BattleKit CharacterFactory), mints a character, applies
// the one-barcode-per-day rule. Player identity comes from the X-Player-Id
// header (requirePlayerId middleware), NOT the request body -- a body field
// could let any client write into another player's collection.
// Rate-limited to avoid OFF API abuse and barcode spam.
scanRouter.post("/", rateLimitByPlayer({ windowMs: 60_000, max: 10, keyPrefix: "scan", message: "Too many scans. Try again later." }), async (req: PlayerRequest, res) => {
  const { barcode } = req.body as { barcode?: string };

  if (typeof barcode !== "string" || !/^\d{6,20}$/.test(barcode)) {
    return res.status(400).json({ error: "barcode must be a string of 6-20 digits (EAN/UPC)." });
  }

  const off = await fetchOFFOrDefault(barcode);
  if (!off || off.status !== 1 || !off.product) {
    return res.status(404).json({ error: "product not found in Open Food Facts" });
  }

  const stats = deriveStats(off.product);
  const name = off.product.product_name_en ?? off.product.product_name ?? "Unknown food";

  // One barcode per day per player. Keyed by the trusted header, not body.
  const key = req.playerId!;
  const isNew = !seenBarcode(key, barcode);
  markSeen(key, barcode);

  const character: Character = {
    id: `scan-${barcode}`,
    name,
    colorHex: "#5FCB82",
    rarity: rarityFor(off.product),
    statType: elementFor(stats),
    isLocked: false
  };

  if (isNew) {
    saveCharacter(key, character);
    // Mint the real owned drop alongside the collection entry — a scanned
    // monster is sellable and wagerable like any crate pull.
    mintCollectionDrop(key, character, "scan");
    awardXP(key, 30, "scan");
    // Consistency ladder (#83): a unique scan is a logged meal.
    awardRankPoints(key, RP_PER_SCAN, "scan");
  }

  const result: ScanResult & { stats: typeof stats; duplicate: boolean } = {
    barcode,
    foodName: name,
    statType: character.statType,
    summonedCharacter: isNew ? character : undefined,
    stats,
    duplicate: !isNew
  };

  // Best-effort gameplay-event mirror into the TigerData hypertable.
  if (hasDatabaseUrl()) {
    // One scan per barcode per day, so barcode+day is the event's own identity
    // and a retried request cannot double-count the scan.
    const day = new Date().toISOString().slice(0, 10);
    enqueueMirror("gameplay_event", `scan:${key}:${barcode}:${day}`, {
      playerId: key,
      type: "scan",
      detail: { barcode, duplicate: !isNew },
    });
    if (isNew) {
      enqueueMirror("gameplay_event", `collect:${key}:${character.id}:${day}`, {
        playerId: key,
        type: "collect",
        detail: { characterId: character.id, rarity: character.rarity },
      });
      enqueueMirror("acquisition_event", `${key}:${character.id}:${day}`, {
        playerId: key,
        sourceKind: "scan",
        rarity: character.rarity,
        netWorth: 0,   // a scan summon carries no wagered worth
        starLevel: 1,
        characterRef: `${character.id}:${day}`,
      });
    }
  }

  res.json({ result });
});

// ===== Dish photo scan (no barcode) =====
//
// Two steps, deliberately. Analysis has to stand on its own before its numbers
// are trusted enough to mint a character from:
//
//   POST /scan/photo/analyze  { image }              -> a draft breakdown
//   POST /scan/photo/confirm  { analysisId, edits }  -> mints the character
//
// The draft lists every food the model found on the plate with its own portion
// and nutrients. The user reviews it, fixes what's wrong, and only then does
// the confirmed total flow into the same stat/element pipeline barcode scans
// use. The draft is held server-side so the confirm step can only rescale,
// rename or drop items the server itself analysed — a client can never hand us
// nutrition numbers directly (see nutrition/edits.ts).
//
// The body limit is raised for /scan/photo* only (see index.ts).

const saveAnalysis = (playerId: string, analysis: DishAnalysis) => {
  // Drafts that were never confirmed are dead weight — prune them alongside
  // each save rather than running a sweeper.
  db.prepare(`DELETE FROM dish_analysis WHERE created_at < datetime('now', '-1 day')`).run();
  db.prepare(`INSERT INTO dish_analysis (analysis_id, player_id, payload) VALUES (?, ?, ?)`)
    .run(analysis.analysisId, playerId, JSON.stringify(analysis));
};

type StoredAnalysis = { analysis: DishAnalysis; consumed: boolean };

const loadAnalysis = (playerId: string, analysisId: string): StoredAnalysis | null => {
  const row = db
    .prepare(`SELECT payload, consumed FROM dish_analysis WHERE analysis_id = ? AND player_id = ?`)
    .get(analysisId, playerId) as { payload: string; consumed: number } | undefined;
  if (!row) return null;
  return { analysis: JSON.parse(row.payload) as DishAnalysis, consumed: row.consumed === 1 };
};

const markAnalysisConsumed = (analysisId: string) =>
  db.prepare(`UPDATE dish_analysis SET consumed = 1 WHERE analysis_id = ?`).run(analysisId);

// Step 1 — analyse. Nothing is minted here; this call only produces the
// breakdown the user is about to review. Rate-limited tighter than barcode
// scans because each call is a vision request.
scanRouter.post(
  "/photo/analyze",
  rateLimitByPlayer({ windowMs: 60_000, max: 5, keyPrefix: "scan:photo", message: "Photo scans are heavy — max 5 per minute." }),
  async (req: PlayerRequest, res) => {
    const { image } = req.body as { image?: string };
    if (typeof image !== "string" || image.length < 500 || image.length > 9_000_000) {
      return res.status(400).json({ error: "image must be a base64 image under ~6MB" });
    }
    // Cheap proof it is actually an image before we pay for a vision call.
    if (!imageKind(image)) {
      return res.status(400).json({ error: { code: "NOT_AN_IMAGE", message: "image must be a base64 jpeg, png or webp" } });
    }

    let analysis: DishAnalysis;
    try {
      analysis = await analyzeDishOrDefault(image);
    } catch (err) {
      // "We couldn't run the analyser" and "there's no food here" are very
      // different messages to show someone holding up their dinner.
      if (err instanceof VisionUnavailableError) {
        return res
          .status(503)
          .json({ error: { code: "VISION_UNAVAILABLE", message: err.message } });
      }
      const message = err instanceof NotFoodError ? err.message : "Could not analyze that photo";
      return res.status(422).json({ error: { code: "NOT_FOOD", message } });
    }

    saveAnalysis(req.playerId!, analysis);
    res.json({ analysis });
  }
);

// Step 2 — confirm. Applies the user's corrections, recomputes every total
// server-side, then mints exactly one character from the confirmed plate.
scanRouter.post(
  "/photo/confirm",
  rateLimitByPlayer({ windowMs: 60_000, max: 20, keyPrefix: "scan:confirm", message: "Too many confirmations. Try again shortly." }),
  (req: PlayerRequest, res) => {
    const { analysisId, edits } = req.body as { analysisId?: string; edits?: unknown };
    if (typeof analysisId !== "string" || analysisId.length === 0) {
      return res.status(400).json({ error: { code: "ANALYSIS_ID_REQUIRED", message: "analysisId is required" } });
    }

    const stored = loadAnalysis(req.playerId!, analysisId);
    if (!stored) {
      return res.status(404).json({ error: { code: "ANALYSIS_NOT_FOUND", message: "No such analysis for this player" } });
    }
    // One analysis mints one character — a confirm can't be replayed for more.
    if (stored.consumed) {
      return res.status(409).json({ error: { code: "ANALYSIS_ALREADY_USED", message: "That plate has already been logged" } });
    }

    let confirmed: DishAnalysis;
    try {
      confirmed = applyEdits(stored.analysis, parseEdits(edits));
    } catch (err) {
      const message = err instanceof NotFoodError ? err.message : "Those edits left nothing to log";
      return res.status(400).json({ error: { code: "EMPTY_PLATE", message } });
    }

    // Same stat math as a barcode scan — the plate is just expressed as an
    // OFF-shaped product first. The micro score is the real measured one.
    const stats = deriveStats(dishToProduct(confirmed), confirmed.totals.microScore);

    const character: Character = {
      id: `dish-${confirmed.analysisId}`,
      name: confirmed.dishName,
      colorHex: confirmed.colorHex,
      rarity: dishRarity(confirmed),
      statType: elementFor(stats),
      isLocked: false,
      // Drives the procedural artwork so a salad and a steak don't render as
      // the same silhouette (ChibiCharacterView).
      foodGroup: confirmed.totals.dominantFoodGroup
    };

    saveCharacter(req.playerId!, character);
    mintCollectionDrop(req.playerId!, character, "dish");
    markAnalysisConsumed(confirmed.analysisId);
    // XP lands here rather than on analyze: confirming is the moment a plate
    // actually becomes a character, so an abandoned review earns nothing.
    awardXP(req.playerId!, 15, "meal-photo");
    awardRankPoints(req.playerId!, RP_PER_SCAN, "meal-photo");

    // Best-effort mirror: confirmed intake -> nutrition_deltas hypertable, plus a
    // collect gameplay event. SQLite above stays authoritative.
    if (hasDatabaseUrl()) {
      const t = confirmed.totals;
      enqueueMirror("meal_intake", `${analysisId}:intake`, {
        playerId: req.playerId!,
        meal: {
          calories: t.calories, proteinG: t.proteinG, carbsG: t.carbsG, fatG: t.fatG,
          sodiumMg: t.sodiumMg, foodGroup: t.dominantFoodGroup, microScore: t.microScore,
        },
      });
      enqueueMirror("gameplay_event", `collect:${character.id}:${analysisId}`, {
        playerId: req.playerId!,
        type: "collect",
        detail: { source: "photo", characterId: character.id },
      });
      enqueueMirror("acquisition_event", character.id, {
        playerId: req.playerId!,
        sourceKind: "dish",
        rarity: character.rarity,
        netWorth: 0,   // a dish summon has no wagered worth of its own
        starLevel: 1,
        characterRef: character.id,
      });
    }

    res.json({
      result: {
        barcode: null,
        source: "photo",
        foodName: confirmed.dishName,
        statType: character.statType,
        summonedCharacter: character,
        stats,
        items: confirmed.items,
        nutrition: confirmed.totals,
        duplicate: false
      }
    });
  }
);

// GET /scan/collection/:playerId -- characters minted from scans. :playerId
// must match the caller's X-Player-Id; otherwise anyone could read anyone's
// collection by guessing the id.
scanRouter.get("/collection/:playerId", (req: PlayerRequest, res) => {
  if (!requireOwnId(req, res)) return;
  res.json({ characters: loadCharacters(req.playerId!) });
});

  return scanRouter;
}

/** Default router: real Open Food Facts lookups, module-level state. */
export const scanRouter = createScanRouter();
