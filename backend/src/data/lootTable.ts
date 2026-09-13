// Loot catalogue: the rarity ladder and the Cookbooks.
//
// Character designs live in the master authored catalog (characters.json,
// loaded+validated by roster.ts) — a design has NO rarity; rarity is rolled
// per monster instance at mint (spec §2). This file is the economy half:
// tier display data, book prices/odds (frozen in game/spec.ts), and the
// pool helpers mints draw from.

import { Cookbook, Rarity, RarityTier } from "../types";
import { COOKBOOKS as COOKBOOK_SPECS } from "../game/spec";
import { ROSTER, RosterCharacter, rosterFor } from "./roster";

/**
 * Weights are integers out of RARITY_TOTAL so the distribution stays exact.
 * Percentages that almost sum to 100 are a classic source of drift in loot
 * systems, and the error always favours the wrong tier.
 *
 * Each tier is one fifth as likely as the one below it -- the same geometric
 * decay CS:GO uses, which is what makes the top of the ladder feel genuinely
 * out of reach rather than merely uncommon.
 */
export const RARITY_TOTAL = 1_000_000;

/**
 * The tier ladder. `statMultiplier` scales a unit's battle stats and is
 * consumed by routes/battle.ts, so every droppable tier is automatically a
 * battle-legal one.
 *
 * The four original multipliers (1.0 / 1.12 / 1.25 / 1.4) are unchanged, so
 * this adds tiers without re-balancing existing matchups. Uncommon sits at the
 * midpoint of the common-to-rare step, and mythic and secret continue the
 * +0.15 cadence that epic -> legendary already set.
 */
export const RARITY_TIERS: Record<Rarity, RarityTier> = {
  common:    { id: "common",    label: "Common",    weight: 800_000, colorHex: "#9AA4B2", order: 0, statMultiplier: 1.0 },
  uncommon:  { id: "uncommon",  label: "Uncommon",  weight: 160_000, colorHex: "#4ADE80", order: 1, statMultiplier: 1.06 },
  rare:      { id: "rare",      label: "Rare",      weight:  32_000, colorHex: "#3B82F6", order: 2, statMultiplier: 1.12 },
  epic:      { id: "epic",      label: "Epic",      weight:   6_400, colorHex: "#A855F7", order: 3, statMultiplier: 1.25 },
  legendary: { id: "legendary", label: "Legendary", weight:   1_280, colorHex: "#F59E0B", order: 4, statMultiplier: 1.4 },
  mythic:    { id: "mythic",    label: "Mythic",    weight:     256, colorHex: "#EF4444", order: 5, statMultiplier: 1.55 },
  secret:    { id: "secret",    label: "Secret",    weight:      64, colorHex: "#22D3EE", order: 6, statMultiplier: 1.7 }
};

/** Tier ids from most to least common. Use wherever order matters. */
export const RARITY_ORDER: Rarity[] = (Object.keys(RARITY_TIERS) as Rarity[]).sort(
  (a, b) => RARITY_TIERS[a].order - RARITY_TIERS[b].order
);

// A mint's net worth comes from the rarity bands in game/rarityBands.ts:
// the weighted segment roll (55/27/13/4/1) decides where inside the band a
// ★1 lands, and that baseMintValue is permanent. There is exactly one
// economy ladder — the spec removed power bands, shiny variants, and the
// parallel coin-shop pricing table that used to live here.

/**
 * The pool a mint draws its character design from. Rarity is a property of
 * the instance, not the design (spec §2) — but designs may whitelist the
 * rarities they can mint at via `rarityEligibility`, and the brainrot set
 * is Secret-only, so the pool depends on the rolled rarity.
 */
export function mintPool(rarity?: Rarity): RosterCharacter[] {
  return rarity === undefined ? ROSTER : rosterFor(rarity);
}

// ---------------------------------------------------------------------------
// Cookbooks (spec §3)
// ---------------------------------------------------------------------------

const COOKBOOK_DESCRIPTIONS: Record<string, string> = {
  "super-simple-cookbook": "Recipes on the back of the box. Commons only — a thousand coins, no surprises.",
  "home-cookbook": "Weeknight staples. Every tier is reachable, even Secret, but the odds favour the everyday.",
  "chefs-cookbook": "A working kitchen's shelf. Better table, better pulls.",
  "master-cookbook": "Technique and patience. Epic and Legendary are realistic goals here.",
  "forbidden-cookbook": "No Commons at all. The book nobody was supposed to publish.",
  "secret-cookbook": "One hundred thousand coins for a one-in-ten shot at a Secret. The table the Gatekeeper doesn't talk about."
};

/**
 * The Cookbooks, cheapest first — the only loot containers that exist
 * (spec §3). Opening one is: pay price, roll a rarity Case off the published
 * odds, mint a ★1 monster of that rarity. No keys, no pity.
 */
export const COOKBOOKS: Cookbook[] = COOKBOOK_SPECS.map((spec) => ({
  id: spec.id,
  name: spec.name,
  description: COOKBOOK_DESCRIPTIONS[spec.id] ?? "",
  price: spec.price,
  odds: spec.odds
}));

export const COOKBOOK_BY_ID: Record<string, Cookbook> = Object.fromEntries(
  COOKBOOKS.map((book) => [book.id, book])
);

// --- Invariants. Catch a bad edit here rather than at 3am mid-demo. ---

const weightSum = RARITY_ORDER.reduce((sum, r) => sum + RARITY_TIERS[r].weight, 0);
if (weightSum !== RARITY_TOTAL) {
  throw new Error(`Rarity weights sum to ${weightSum}, expected ${RARITY_TOTAL}`);
}

// A rarer pull must never be a statistical downgrade.
for (let i = 1; i < RARITY_ORDER.length; i++) {
  const prev = RARITY_TIERS[RARITY_ORDER[i - 1]];
  const curr = RARITY_TIERS[RARITY_ORDER[i]];
  if (curr.statMultiplier <= prev.statMultiplier) {
    throw new Error(
      `statMultiplier must increase with scarcity: ${curr.id} (${curr.statMultiplier}) <= ${prev.id} (${prev.statMultiplier})`
    );
  }
}

for (const book of COOKBOOKS) {
  const oddsSum = RARITY_ORDER.reduce((sum, r) => sum + (book.odds[r] ?? 0), 0);
  if (Math.abs(oddsSum - 1) > 1e-9) {
    throw new Error(`Cookbook '${book.id}' odds sum to ${oddsSum}, expected 1`);
  }
}
