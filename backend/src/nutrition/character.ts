// Confirmed plate -> the shapes the character pipeline already speaks.
//
// Phase 2 of the dish-photo feature. Deliberately thin: the stat formulas,
// element mapping and clamping all stay in the barcode pipeline (routes/scan.ts)
// so a photographed dish and a scanned product are scored by exactly the same
// math. All this module does is translate a plate into that vocabulary and
// decide rarity from the signals a plate actually has.

import { DishAnalysis } from "./types";
import { per100g } from "./totals";
import type { Rarity } from "../types";

/**
 * Rarity a dish can be assigned. Reuses the shared 7-tier `Rarity` union
 * rather than redeclaring a narrow copy — a duplicate list here is exactly
 * the drift that let crate tiers (uncommon/mythic/secret) go unrepresentable.
 * Like barcode scans, `dishRarity()` only ever *mints* the 4 core tiers;
 * the wider tiers are crate-exclusive.
 */
export type DishRarity = Rarity;

/**
 * An Open-Food-Facts-shaped product built from the plate, so `deriveStats()`
 * can score it without knowing photos exist.
 *
 * Portion weight comes from the analysis, so the per-100g conversion is real
 * rather than the old "assume a 500 g plate" divide-by-five.
 */
export function dishToProduct(analysis: DishAnalysis) {
  const totals = analysis.totals;
  return {
    product_name: analysis.dishName,
    nutriments: per100g(totals),
    nova_group: analysis.nova,
    // Tags exist only so anything reading OFF-shaped data sees a consistent
    // record; the real micronutrient signal is passed separately as a score.
    vitamins_tags: totals.micronutrients.filter((m) => m.startsWith("vitamin-")),
    minerals_tags: totals.micronutrients.filter((m) => !m.startsWith("vitamin-"))
  };
}

/**
 * Rarity from the signals a plate genuinely carries.
 *
 * A barcode product gets rarity from scarcity/labels, which a home-cooked
 * plate simply doesn't have. The equivalent signal for a dish is how good the
 * plate actually is: micronutrient coverage, fibre, protein and variety, minus
 * a sugar penalty. Photo dishes can reach every tier — same range as barcode
 * scans — but a legendary plate has to earn it on all four axes at once.
 */
export function dishRarity(analysis: DishAnalysis): DishRarity {
  // Ultra-processed plates stay common, matching the NOVA-4 rule the barcode
  // path and the canonical `assign_rarity()` both apply.
  if (analysis.nova >= 4) return "common";

  const t = analysis.totals;
  const micro = t.microScore >= 0.83 ? 3 : t.microScore >= 0.5 ? 2 : t.microScore >= 0.33 ? 1 : 0;
  const fibre = t.fiberG >= 12 ? 2 : t.fiberG >= 6 ? 1 : 0;
  const protein = t.proteinG >= 35 ? 2 : t.proteinG >= 20 ? 1 : 0;
  const variety = t.foodGroups.length >= 4 ? 2 : t.foodGroups.length >= 3 ? 1 : 0;
  const sugarPenalty = t.sugarG >= 50 ? 2 : t.sugarG >= 25 ? 1 : 0;

  const score = micro + fibre + protein + variety - sugarPenalty;

  if (score >= 8) return "legendary";
  if (score >= 6) return "epic";
  if (score >= 3) return "rare";
  return "common";
}
