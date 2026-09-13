// Dish photo → itemised nutrition estimate.
//
// This is the analysis engine. It identifies each distinct food on a plate,
// estimates a portion for each, and reports per-item nutrients — rather than
// one flat guess for "the meal", which is what the first version of the photo
// scan did and why its numbers weren't trustworthy.
//
// The model's reply is treated as hostile input: every field is re-typed,
// clamped and cross-checked before it leaves this module, and the plate totals
// are always recomputed from the items rather than believed.

import { randomUUID } from "crypto";
import {
  DishAnalysis,
  DishItem,
  FoodGroup,
  FOOD_GROUPS,
  Micronutrient,
  MICRONUTRIENTS,
  NotFoodError,
  VisionUnavailableError
} from "./types";
import { caloriesFromMacros, computeTotals } from "./totals";

// ---------------------------------------------------------------------------
// Sanity limits. A single plate that exceeds these is either a model
// hallucination or someone probing for a way to mint an over-powered
// character, and either way it gets clamped.
// ---------------------------------------------------------------------------
export const LIMITS = {
  maxItems: 12,
  item: {
    portionG: 2000,
    calories: 5000,
    macroG: 500,
    sodiumMg: 20_000
  },
  plate: {
    portionG: 5000,
    calories: 8000
  }
} as const;

/** Below this mean confidence the UI should push the user to check the
 *  breakdown carefully before confirming. */
export const LOW_CONFIDENCE_THRESHOLD = 0.55;

/** Model calories are replaced by the macro-derived figure when they disagree
 *  by more than this — internally consistent numbers beat a stray guess. */
const CALORIE_TOLERANCE = 0.4;

const clamp = (v: number, lo: number, hi: number) => Math.min(hi, Math.max(lo, v));
const round1 = (v: number) => Math.round(v * 10) / 10;

function num(value: unknown, max: number): number {
  const n = Number(value);
  if (!Number.isFinite(n) || n < 0) return 0;
  return round1(clamp(n, 0, max));
}

function text(value: unknown, fallback: string, maxLength: number): string {
  if (typeof value !== "string") return fallback;
  const trimmed = value.trim().replace(/\s+/g, " ");
  return trimmed.length === 0 ? fallback : trimmed.slice(0, maxLength);
}

function foodGroupOf(value: unknown): FoodGroup {
  const raw = typeof value === "string" ? value.trim().toLowerCase() : "";
  return (FOOD_GROUPS as readonly string[]).includes(raw) ? (raw as FoodGroup) : "other";
}

/** Normalises the many spellings a model reaches for ("vitamin C", "vit_c",
 *  "vitaminC") onto the six canonical keys. Unknown entries are dropped. */
function micronutrientsOf(value: unknown): Micronutrient[] {
  if (!Array.isArray(value)) return [];
  const found = new Set<Micronutrient>();
  for (const entry of value) {
    if (typeof entry !== "string") continue;
    const key = entry.toLowerCase().replace(/[\s_]+/g, "-").replace(/^vit-/, "vitamin-");
    const match = MICRONUTRIENTS.find((m) => m === key || m.replace("-", "") === key.replace("-", ""));
    if (match) found.add(match);
  }
  return [...found];
}

/**
 * Turn one raw model item into a trusted DishItem.
 * Returns null for entries that carry no usable signal at all.
 */
function normalizeItem(raw: unknown, index: number): DishItem | null {
  if (typeof raw !== "object" || raw === null) return null;
  const r = raw as Record<string, unknown>;

  const portionG = num(r.portionGrams ?? r.portionG, LIMITS.item.portionG);
  const proteinG = num(r.proteinG, LIMITS.item.macroG);
  const carbsG = num(r.carbsG, LIMITS.item.macroG);
  const fatG = num(r.fatG, LIMITS.item.macroG);
  let calories = num(r.calories, LIMITS.item.calories);

  // An item with neither mass nor energy is noise (e.g. "garnish").
  if (portionG === 0 && calories === 0 && proteinG === 0 && carbsG === 0 && fatG === 0) return null;

  // Cross-check energy against the macros; prefer the internally consistent
  // figure when the model's calorie guess drifts.
  const derived = caloriesFromMacros(proteinG, carbsG, fatG);
  if (derived >= 10) {
    const drift = calories === 0 ? 1 : Math.abs(calories - derived) / derived;
    if (drift > CALORIE_TOLERANCE) calories = round1(clamp(derived, 0, LIMITS.item.calories));
  }

  const name = text(r.name, `Item ${index + 1}`, 60);

  return {
    id: `i${index}`,
    name,
    portionG: portionG || 1,
    portionLabel: text(r.portionLabel, `~${Math.round(portionG) || 1} g`, 40),
    calories,
    proteinG,
    carbsG,
    fatG,
    fiberG: num(r.fiberG, LIMITS.item.macroG),
    sugarG: num(r.sugarG, LIMITS.item.macroG),
    sodiumMg: num(r.sodiumMg, LIMITS.item.sodiumMg),
    micronutrients: micronutrientsOf(r.micronutrients),
    foodGroup: foodGroupOf(r.foodGroup),
    confidence: clamp(Number(r.confidence) || 0.5, 0, 1)
  };
}

/** Proportionally shrink a plate that blew past the sanity ceilings, so the
 *  item mix is preserved but the magnitude is believable. */
function capPlate(items: DishItem[]): DishItem[] {
  const totalG = items.reduce((a, i) => a + i.portionG, 0);
  const totalKcal = items.reduce((a, i) => a + i.calories, 0);
  const factor = Math.min(
    totalG > LIMITS.plate.portionG ? LIMITS.plate.portionG / totalG : 1,
    totalKcal > LIMITS.plate.calories ? LIMITS.plate.calories / totalKcal : 1
  );
  if (factor >= 1) return items;
  return items.map((i) => ({
    ...i,
    portionG: round1(i.portionG * factor),
    calories: round1(i.calories * factor),
    proteinG: round1(i.proteinG * factor),
    carbsG: round1(i.carbsG * factor),
    fatG: round1(i.fatG * factor),
    fiberG: round1(i.fiberG * factor),
    sugarG: round1(i.sugarG * factor),
    sodiumMg: round1(i.sodiumMg * factor)
  }));
}

/**
 * Validate + normalise a raw model reply into a DishAnalysis.
 * Exported so the sanitiser can be tested without a network round-trip.
 *
 * @throws NotFoodError when the reply signals "not food" or yields no items.
 */
export function normalizeAnalysis(raw: unknown, analysisId = randomUUID()): DishAnalysis {
  if (typeof raw !== "object" || raw === null) throw new NotFoodError();
  const r = raw as Record<string, unknown>;

  if (r.notFood === true || r.error === "not_food") throw new NotFoodError();

  const rawItems = Array.isArray(r.items) ? r.items.slice(0, LIMITS.maxItems) : [];
  const items = capPlate(
    rawItems.map((item, index) => normalizeItem(item, index)).filter((i): i is DishItem => i !== null)
  );
  if (items.length === 0) throw new NotFoodError();

  const hex = typeof r.colorHex === "string" && /^#[0-9a-fA-F]{6}$/.test(r.colorHex) ? r.colorHex : "#5FCB82";
  const confidence =
    Math.round((items.reduce((a, i) => a + i.confidence, 0) / items.length) * 100) / 100;

  return {
    analysisId,
    dishName: text(r.dishName ?? r.mealName, items[0].name, 60),
    colorHex: hex,
    nova: Math.round(clamp(Number(r.nova) || 1, 1, 4)),
    items,
    totals: computeTotals(items),
    confidence,
    lowConfidence: confidence < LOW_CONFIDENCE_THRESHOLD
  };
}

// ---------------------------------------------------------------------------
// Vision transport
// ---------------------------------------------------------------------------

const DISH_PROMPT = `You are a nutrition analyst. Look at this meal photo and identify EVERY distinct food on the plate separately.

Estimate the portion of each item in grams. Use visible scale references (plate rim ~26cm, fork ~19cm, spoon, hand) to judge size. Be realistic: a restaurant chicken breast is ~150-200g, a cup of cooked rice is ~160g.

Reply with ONLY a JSON object (no markdown fences, no prose):
{
  "dishName": "short name for the whole plate",
  "colorHex": "#RRGGBB dominant food colour",
  "nova": 1-4 processing level for the plate (4 = ultra-processed),
  "items": [
    {
      "name": "grilled chicken breast",
      "portionGrams": 160,
      "portionLabel": "1 breast (~160 g)",
      "calories": 264,
      "proteinG": 49,
      "carbsG": 0,
      "fatG": 6,
      "fiberG": 0,
      "sugarG": 0,
      "sodiumMg": 110,
      "micronutrients": ["iron", "potassium"],
      "foodGroup": "protein",
      "confidence": 0.8
    }
  ]
}

Rules:
- One entry per distinct food. Do not merge a mixed plate into one item.
- Nutrient values are for the estimated portion, NOT per 100g.
- "sodiumMg" is milligrams of sodium for the portion.
- "micronutrients": only from ["vitamin-a","vitamin-c","vitamin-b12","iron","calcium","potassium"], only ones meaningfully present.
- "foodGroup": one of ["produce","grain","dairy","protein","other"].
- "confidence": 0-1, how sure you are of this item's identity and portion.
- If the photo contains no food at all, reply exactly {"notFood": true}.`;

/** Injectable transport so tests never hit the network. */
export type VisionCall = (imageBase64: string, prompt: string) => Promise<string>;

// Any OpenAI-compatible chat-completions endpoint works, but the default is
// OpenAI's gpt-4o-mini: the previous default (Pollinations' anonymous tier)
// answers 402 Payment Required for uncached requests, so photo scanning was
// dead out of the box. VISION_API_URL/VISION_MODEL still override for other
// providers (OpenRouter, Groq, a local vLLM, …).
const VISION_API_URL = process.env.VISION_API_URL || "https://api.openai.com/v1/chat/completions";
const VISION_MODEL = process.env.VISION_MODEL || "gpt-4o-mini";
const VISION_API_KEY = process.env.VISION_API_KEY || process.env.OPENAI_API_KEY;

/** Which image bytes a photo is allowed to carry, by magic number. The route
 *  checks this before spending a vision call on a payload that can't be a
 *  meal photo. */
export function imageKind(base64: string): "jpeg" | "png" | "webp" | null {
  let buf: Buffer;
  try {
    buf = Buffer.from(base64, "base64");
  } catch {
    return null;
  }
  if (buf.length < 12) return null;
  if (buf[0] === 0xff && buf[1] === 0xd8 && buf[2] === 0xff) return "jpeg";
  if (buf[0] === 0x89 && buf[1] === 0x50 && buf[2] === 0x4e && buf[3] === 0x47) return "png";
  if (buf[0] === 0x52 && buf[1] === 0x49 && buf[2] === 0x46 && buf[3] === 0x46 &&
      buf[8] === 0x57 && buf[9] === 0x45 && buf[10] === 0x42 && buf[11] === 0x50) return "webp";
  return null;
}

const MIME_FOR: Record<NonNullable<ReturnType<typeof imageKind>>, string> = {
  jpeg: "image/jpeg",
  png: "image/png",
  webp: "image/webp"
};

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

/** Statuses worth one retry: a hiccup, not a wrong photo. */
const RETRYABLE = new Set([408, 429, 500, 502, 503, 504]);

/** Default transport: an OpenAI-compatible vision endpoint, one retry on
 *  transient failures. */
export const pollinationsVision: VisionCall = async (imageBase64, prompt) => {
  const headers: Record<string, string> = { "Content-Type": "application/json" };
  if (VISION_API_KEY) headers.Authorization = `Bearer ${VISION_API_KEY}`;

  const mime = MIME_FOR[imageKind(imageBase64) ?? "jpeg"];

  let res: Response | null = null;
  let networkError: unknown = null;
  for (let attempt = 0; attempt < 2; attempt++) {
    if (attempt > 0) await sleep(1_500 * attempt);
    try {
      res = await fetch(VISION_API_URL, {
        method: "POST",
        headers,
        body: JSON.stringify({
          model: VISION_MODEL,
          messages: [
            {
              role: "user",
              content: [
                { type: "text", text: prompt },
                { type: "image_url", image_url: { url: `data:${mime};base64,${imageBase64}` } }
              ]
            }
          ],
          max_tokens: 1200
        }),
        signal: AbortSignal.timeout(45_000)
      });
    } catch (err) {
      // Network failure or timeout — the analyser, not the photo. Retry once.
      networkError = err;
      res = null;
      continue;
    }
    if (res.ok || !RETRYABLE.has(res.status)) break;
  }

  if (!res) {
    throw new VisionUnavailableError(
      `Could not reach the photo analyser: ${networkError instanceof Error ? networkError.message : "network error"}`
    );
  }

  if (!res.ok) {
    const detail = res.status === 402 || res.status === 401 || res.status === 403
      ? "the analyser rejected our credentials or quota (set VISION_API_KEY / VISION_API_URL)"
      : `the analyser returned HTTP ${res.status}`;
    throw new VisionUnavailableError(`Photo analysis is unavailable: ${detail}`, res.status);
  }

  const data = (await res.json()) as { choices?: { message?: { content?: string } }[] };
  const content = data.choices?.[0]?.message?.content;
  if (!content) throw new VisionUnavailableError("The photo analyser returned an empty reply");
  return content;
};

/** Pull the JSON object out of a model reply that may be fenced or chatty. */
export function extractJson(content: string): unknown {
  const stripped = content.replace(/```json/gi, "").replace(/```/g, "").trim();
  try {
    return JSON.parse(stripped);
  } catch {
    // Fall back to the outermost {...} block.
    const start = stripped.indexOf("{");
    const end = stripped.lastIndexOf("}");
    if (start === -1 || end <= start) throw new NotFoodError("Vision reply was not JSON");
    try {
      return JSON.parse(stripped.slice(start, end + 1));
    } catch {
      throw new NotFoodError("Vision reply was not JSON");
    }
  }
}

/**
 * Analyse a dish photo end to end.
 * @throws NotFoodError when the photo isn't food or the reply is unusable.
 */
export async function analyzeDishPhoto(
  imageBase64: string,
  vision: VisionCall = pollinationsVision,
  analysisId = randomUUID()
): Promise<DishAnalysis> {
  const content = await vision(imageBase64, DISH_PROMPT);
  return normalizeAnalysis(extractJson(content), analysisId);
}
