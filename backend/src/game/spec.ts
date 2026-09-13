// ============================================================================
// THE SPEC — Phase 0 contract (final-dev-doc.pdf is ground truth)
//
// Every numeric constant the four workstreams share lives here, once.
// Do not copy these numbers into feature code — import them. If a balance
// change happens, it happens in this file and the parity tests in
// spec.test.ts keep the rest of the codebase honest.
//
// Removed by the spec (do not reintroduce): element/type system, power bands,
// shiny variants, keys, pity, account XP/levels, comeback rewards, arena
// wagers, async challenges, the power/guard/vitality/tempo stat set.
// ============================================================================

import { Rarity } from "../types";

// ---------------------------------------------------------------------------
// §2 Characters: rarities, stars, scaling
// ---------------------------------------------------------------------------

/** Combat multiplier per rarity (doc §2). Replaces lootTable statMultiplier. */
export const RARITY_COMBAT_MULT: Record<Rarity, number> = {
  common: 1.0,
  uncommon: 1.06,
  rare: 1.12,
  epic: 1.25,
  legendary: 1.4,
  mythic: 1.55,
  secret: 1.7
};

/** Rarity order ascending, index = rarityIndex used by the scan roll. */
export const SPEC_RARITY_ORDER: Rarity[] = [
  "common", "uncommon", "rare", "epic", "legendary", "mythic", "secret"
];
export const RARITY_INDEX: Record<Rarity, number> = Object.fromEntries(
  SPEC_RARITY_ORDER.map((r, i) => [r, i])
) as Record<Rarity, number>;

/** Rarities that may carry Mana and a Special Ability (doc §1/§4). */
export const MANA_MIN_RARITY: Rarity = "epic";
export function hasMana(rarity: Rarity): boolean {
  return RARITY_INDEX[rarity] >= RARITY_INDEX[MANA_MIN_RARITY];
}

/** Star combat multipliers, ★1..★5 (doc §2). Multiplicative with rarity. */
export const STAR_COMBAT_MULT: Record<number, number> = {
  1: 1.0, 2: 1.08, 3: 1.18, 4: 1.3, 5: 1.45
};

/** Star Mana multipliers, ★1..★5 (doc §4). */
export const STAR_MANA_MULT: Record<number, number> = {
  1: 1.0, 2: 1.1, 3: 1.2, 4: 1.35, 5: 1.5
};

export const MAX_STAR = 5;
/** Secret never exceeds ★2 (doc §2). */
export const SECRET_MAX_STAR = 2;
export function maxStarsFor(rarity: Rarity): number {
  return rarity === "secret" ? SECRET_MAX_STAR : MAX_STAR;
}

/** Fusion consumes exactly 3 same-character + same-rarity + same-star copies. */
export const FUSION_COPIES = 3;

// ---------------------------------------------------------------------------
// §2 Net worth: rarity bands, mint roll, additive star bonuses
// ---------------------------------------------------------------------------

export interface SpecBand {
  min: number;
  /** Inclusive. Spec gives an explicit ceiling even for Secret. */
  max: number;
}

/**
 * Fresh ★1 net-worth bands (doc §2). A mint never crosses its band.
 * Band width = max - min + 1; "step" in the star-bonus math is
 * min(next) - min(this), i.e. width of this band.
 */
export const SPEC_BANDS: Record<Rarity, SpecBand> = {
  common:    { min: 500,     max: 1_099 },
  uncommon:  { min: 1_100,   max: 2_649 },
  rare:      { min: 2_650,   max: 6_899 },
  epic:      { min: 6_900,   max: 19_499 },
  legendary: { min: 19_500,  max: 58_499 },
  mythic:    { min: 58_500,  max: 186_999 },
  secret:    { min: 187_000, max: 597_999 }
};

/**
 * Weighted mint roll (doc §2): pick a band segment by weight, then roll
 * uniformly inside it. Segments are fractions of the band width.
 */
export const MINT_SEGMENTS: { from: number; to: number; weight: number }[] = [
  { from: 0.0,  to: 0.4,  weight: 0.55 },
  { from: 0.4,  to: 0.7,  weight: 0.27 },
  { from: 0.7,  to: 0.9,  weight: 0.13 },
  { from: 0.9,  to: 0.98, weight: 0.04 },
  { from: 0.98, to: 1.0,  weight: 0.01 }
];

/**
 * Additive star bonuses to net worth (doc §2, frozen table).
 * ★2/★3/★4 = 15%/40%/75% of the band step; ★5 = step + ★2(next rarity);
 * Secret has ★2 only.
 */
export const SPEC_STAR_BONUS: Record<Rarity, Partial<Record<number, number>>> = {
  common:    { 1: 0, 2: 90,     3: 240,    4: 450,    5: 833 },
  uncommon:  { 1: 0, 2: 233,    3: 620,    4: 1_163,  5: 2_188 },
  rare:      { 1: 0, 2: 638,    3: 1_700,  4: 3_188,  5: 6_140 },
  epic:      { 1: 0, 2: 1_890,  3: 5_040,  4: 9_450,  5: 18_450 },
  legendary: { 1: 0, 2: 5_850,  3: 15_600, 4: 29_250, 5: 58_275 },
  mythic:    { 1: 0, 2: 19_275, 3: 51_400, 4: 96_375, 5: 190_150 },
  secret:    { 1: 0, 2: 61_650 }
};

/** Selling pays full Current Net Worth; Net Worth is not a combat stat. */
export const SELL_RATE = 1;

// ---------------------------------------------------------------------------
// §1 Scan pipeline: nutrition score -> rarity roll
// ---------------------------------------------------------------------------

/** Baseline rarity odds at NutritionScore 50 (doc §1). */
export const SCAN_BASE_ODDS: Record<Rarity, number> = {
  common: 0.80, uncommon: 0.16, rare: 0.032, epic: 0.0064,
  legendary: 0.00128, mythic: 0.000256, secret: 0.000064
};

/** rawWeight(r) = baseOdds(r) * exp(TILT * ((score-50)/50) * rarityIndex(r)). */
export const SCAN_RARITY_TILT = 0.8;

/**
 * NutritionScore component weights (doc §1). Each component is a 0..100
 * sub-score; missing fields redistribute weight across present components.
 *   ProteinScore = clamp(protein_g/25,0,1)*100        (per 100g/100mL)
 *   FiberScore   = clamp(fiber_g/10,0,1)*100
 *   SugarScore   = (1 - clamp(sugar_g/20,0,1))*100
 *   SodiumScore  = (1 - clamp((sodium_mg-50)/950,0,1))*100
 *   SatFatScore  = (1 - clamp((satFat_g-0.5)/9.5,0,1))*100
 */
export const NUTRITION_WEIGHTS = {
  protein: 0.25, fiber: 0.2, sugar: 0.25, sodium: 0.15, satFat: 0.15
} as const;

/** Combat-profile weights (doc §1) — a separate calc from the rarity roll. */
export const ATTACK_PROFILE_WEIGHTS = {
  protein: 0.4, carbEnergy: 0.25, calorieDensity: 0.2, fatEnergy: 0.15
} as const;
export const HEALTH_PROFILE_WEIGHTS = {
  fiber: 0.25, protein: 0.2, sugarQuality: 0.2, sodiumQuality: 0.2, satFatQuality: 0.15
} as const;

/** Barcode monsters always mint at ★1. One barcode mints once per user, ever. */
export const SCAN_MINT_STAR = 1;

// ---------------------------------------------------------------------------
// §3 Cookbooks
// ---------------------------------------------------------------------------

export interface CookbookSpec {
  id: string;
  name: string;
  /** Coin price. Target: price ≈ EV / 0.745 (~74% mean sell-back). */
  price: number;
  /** Published 7-tier Case odds; must sum to 1. No pity. */
  odds: Record<Rarity, number>;
}

export const COOKBOOKS: CookbookSpec[] = [
  {
    id: "home-cookbook",
    name: "Home Cookbook",
    price: 1_600,
    odds: { common: 0.80, uncommon: 0.16, rare: 0.032, epic: 0.0064,
            legendary: 0.00128, mythic: 0.000256, secret: 0.000064 }
  },
  {
    id: "chefs-cookbook",
    name: "Chef's Cookbook",
    price: 3_300,
    odds: { common: 0.55, uncommon: 0.28, rare: 0.12, epic: 0.04,
            legendary: 0.008, mythic: 0.0018, secret: 0.0002 }
  },
  {
    id: "master-cookbook",
    name: "Master Cookbook",
    price: 9_200,
    odds: { common: 0.20, uncommon: 0.35, rare: 0.25, epic: 0.14,
            legendary: 0.048, mythic: 0.011, secret: 0.001 }
  },
  {
    id: "forbidden-cookbook",
    name: "Forbidden Cookbook",
    price: 33_500,
    odds: { common: 0.0, uncommon: 0.10, rare: 0.25, epic: 0.35,
            legendary: 0.20, mythic: 0.095, secret: 0.005 }
  }
];

/** Cookbook Boost (doc §6): Rare+ weights ×1.15, renormalized to 100%. */
export const BOOST_RARE_PLUS_MULT = 1.15;
/** Rarities unaffected by a boost. */
export const BOOST_EXEMPT: Rarity[] = ["common", "uncommon"];

// ---------------------------------------------------------------------------
// §4 Battle system
// ---------------------------------------------------------------------------

export const TEAM_SIZE = 3;
/** Authored standard moves per character; Epic+ get 1 Special on top. */
export const STANDARD_MOVES_PER_CHARACTER = 3;

export const CRIT_CHANCE = 1 / 24; // ≈4.17%
export const CRIT_MULT = 1.5;
/** Uniform damage variance bounds. */
export const VARIANCE_MIN = 0.85;
export const VARIANCE_MAX = 1.0;
/** A successful damaging hit never deals less than this (checklist). */
export const MIN_DAMAGE = 1;
/** PvP first-turn coin flip. PvE: the human always opens. */
export const PVP_FIRST_TURN_P = 0.5;

// ---------------------------------------------------------------------------
// §5 Ranked / matchmaking / dungeon
// ---------------------------------------------------------------------------

export type Rank = "iron" | "bronze" | "silver" | "gold" | "platinum" | "diamond";

/** RR floors, ascending. 100-RR bands; Diamond begins at 500. */
export const RANKS: { rank: Rank; minRR: number }[] = [
  { rank: "iron", minRR: 0 },
  { rank: "bronze", minRR: 100 },
  { rank: "silver", minRR: 200 },
  { rank: "gold", minRR: 300 },
  { rank: "platinum", minRR: 400 },
  { rank: "diamond", minRR: 500 }
];

export const RR_WIN_BASE = 20;
export const RR_LOSS_BASE = -15;
/** Adjustment = clamp(round((OppRR - MyRR) / RR_ADJUST_STEP), ±RR_ADJUST_CAP). */
export const RR_ADJUST_STEP = 25;
export const RR_ADJUST_CAP = 5;
/** Eligible tasks: +5 RR each, +10/day cap, cannot cross into the next rank. */
export const TASK_RR_AMOUNT = 5;
export const TASK_RR_DAILY_CAP = 10;

/**
 * SBMM (doc §5):
 *   MonsterPower = EffectiveHealth + EffectiveAttack * SBMM_ATTACK_WEIGHT
 *   TeamGap%     = |A-B| / max(A,B)
 *   MatchScore   = |RRa-RRb|/100 + TeamGap%        (lower is better)
 * AttackWeight is a tuning constant — set once authored stat ranges land.
 */
export const SBMM_ATTACK_WEIGHT = 1.0;
export const SBMM_RR_SCALE = 100;

/** Ranked-win Case odds per current rank (doc §5). Each row sums to 1. */
export const RANKED_CASE_ODDS: Record<Rank, Record<Rarity, number>> = {
  iron:     { common: 0.75, uncommon: 0.18, rare: 0.05, epic: 0.016,
              legendary: 0.0032, mythic: 0.0007, secret: 0.0001 },
  bronze:   { common: 0.65, uncommon: 0.23, rare: 0.08, epic: 0.03,
              legendary: 0.008, mythic: 0.0018, secret: 0.0002 },
  silver:   { common: 0.52, uncommon: 0.28, rare: 0.13, epic: 0.05,
              legendary: 0.016, mythic: 0.0035, secret: 0.0005 },
  gold:     { common: 0.38, uncommon: 0.30, rare: 0.20, epic: 0.085,
              legendary: 0.027, mythic: 0.007, secret: 0.001 },
  platinum: { common: 0.24, uncommon: 0.28, rare: 0.27, epic: 0.14,
              legendary: 0.055, mythic: 0.013, secret: 0.002 },
  diamond:  { common: 0.15, uncommon: 0.25, rare: 0.30, epic: 0.20,
              legendary: 0.075, mythic: 0.0225, secret: 0.0025 }
};

/** Dungeon (doc §5): 3-monster run, endless floors, persistent HP. */
export const DUNGEON_TEAM_SIZE = 3;
/** EnemyMultiplier = 1 + DUNGEON_FLOOR_GROWTH * (floor - 1). */
export const DUNGEON_FLOOR_GROWTH = 0.05;
/** Boss every Nth floor; boss stats ×DUNGEON_BOSS_MULT on top of floor mult. */
export const DUNGEON_BOSS_EVERY = 5;
export const DUNGEON_BOSS_MULT = 1.25;
/** FloorReward = BASE + STEP*(floor-1) coins; boss floors ×BOSS_REWARD_MULT. */
export const DUNGEON_FLOOR_REWARD_BASE = 100;
export const DUNGEON_FLOOR_REWARD_STEP = 25;
export const DUNGEON_BOSS_REWARD_MULT = 3;

// ---------------------------------------------------------------------------
// §6 Player progression / tasks / streak
// ---------------------------------------------------------------------------

/** Daily tasks: 3/day (nutrition + battle + flex), 250 coins each, +500 for
 *  completing all three. Max 1,250 coins/day from tasks. */
export const TASKS_PER_DAY = 3;
export const TASK_REWARD_COINS = 250;
export const TASK_ALL_DONE_BONUS = 500;
export const TASK_DAILY_MAX =
  TASKS_PER_DAY * TASK_REWARD_COINS + TASK_ALL_DONE_BONUS;

/** Nutrition streak: one Cookbook Boost per 5 consecutive streak days. */
export const STREAK_BOOST_EVERY = 5;

/** Inventory: 200 unlocked monsters; overflow goes to a mailbox, never evicted
 *  or silently dropped (checklist). */
export const INVENTORY_CAP = 200;
