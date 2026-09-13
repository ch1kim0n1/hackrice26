// Crate opening logic.
//
// Every outcome is derived from three inputs -- a server seed, a client seed and
// a nonce -- so it can be recomputed and checked afterwards. This is the
// "provably fair" scheme case-opening sites use, and it is the difference
// between a loot system players trust and one they merely tolerate.
//
//     roll(cursor) = HMAC_SHA256(serverSeed, `${clientSeed}:${nonce}:${cursor}`)
//
// The first 8 hex digits become a float in [0, 1). A distinct cursor per
// decision keeps the draws independent while staying reproducible.
//
// The server publishes SHA256(serverSeed) *before* any open and reveals the seed
// only when rotating it, so past rolls can be verified but never chosen.

import { createHash, createHmac, randomBytes } from "crypto";
import {
  BASE_VALUES,
  CHARACTERS,
  POWER_BANDS,
  RARITY_ORDER,
  RARITY_TIERS
} from "../data/lootTable";
import { Character, Crate, CrateOdds, DropRolls, PowerBand, Rarity } from "../types";
import { dropNetWorth } from "../game/rarityBands";
import { RankTier } from "../game/rankTiers";

/** What selection actually needs from a crate — key crates and coin-shop
 *  cases both satisfy it. */
export type CrateStock = Pick<Crate, "id" | "characterIds">;

/** One cursor per independent decision, so no two draws share a digest. */
export const CURSOR = {
  rarity: 0,
  character: 1,
  power: 2,
  shiny: 3,
  reelBase: 100
} as const;

export const SHINY_CHANCE = 0.1;
export const SHINY_MULTIPLIER = 2;

export const REEL_LENGTH = 60;
/** The reel scrolls past its tail and stops here. */
export const REEL_WINNER_INDEX = 55;

export function newServerSeed(): string {
  return randomBytes(32).toString("hex");
}

export function hashSeed(serverSeed: string): string {
  return createHash("sha256").update(serverSeed).digest("hex");
}

export function roll(
  serverSeed: string,
  clientSeed: string,
  nonce: number,
  cursor: number
): number {
  const digest = createHmac("sha256", serverSeed)
    .update(`${clientSeed}:${nonce}:${cursor}`)
    .digest("hex");
  return parseInt(digest.slice(0, 8), 16) / 0x1_0000_0000;
}

// ---------------------------------------------------------------------------
// Selection
// ---------------------------------------------------------------------------

// Crate composition never changes at runtime, so derive the tables once.
const weightsCache = new Map<string, Partial<Record<Rarity, number>>>();
const poolCache = new Map<string, Character[]>();

/**
 * Tier weights restricted to the tiers this crate actually stocks.
 *
 * A crate need not contain every tier. Renormalising over the tiers present
 * keeps the odds a true probability distribution, instead of silently losing the
 * missing tiers' share of the roll to whichever tier happens to be last.
 */
export function crateRarityWeights(crate: CrateStock): Partial<Record<Rarity, number>> {
  const cached = weightsCache.get(crate.id);
  if (cached) return cached;

  const present = new Set(crate.characterIds.map((id) => CHARACTERS[id].rarity));
  const weights: Partial<Record<Rarity, number>> = {};
  for (const rarity of RARITY_ORDER) {
    if (present.has(rarity)) weights[rarity] = RARITY_TIERS[rarity].weight;
  }
  weightsCache.set(crate.id, weights);
  return weights;
}

/** The crate's characters of one tier, in a stable order. */
export function cratePool(crate: CrateStock, rarity: Rarity): Character[] {
  const key = `${crate.id}:${rarity}`;
  const cached = poolCache.get(key);
  if (cached) return cached;

  const pool = crate.characterIds
    .map((id) => CHARACTERS[id])
    .filter((c) => c.rarity === rarity)
    .sort((a, b) => a.id.localeCompare(b.id));
  poolCache.set(key, pool);
  return pool;
}

/** Per-tier odds bonus on non-common pulls (issue #86): silver +25%, gold
 *  +50%, plat +75% weight on every tier above common. The common slice shrinks
 *  correspondingly after normalisation — pity is applied after this, so a
 *  forced epic/legendary still always wins. */
const RANK_ODDS_STEP: Record<RankTier, number> = { bronze: 0, silver: 0.25, gold: 0.5, plat: 0.75 };

export function rankScaledWeights(
  weights: Partial<Record<Rarity, number>>,
  tier: RankTier
): Partial<Record<Rarity, number>> {
  const boost = RANK_ODDS_STEP[tier];
  if (!boost) return weights;
  const out: Partial<Record<Rarity, number>> = {};
  for (const [rarity, w] of Object.entries(weights) as [Rarity, number][]) {
    out[rarity] = rarity === "common" ? w : w * (1 + boost);
  }
  return out;
}

/**
 * Walk the cumulative weights from rarest to most common.
 *
 * Rarest first is deliberate: it puts the tiny intervals at the bottom of the
 * range, where they cannot be swallowed by floating point noise in a much wider
 * band sitting ahead of them.
 */
export function pickRarity(crate: CrateStock, value: number, tier?: RankTier): Rarity {
  const weights = tier ? rankScaledWeights(crateRarityWeights(crate), tier) : crateRarityWeights(crate);
  const entries = (Object.entries(weights) as [Rarity, number][]).sort(
    (a, b) => a[1] - b[1]
  );
  const total = entries.reduce((sum, [, w]) => sum + w, 0);
  const target = value * total;

  let cumulative = 0;
  for (const [rarity, weight] of entries) {
    cumulative += weight;
    if (target < cumulative) return rarity;
  }
  return entries[entries.length - 1][0]; // unreachable but for rounding
}

/** Uniform pick among the crate's characters of that tier. */
export function pickCharacter(crate: CrateStock, rarity: Rarity, value: number): Character {
  const pool = cratePool(crate, rarity);
  return pool[Math.min(Math.floor(value * pool.length), pool.length - 1)];
}

export function powerBandFor(power: number): PowerBand {
  return (
    POWER_BANDS.find((b) => power >= b.min && power < b.max) ??
    POWER_BANDS[POWER_BANDS.length - 1]
  );
}

// ---------------------------------------------------------------------------
// Opening
// ---------------------------------------------------------------------------

// Pity guarantees (game/pity.ts): an Epic-or-better pull is guaranteed on the
// 15th consecutive open without one, Legendary-or-better on the 40th.
export const EPIC_PITY = 15;
export const LEGENDARY_PITY = 40;

/** Rarity rank in the crate ladder — pity only ever upgrades, never downgrades. */
const TIER_RANK: Record<Rarity, number> = {
  common: 0, uncommon: 1, rare: 2, epic: 3, legendary: 4, mythic: 5, secret: 6
};

export interface PityState {
  sinceEpic: number;
  sinceLegendary: number;
}

/**
 * Apply pity to a rolled rarity. Deterministic given the counters, which the
 * API discloses — the roll still happened (see `rolls`), pity just lifts the
 * tier when the guarantee comes due. Returns the forced tier, if any.
 */
export function applyPity(
  crate: CrateStock,
  rolled: Rarity,
  pity: PityState
): { rarity: Rarity; forced: "epic" | "legendary" | null } {
  const stocked = new Set(crate.characterIds.map((id) => CHARACTERS[id].rarity));
  let rarity = rolled;
  let forced: "epic" | "legendary" | null = null;

  if (pity.sinceLegendary + 1 >= LEGENDARY_PITY && TIER_RANK[rarity] < TIER_RANK.legendary) {
    const target: Rarity = stocked.has("legendary") ? "legendary"
      : stocked.has("mythic") ? "mythic"
      : "secret";
    rarity = target;
    forced = "legendary";
  } else if (pity.sinceEpic + 1 >= EPIC_PITY && TIER_RANK[rarity] < TIER_RANK.epic) {
    rarity = "epic";
    forced = "epic";
  }
  return { rarity, forced };
}

/** Advance pity counters after an open resolves at `rarity`. */
export function advancePity(pity: PityState, rarity: Rarity): PityState {
  return {
    sinceEpic: TIER_RANK[rarity] >= TIER_RANK.epic ? 0 : pity.sinceEpic + 1,
    sinceLegendary: TIER_RANK[rarity] >= TIER_RANK.legendary ? 0 : pity.sinceLegendary + 1
  };
}

export interface OpenOutcome {
  character: Character;
  power: number;
  powerLabel: string;
  shiny: boolean;
  value: number;
  rolls: DropRolls;
  /** Set when pity overrode the rolled tier — disclosed so the open stays auditable. */
  pityForced: "epic" | "legendary" | null;
  reel: string[];
  reelWinnerIndex: number;
  openedAt: string;
}

/** Resolve one open. Pure: the same seeds and nonce always give this result. */
export function openCrate(
  crate: CrateStock,
  serverSeed: string,
  clientSeed: string,
  nonce: number,
  pity?: PityState,
  rankTier?: RankTier
): OpenOutcome {
  const rarityRoll = roll(serverSeed, clientSeed, nonce, CURSOR.rarity);
  const characterRoll = roll(serverSeed, clientSeed, nonce, CURSOR.character);
  const powerRoll = roll(serverSeed, clientSeed, nonce, CURSOR.power);
  const shinyRoll = roll(serverSeed, clientSeed, nonce, CURSOR.shiny);

  const rolled = pickRarity(crate, rarityRoll, rankTier);
  const { rarity, forced } = pity ? applyPity(crate, rolled, pity) : { rarity: rolled, forced: null };
  const character = pickCharacter(crate, rarity, characterRoll);
  const power = Math.round(powerRoll * 1000) / 10; // 0.0 - 100.0
  const band = powerBandFor(power);
  const shiny = shinyRoll < SHINY_CHANCE;

  // Net worth is the rarity's band floor plus however far the power roll and
  // the holo carry it up that band -- never past it (game/rarityBands.ts).
  const value = dropNetWorth(rarity, band.valueMultiplier, shiny);

  return {
    character,
    power,
    powerLabel: band.label,
    shiny,
    value,
    rolls: {
      rarity: rarityRoll,
      character: characterRoll,
      power: powerRoll,
      shiny: shinyRoll
    },
    pityForced: forced,
    reel: buildReel(crate, character, serverSeed, clientSeed, nonce),
    reelWinnerIndex: REEL_WINNER_INDEX,
    openedAt: new Date().toISOString()
  };
}

/**
 * The strip of characters the UI scrolls past before stopping on the winner.
 * Cosmetic, but generated from the same seed chain, so replaying an open
 * reproduces the exact animation and not merely the result.
 */
export function buildReel(
  crate: CrateStock,
  winner: Character,
  serverSeed: string,
  clientSeed: string,
  nonce: number
): string[] {
  const reel: string[] = [];
  for (let slot = 0; slot < REEL_LENGTH; slot++) {
    if (slot === REEL_WINNER_INDEX) {
      reel.push(winner.id);
      continue;
    }
    const rarity = pickRarity(crate, roll(serverSeed, clientSeed, nonce, CURSOR.reelBase + slot));
    const filler = roll(serverSeed, clientSeed, nonce, CURSOR.reelBase + slot + REEL_LENGTH);
    reel.push(pickCharacter(crate, rarity, filler).id);
  }
  return reel;
}

/** Per-character drop chance, so the UI can show real numbers rather than vibes. */
export function crateOdds(crate: CrateStock): CrateOdds[] {
  const weights = crateRarityWeights(crate);
  const total = Object.values(weights).reduce((sum, w) => sum + (w ?? 0), 0);

  return (Object.entries(weights) as [Rarity, number][])
    .map(([rarity, weight]) => {
      const pool = cratePool(crate, rarity);
      const tierChance = weight / total;
      return {
        rarity,
        label: RARITY_TIERS[rarity].label,
        colorHex: RARITY_TIERS[rarity].colorHex,
        tierChance,
        oneIn: Math.round(total / weight),
        characterCount: pool.length,
        perCharacterChance: pool.length ? tierChance / pool.length : 0
      };
    })
    .sort((a, b) => b.tierChance - a.tierChance);
}

// ---------------------------------------------------------------------------
// Coin-shop cases
// ---------------------------------------------------------------------------

/**
 * Resolve one coin-shop case open the Loot-Boxes-Logic branch's way: the plain
 * weighted roll over the case's stocked tiers (no pity, no rank boost), the
 * same seed chain and reel, and value from BASE_VALUES × power band × shiny
 * instead of the rarity bands key crates use.
 */
export function openShopCase(
  crate: CrateStock,
  serverSeed: string,
  clientSeed: string,
  nonce: number
): OpenOutcome {
  const outcome = openCrate(crate, serverSeed, clientSeed, nonce);
  const band = powerBandFor(outcome.power);
  return {
    ...outcome,
    value: Math.round(
      BASE_VALUES[outcome.character.rarity] * band.valueMultiplier * (outcome.shiny ? SHINY_MULTIPLIER : 1)
    )
  };
}

/** Mean power-band value multiplier over a uniform 0-100 power roll. */
function expectedPowerMultiplier(): number {
  return POWER_BANDS.reduce((sum, band) => {
    const width = Math.min(band.max, 100) - Math.max(band.min, 0);
    return sum + (width / 100) * band.valueMultiplier;
  }, 0);
}

/**
 * The house margin on a shop case. At exactly expected value a case is a
 * coin-neutral slot machine — buy at EV, sell the drop back at full worth,
 * repeat forever with free upside. A 15% overround keeps the shop a sink.
 */
export const SHOP_CASE_MARGIN = 1.15;

/**
 * A case's coin price: what its drop is worth on average (tier odds ×
 * BASE_VALUES × expected power multiplier × expected shiny multiplier) plus
 * the house margin, rounded up to the next 10. Derived rather than hand-set,
 * so a pricier case costs more exactly because its odds are better, and
 * editing BASE_VALUES or the odds re-prices the shop with it.
 */
export function shopCaseCoinCost(crate: CrateStock): number {
  const shinyMultiplier = 1 + SHINY_CHANCE * (SHINY_MULTIPLIER - 1);
  const expected =
    crateOdds(crate).reduce((sum, odds) => sum + odds.tierChance * BASE_VALUES[odds.rarity], 0) *
    expectedPowerMultiplier() *
    shinyMultiplier *
    SHOP_CASE_MARGIN;
  return Math.ceil(expected / 10) * 10;
}
