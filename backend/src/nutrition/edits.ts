// Applying the user's corrections to a draft analysis.
//
// The confirm screen is what makes a photo-only estimate trustworthy enough to
// mint a character from, so users must be able to fix what the model got
// wrong. But "let the client send nutrition numbers" would be a free pass to
// mint a maxed character, so edits are deliberately limited to three verbs:
//
//   rename    — cosmetic only, never touches nutrition
//   re-portion — scales the item, holding the analysed density constant
//   remove    — drops the item entirely
//
// Nutrient density always comes from the server's own analysis. A user who
// hits a genuinely misidentified item removes it and re-shoots rather than
// hand-editing macros.

import { DishAnalysis, DishItem, NotFoodError } from "./types";
import { computeTotals, scaleItem } from "./totals";
import { LIMITS } from "./analyze";

/** One correction from the confirm screen. All fields but `id` are optional. */
export interface ItemEdit {
  id: string;
  name?: string;
  portionG?: number;
  removed?: boolean;
}

const clamp = (v: number, lo: number, hi: number) => Math.min(hi, Math.max(lo, v));

/** Validate a raw edits payload into typed edits. Unknown shapes are ignored
 *  rather than rejected, so a partial/garbled body can't wedge the flow. */
export function parseEdits(raw: unknown): ItemEdit[] {
  if (!Array.isArray(raw)) return [];
  const edits: ItemEdit[] = [];
  for (const entry of raw.slice(0, LIMITS.maxItems)) {
    if (typeof entry !== "object" || entry === null) continue;
    const e = entry as Record<string, unknown>;
    if (typeof e.id !== "string") continue;
    const edit: ItemEdit = { id: e.id };
    if (typeof e.name === "string") edit.name = e.name.trim().slice(0, 60);
    if (e.portionG !== undefined) {
      const n = Number(e.portionG);
      if (Number.isFinite(n)) edit.portionG = clamp(n, 0, LIMITS.item.portionG);
    }
    if (e.removed === true) edit.removed = true;
    edits.push(edit);
  }
  return edits;
}

/**
 * Apply corrections to a stored analysis and recompute every total.
 *
 * @throws NotFoodError if the edits would leave an empty plate.
 */
export function applyEdits(analysis: DishAnalysis, edits: ItemEdit[]): DishAnalysis {
  const byId = new Map(edits.map((e) => [e.id, e]));

  const items: DishItem[] = [];
  for (const item of analysis.items) {
    const edit = byId.get(item.id);
    if (edit?.removed) continue;

    let next = item;
    if (edit?.portionG !== undefined && edit.portionG !== item.portionG) {
      // A portion edited to zero means "this isn't on the plate".
      if (edit.portionG <= 0) continue;
      next = scaleItem(next, edit.portionG);
    }
    if (edit?.name && edit.name.length > 0) {
      next = { ...next, name: edit.name };
    }
    items.push(next);
  }

  if (items.length === 0) {
    throw new NotFoodError("Every item was removed — nothing left to log");
  }

  return {
    ...analysis,
    items,
    totals: computeTotals(items),
    // The user has now vetted the plate, so it is no longer "low confidence"
    // in the sense the UI cares about, but keep the model's own score for
    // telemetry.
    lowConfidence: false
  };
}
