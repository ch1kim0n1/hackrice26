// Scan pipeline (spec §1) — the only user food path that mints a monster.
//
//   POST /scan                barcode -> nutrition -> (once ever) a ★1 monster
//   POST /scan/photo/analyze  dish photo -> a draft breakdown, nothing else
//   POST /scan/photo/confirm  reviewed draft -> a meal-log entry, nothing else
//   POST /scan/meals          manual entry -> a meal-log entry
//   GET/PATCH/DELETE /scan/meals*  the intake log + dashboard totals
//
// The spec's hard rules, all enforced here:
//   - Barcode is the ONLY mint path. Photo and manual never create a monster.
//   - A barcode mints once per user, ever (the scan_mint PK enforces it at
//     the data layer — a retried or racing insert fails, not double-mints).
//     Re-scans still log nutrition and count for tasks.
//   - Anti-cheat: every mint persists the barcode, the exact nutrition
//     snapshot used, the source, and the timestamp (scan_mint). Impossible
//     nutrition is rejected before anything mints.
//   - Photo estimates are advisory until the user confirms or edits them;
//     low-confidence and implausible results are flagged, and only confirmed
//     plates are logged.

import { randomBytes, randomUUID } from "crypto";
import { Router, Response } from "express";
import type { ScanResult, ScanNutrition, Character, Rarity } from "../types";
import { PlayerRequest, requirePlayerId } from "../middleware/player";
import { rateLimitByPlayer } from "../middleware/security";
import { db } from "../db";
import { hasDatabaseUrl } from "../db/pg";
import { analyzeDishPhoto, imageKind } from "../nutrition/analyze";
import { applyEdits, parseEdits } from "../nutrition/edits";
import { DishAnalysis, NotFoodError, VisionUnavailableError } from "../nutrition/types";
import {
  nutritionScore,
  rollRarity,
  combatBase,
  checkPlausibility,
  NutritionInput
} from "../game/nutritionScore";
import { mintValue } from "../game/rarityBands";
import { SCAN_MINT_STAR } from "../game/spec";
import { asCharacter, rosterFor } from "../data/roster";
import { recordNutritionAction } from "./user";
import { enqueueMirror } from "../services/mirrorQueue";
import { mintCollectionDrop } from "../services/lootboxState";
import { scanSchema, manualMealSchema, mealEditSchema } from "../schemas/gameSchemas";

// OFF is community-entered: the per-100g fields are usually numbers but
// arrive as numeric strings often enough that the feed must accept both.
type OFFNumber = number | string;

interface OFFNutriments {
  "energy-kcal_100g"?: OFFNumber;
  energy_100g?: OFFNumber;
  proteins_100g?: OFFNumber;
  carbohydrates_100g?: OFFNumber;
  fat_100g?: OFFNumber;
  "fiber_100g"?: OFFNumber;
  sugars_100g?: OFFNumber;
  sodium_100g?: OFFNumber;
  salt_100g?: OFFNumber;
  "saturated-fat_100g"?: OFFNumber;
  [key: string]: OFFNumber | undefined;
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
    serving_size?: string;
  };
}

/** Uniform roll unit in [0,1) from crypto bytes — the mint rolls are
 *  server-side and auditable, never client-supplied. */
const unit = () => randomBytes(4).readUInt32BE(0) / 0x1_0000_0000;

/**
 * The nutrition snapshot for a product — the exact numbers the monster is
 * generated from, stored verbatim in scan_mint at mint time (anti-cheat).
 * OFF reports sodium in grams; the game scores in milligrams, so the snapshot
 * normalises once, here, and nothing downstream re-interprets the feed.
 */
function nutritionFromOFF(product: OFFProduct["product"]): NutritionInput {
  const n = (product?.nutriments ?? {}) as OFFNutriments;
  // Numeric strings count; an empty string does not (Number("") is 0, which
  // would log a 0 kcal product as fact).
  const num = (v: unknown): number | undefined => {
    if (typeof v === "number") return Number.isFinite(v) ? v : undefined;
    if (typeof v === "string" && v.trim() !== "") {
      const parsed = Number(v);
      return Number.isFinite(parsed) ? parsed : undefined;
    }
    return undefined;
  };
  const sodiumG = num(n.sodium_100g) ?? (num(n.salt_100g) !== undefined ? num(n.salt_100g)! / 2.5 : undefined);
  const kcal = num(n["energy-kcal_100g"]) ?? (num(n.energy_100g) !== undefined ? num(n.energy_100g)! / 4.184 : undefined);
  return {
    calories: kcal,
    proteinG: num(n.proteins_100g),
    carbsG: num(n.carbohydrates_100g),
    fatG: num(n.fat_100g),
    fiberG: num(n["fiber_100g"]),
    sugarG: num(n.sugars_100g),
    sodiumMg: sodiumG !== undefined ? sodiumG * 1000 : undefined,
    satFatG: num(n["saturated-fat_100g"])
  };
}

function asScanNutrition(n: NutritionInput): ScanNutrition {
  return {
    calories: n.calories,
    proteinG: n.proteinG,
    carbsG: n.carbsG,
    fatG: n.fatG,
    fiberG: n.fiberG,
    sugarG: n.sugarG,
    sodiumMg: n.sodiumMg,
    satFatG: n.satFatG
  };
}

// --- persistence helpers ----------------------------------------------------

/** True when this player has already minted from this barcode — ever.
 *  scan_mint is authoritative; scan_seen keeps pre-016 mints honoured. */
const hasMinted = (playerId: string, barcode: string): boolean =>
  !!db.prepare(`SELECT 1 FROM scan_mint WHERE player_id = ? AND barcode = ?`).get(playerId, barcode) ||
  !!db.prepare(`SELECT 1 FROM scan_seen WHERE player_id = ? AND barcode = ?`).get(playerId, barcode);

const markSeen = (playerId: string, barcode: string) =>
  db.prepare(`INSERT INTO scan_seen (player_id, barcode, seen_at) VALUES (?, ?, datetime('now'))
              ON CONFLICT(player_id, barcode) DO UPDATE SET seen_at = datetime('now')`).run(playerId, barcode);

interface MintRecord {
  dropId: string;
  characterId: string;
  nutrition: string;
  source: string;
}

/** Anti-cheat snapshot: one row per (player, barcode) for all time. The PK
 *  is the enforcement — a second insert throws rather than double-minting. */
const recordMint = (playerId: string, barcode: string, mint: MintRecord) =>
  db.prepare(
    `INSERT INTO scan_mint (player_id, barcode, drop_id, character_id, nutrition, source)
     VALUES (?, ?, ?, ?, ?, ?)`
  ).run(playerId, barcode, mint.dropId, mint.characterId, mint.nutrition, mint.source);

const loadCharacters = (playerId: string): Character[] =>
  (db.prepare(`SELECT payload FROM scan_character WHERE player_id = ?`).all(playerId) as { payload: string }[])
    .map((r) => JSON.parse(r.payload) as Character);

const saveCharacter = (playerId: string, character: Character) =>
  db.prepare(`INSERT OR IGNORE INTO scan_character (player_id, char_id, payload) VALUES (?, ?, ?)`)
    .run(playerId, character.id, JSON.stringify(character));

interface MealRow {
  meal_id: string;
  player_id: string;
  source: "barcode" | "photo" | "manual";
  name: string;
  calories: number | null;
  protein_g: number | null;
  carbs_g: number | null;
  fat_g: number | null;
  fiber_g: number | null;
  sugar_g: number | null;
  sodium_mg: number | null;
  sat_fat_g: number | null;
  barcode: string | null;
  analysis_id: string | null;
  flagged: number;
  logged_at: string;
  updated_at: string;
  removed: number;
}

function insertMeal(playerId: string, meal: {
  source: "barcode" | "photo" | "manual";
  name: string;
  nutrition: NutritionInput;
  barcode?: string;
  analysisId?: string;
  flagged?: boolean;
}): string {
  const mealId = randomUUID();
  db.prepare(
    `INSERT INTO meal_log (meal_id, player_id, source, name, calories, protein_g, carbs_g, fat_g,
                           fiber_g, sugar_g, sodium_mg, sat_fat_g, barcode, analysis_id, flagged)
     VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`
  ).run(
    mealId,
    playerId,
    meal.source,
    meal.name,
    meal.nutrition.calories ?? null,
    meal.nutrition.proteinG ?? null,
    meal.nutrition.carbsG ?? null,
    meal.nutrition.fatG ?? null,
    meal.nutrition.fiberG ?? null,
    meal.nutrition.sugarG ?? null,
    meal.nutrition.sodiumMg ?? null,
    meal.nutrition.satFatG ?? null,
    meal.barcode ?? null,
    meal.analysisId ?? null,
    meal.flagged ? 1 : 0
  );
  return mealId;
}

function mealDto(row: MealRow) {
  return {
    mealId: row.meal_id,
    source: row.source,
    name: row.name,
    calories: row.calories,
    proteinG: row.protein_g,
    carbsG: row.carbs_g,
    fatG: row.fat_g,
    flagged: row.flagged === 1,
    loggedAt: row.logged_at
  };
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

export function createScanRouter(
  fetchProduct?: (barcode: string) => Promise<OFFProduct | null>,
  analyzeDish?: (imageBase64: string) => Promise<DishAnalysis>
): Router {
const scanRouter = Router();
scanRouter.use(requirePlayerId);
const fetchOFFOrDefault = fetchProduct ?? fetchOFF;
// Injectable so the dish-photo tests never make a vision call.
const analyzeDishOrDefault = analyzeDish ?? ((image: string) => analyzeDishPhoto(image));

// POST /scan { barcode } — the only mint path. Fetches nutrition from Open
// Food Facts (never the client), scores it holistically, and on the FIRST
// scan of this barcode by this player mints a ★1 monster: rarity from the
// NutritionScore-tilted roll, character design picked uniformly from the
// catalog, combat base from the Attack/Health profiles, mint value from the
// §2 segment roll. Re-scans log nutrition and earn task credit but never
// mint again — the scan_mint PK makes a double-mint impossible even if two
// requests race.
scanRouter.post("/", rateLimitByPlayer({ windowMs: 60_000, max: 10, keyPrefix: "scan", message: "Too many scans. Try again later." }), async (req: PlayerRequest, res) => {
  const parsed = scanSchema.safeParse(req.body);
  if (!parsed.success) {
    return res.status(400).json({ error: "barcode must be a string of 6-20 digits (EAN/UPC)." });
  }
  const { barcode } = parsed.data;
  if (!/^\d{6,20}$/.test(barcode)) {
    return res.status(400).json({ error: "barcode must be a string of 6-20 digits (EAN/UPC)." });
  }

  const off = await fetchOFFOrDefault(barcode);
  if (!off || off.status !== 1 || !off.product) {
    return res.status(404).json({ error: "product not found in Open Food Facts" });
  }

  const key = req.playerId!;
  const name = off.product.product_name_en ?? off.product.product_name ?? "Unknown food";
  const brands = off.product.brands?.trim();
  const nutrition = nutritionFromOFF(off.product);

  // Reject impossible/outlier nutrition before it can mint anything
  // (checklist anti-cheat). An implausible feed also doesn't get logged as
  // fact — the meal log is a ledger, not a scratchpad.
  const plausibility = checkPlausibility(nutrition);
  if (!plausibility.plausible) {
    // Community-entered OFF rows fail this often enough that the barcode and
    // the rule that fired need to be visible server-side.
    console.warn(`[scan] rejected ${barcode} (${name}): ${plausibility.reasons.join("; ")}`);
    return res.status(422).json({
      error: {
        code: "IMPLAUSIBLE_NUTRITION",
        message: "The nutrition data for this product failed sanity checks.",
        reasons: plausibility.reasons
      }
    });
  }

  const score = nutritionScore(nutrition);
  const duplicate = hasMinted(key, barcode);

  let character: Character | undefined;
  let mint: { dropId: string; netWorth: number; stars: number } | undefined;

  if (!duplicate) {
    // Draw the monster: NutritionScore tilts the rarity roll, the design is a
    // uniform pick across the 14, and the mint value uses the §2 segment roll.
    const rarityUnit = unit();
    const rarity: Rarity = rollRarity(score, rarityUnit);
    const characterUnit = unit();
    const pool = rosterFor(rarity);
    const entry = pool[Math.floor(characterUnit * pool.length)];
    const stats = combatBase(nutrition);
    const segmentUnit = unit();
    const positionUnit = unit();
    const netWorth = mintValue(rarity, segmentUnit, positionUnit);
    character = asCharacter(entry, rarity, stats);

    // Atomic: the drop, the collection entry and the anti-cheat record all
    // commit together — a crash mid-mint can never leave a monster without
    // its provenance, or provenance for a monster that doesn't exist.
    db.exec("BEGIN IMMEDIATE");
    try {
      const drop = mintCollectionDrop(key, character, "scan", {
        value: netWorth,
        rolls: { rarity: rarityUnit, character: characterUnit, mintSegment: segmentUnit, mintPosition: positionUnit }
      });
      recordMint(key, barcode, {
        dropId: drop.id,
        characterId: entry.id,
        nutrition: JSON.stringify(asScanNutrition(nutrition)),
        source: "openfoodfacts"
      });
      saveCharacter(key, character);
      db.exec("COMMIT");
      mint = { dropId: drop.id, netWorth, stars: SCAN_MINT_STAR };
    } catch (err) {
      db.exec("ROLLBACK");
      throw err;
    }
    markSeen(key, barcode);
  } else {
    markSeen(key, barcode);
  }

  // Every successful scan logs the meal — mint or not (spec: re-scans still
  // log nutrition and count for tasks).
  const mealId = insertMeal(key, { source: "barcode", name, nutrition, barcode });
  // An eligible nutrition action — feeds the streak (spec §6), not RR.
  recordNutritionAction(key);

  const result: ScanResult & { mealId: string; mint?: typeof mint } = {
    barcode,
    foodName: name,
    ...(brands ? { brands } : {}),
    nutritionScore: Math.round(score * 10) / 10,
    summonedCharacter: character,
    nutrition: asScanNutrition(nutrition),
    duplicate,
    mealId,
    ...(mint ? { mint } : {})
  };

  // Best-effort gameplay-event mirror into the TigerData hypertable.
  if (hasDatabaseUrl()) {
    enqueueMirror("gameplay_event", `scan:${key}:${barcode}:${mealId}`, {
      playerId: key,
      type: "scan",
      detail: { barcode, duplicate, nutritionScore: result.nutritionScore },
    });
    if (character && mint) {
      enqueueMirror("gameplay_event", `collect:${key}:${mint.dropId}`, {
        playerId: key,
        type: "collect",
        detail: { characterId: character.id, rarity: character.rarity, source: "scan" },
      });
      enqueueMirror("acquisition_event", mint.dropId, {
        playerId: key,
        sourceKind: "scan",
        rarity: character.rarity,
        netWorth: mint.netWorth,
        starLevel: SCAN_MINT_STAR,
        characterRef: character.id,
      });
    }
    enqueueMirror("meal_intake", `${mealId}:intake`, {
      playerId: key,
      meal: {
        calories: nutrition.calories ?? 0,
        proteinG: nutrition.proteinG ?? 0,
        carbsG: nutrition.carbsG ?? 0,
        fatG: nutrition.fatG ?? 0,
        sodiumMg: nutrition.sodiumMg ?? 0,
      },
    });
  }

  res.json({ result });
});

// ===== Dish photo scan (no barcode) =====
//
// Two steps, deliberately. Analysis produces a draft breakdown the user must
// review; confirmation logs the meal. Per the spec a photographed dish NEVER
// mints a monster — barcode is the only food path that can. What the photo
// path does produce is a nutrition log entry, flagged for review when the
// estimate is shaky (low confidence) or the totals are implausible.
//
// The draft is held server-side so the confirm step can only rescale, rename
// or drop items the server itself analysed — a client can never hand us
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

// Step 1 — analyse. Produces the draft the user reviews; nothing is logged or
// minted. Rate-limited tighter than barcode scans because each call is a
// vision request.
scanRouter.post(
  "/photo/analyze",
  rateLimitByPlayer({ windowMs: 60_000, max: 5, keyPrefix: "scan:photo", message: "Photo scans are heavy; max 5 per minute." }),
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
// server-side, and logs the meal. No monster is minted here — ever. The
// response flags the estimate for review when confidence is low or the
// confirmed totals are implausible; flagging is advisory (the user already
// reviewed the plate), but it is persisted on the meal row so the app can
// distinguish estimates it should double-check later.
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
    // One analysis logs one meal — a confirm can't be replayed for more.
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

    // The confirmed plate, expressed per-100g, goes through the same
    // plausibility gate a barcode feed would — a plate whose totals are
    // physically impossible is flagged even after the user OK'd it.
    const t = confirmed.totals;
    const grams = t.portionG > 0 ? t.portionG : 100;
    const per100 = (v: number) => (v * 100) / grams;
    const nutrition: NutritionInput = {
      calories: per100(t.calories),
      proteinG: per100(t.proteinG),
      carbsG: per100(t.carbsG),
      fatG: per100(t.fatG),
      fiberG: per100(t.fiberG),
      sugarG: per100(t.sugarG),
      sodiumMg: per100(t.sodiumMg)
    };
    const implausible = !checkPlausibility(nutrition).plausible;
    const flagged = confirmed.lowConfidence || implausible;

    markAnalysisConsumed(confirmed.analysisId);
    const mealId = insertMeal(req.playerId!, {
      source: "photo",
      name: confirmed.dishName,
      // The meal row stores what was actually eaten — absolute totals, not
      // per-100g figures.
      nutrition: {
        calories: t.calories,
        proteinG: t.proteinG,
        carbsG: t.carbsG,
        fatG: t.fatG,
        fiberG: t.fiberG,
        sugarG: t.sugarG,
        sodiumMg: t.sodiumMg
      },
      analysisId: confirmed.analysisId,
      flagged
    });
    recordNutritionAction(req.playerId!);

    if (hasDatabaseUrl()) {
      enqueueMirror("meal_intake", `${analysisId}:intake`, {
        playerId: req.playerId!,
        meal: {
          calories: t.calories, proteinG: t.proteinG, carbsG: t.carbsG, fatG: t.fatG,
          sodiumMg: t.sodiumMg, foodGroup: t.dominantFoodGroup, microScore: t.microScore,
        },
      });
    }

    res.json({
      result: {
        source: "photo",
        foodName: confirmed.dishName,
        mealId,
        items: confirmed.items,
        nutrition: confirmed.totals,
        lowConfidence: confirmed.lowConfidence,
        implausible,
        flagged
      }
    });
  }
);

// ===== Meal logging =====
//
// One intake record across barcode / photo / manual. The dashboard contract
// is kcal + protein + carbs + fat only — that's what /scan/meals/today and
// the list endpoint's totals carry.

// POST /scan/meals — manual entry. Like everything else it never mints.
scanRouter.post("/meals", (req: PlayerRequest, res) => {
  const parsed = manualMealSchema.safeParse(req.body);
  if (!parsed.success) {
    return res.status(400).json({
      error: { code: "INVALID_MEAL", message: parsed.error.issues[0]?.message ?? "invalid meal" }
    });
  }
  const meal = parsed.data;
  const mealId = insertMeal(req.playerId!, {
    source: "manual",
    name: meal.name,
    nutrition: {
      calories: meal.calories,
      proteinG: meal.proteinG,
      carbsG: meal.carbsG,
      fatG: meal.fatG,
      fiberG: meal.fiberG,
      sugarG: meal.sugarG,
      sodiumMg: meal.sodiumMg,
      satFatG: meal.satFatG
    }
  });
  recordNutritionAction(req.playerId!);
  res.status(201).json({ mealId });
});

// GET /scan/meals?date=YYYY-MM-DD — one day's log plus its totals. Omitting
// the date returns today's.
scanRouter.get("/meals", (req: PlayerRequest, res) => {
  const date = typeof req.query.date === "string" && /^\d{4}-\d{2}-\d{2}$/.test(req.query.date)
    ? req.query.date
    : new Date().toISOString().slice(0, 10);
  const rows = db
    .prepare(`SELECT * FROM meal_log WHERE player_id = ? AND removed = 0 AND date(logged_at) = ? ORDER BY logged_at`)
    .all(req.playerId!, date) as unknown as MealRow[];
  const totals = rows.reduce(
    (acc, r) => ({
      calories: acc.calories + (r.calories ?? 0),
      proteinG: acc.proteinG + (r.protein_g ?? 0),
      carbsG: acc.carbsG + (r.carbs_g ?? 0),
      fatG: acc.fatG + (r.fat_g ?? 0)
    }),
    { calories: 0, proteinG: 0, carbsG: 0, fatG: 0 }
  );
  res.json({ date, meals: rows.map(mealDto), totals });
});

// GET /scan/meals/today — the dashboard feed (spec: kcal/protein/carbs/fat
// only). W4's home screen reads exactly this shape.
scanRouter.get("/meals/today", (req: PlayerRequest, res) => {
  const today = new Date().toISOString().slice(0, 10);
  const row = db
    .prepare(
      `SELECT COALESCE(SUM(calories), 0) AS calories,
              COALESCE(SUM(protein_g), 0) AS protein,
              COALESCE(SUM(carbs_g), 0) AS carbs,
              COALESCE(SUM(fat_g), 0) AS fat
       FROM meal_log WHERE player_id = ? AND removed = 0 AND date(logged_at) = ?`
    )
    .get(req.playerId!, today) as { calories: number; protein: number; carbs: number; fat: number };
  res.json({ date: today, totals: row });
});

// PATCH /scan/meals/:mealId — correct a logged entry. Name and the four
// dashboard macros are editable; everything else stays as recorded.
scanRouter.patch("/meals/:mealId", (req: PlayerRequest, res) => {
  const parsed = mealEditSchema.safeParse(req.body);
  if (!parsed.success) {
    return res.status(400).json({
      error: { code: "INVALID_MEAL_EDIT", message: parsed.error.issues[0]?.message ?? "invalid edit" }
    });
  }
  const edit = parsed.data;
  const row = db
    .prepare(`SELECT * FROM meal_log WHERE meal_id = ? AND player_id = ? AND removed = 0`)
    .get(req.params.mealId, req.playerId!) as MealRow | undefined;
  if (!row) {
    return res.status(404).json({ error: { code: "MEAL_NOT_FOUND", message: "No such meal" } });
  }
  db.prepare(
    `UPDATE meal_log SET name = ?, calories = ?, protein_g = ?, carbs_g = ?, fat_g = ?, updated_at = datetime('now')
     WHERE meal_id = ?`
  ).run(
    edit.name ?? row.name,
    edit.calories ?? row.calories,
    edit.proteinG ?? row.protein_g,
    edit.carbsG ?? row.carbs_g,
    edit.fatG ?? row.fat_g,
    row.meal_id
  );
  res.json({ mealId: row.meal_id });
});

// DELETE /scan/meals/:mealId — tombstone, not a hard delete: ledgers and
// mirrors stay replayable.
scanRouter.delete("/meals/:mealId", (req: PlayerRequest, res) => {
  const row = db
    .prepare(`SELECT 1 FROM meal_log WHERE meal_id = ? AND player_id = ? AND removed = 0`)
    .get(req.params.mealId, req.playerId!);
  if (!row) {
    return res.status(404).json({ error: { code: "MEAL_NOT_FOUND", message: "No such meal" } });
  }
  db.prepare(`UPDATE meal_log SET removed = 1, updated_at = datetime('now') WHERE meal_id = ?`)
    .run(req.params.mealId);
  res.json({ removed: true });
});

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
