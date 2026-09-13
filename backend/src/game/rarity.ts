// Rarity assignment — port of docs/BATTLE-SYSTEM.md §2 and the DB
// `assign_rarity()` function. Assigned ONCE at character creation; never
// recomputed retroactively.

// Full 7-tier ladder (matches backend/src/types.ts + data/lootTable.ts on
// main): crates can drop uncommon/mythic/secret, so stored rarity must admit
// all seven. Scans still only MINT the four core tiers below.
export type Rarity = "common" | "uncommon" | "rare" | "epic" | "legendary" | "mythic" | "secret";

// Core tiers mintable by assign_rarity (BATTLE-SYSTEM.md §2: scans never
// mint uncommon/mythic/secret — those are crate-exclusive).
const RANKS: Rarity[] = ["common", "rare", "epic", "legendary"];

/**
 * @param scarcityPercentile product's unique_scans rank in [0,1] (0 = rarest)
 * @param priceHigh          Open Prices price above the country 75th percentile
 * @param novaGroup          OFF NOVA classification (1..4)
 */
export function assignRarity(scarcityPercentile: number, priceHigh: boolean, novaGroup: number): Rarity {
  let idx =
    scarcityPercentile <= 0.05 ? 3 : scarcityPercentile <= 0.2 ? 2 : scarcityPercentile <= 0.5 ? 1 : 0;

  if (priceHigh) idx = Math.min(idx + 1, 3);

  // Ultra-processed cap: NOVA 4 caps at Epic unless scarcity is extreme.
  if (novaGroup === 4 && scarcityPercentile > 0.05) idx = Math.min(idx, 2);

  return RANKS[idx];
}

/** Rarity stat multipliers — mirrors RARITY_TIERS[].statMultiplier in
 *  backend/src/data/lootTable.ts (all seven tiers). */
export const RARITY_STAT_MULTIPLIER: Record<Rarity, number> = {
  common: 1.0,
  uncommon: 1.06,
  rare: 1.12,
  epic: 1.25,
  legendary: 1.4,
  mythic: 1.55,
  secret: 1.7
};
