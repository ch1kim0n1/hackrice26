// Cookbook / Case opening logic.
//
// Every outcome is derived from three inputs -- a server seed, a client seed and
// a nonce -- so it can be recomputed and checked afterwards. This is the
// "provably fair" scheme case-opening sites use, and it is the difference
// between a loot system players trust and one they merely tolerate.
//
//     roll(cursor) = HMAC_SHA256(serverSeed, `${clientSeed}:${nonce}:${cursor}`)
//
// The first 8 hex digits become a float in [0, 1). A distinct cursor per
// decision keeps the draws independent while staying reproducible. No roll is
// ever turned into an integer via `% N` — that would bias toward low indices
// when N doesn't divide 2^32. Indices come from floor(unit * N), which is
// unbiased for a uniform unit.
//
// The server publishes SHA256(serverSeed) *before* any open and reveals the seed
// only when rotating it, so past rolls can be verified but never chosen.

import { createHash, createHmac, randomBytes } from "crypto";
import {
  COOKBOOK_BY_ID,
  RARITY_ORDER,
  RARITY_TIERS,
  mintPool
} from "../data/lootTable";
import { RosterCharacter, asCharacter } from "../data/roster";
import { Character, Cookbook, CrateOdds, DropRolls, Rarity } from "../types";
import { mintValue } from "../game/rarityBands";
import { BOOST_EXEMPT, BOOST_RARE_PLUS_MULT } from "../game/spec";

/** One cursor per independent decision, so no two draws share a digest. */
export const CURSOR = {
  rarity: 0,
  character: 1,
  mintSegment: 2,
  mintPosition: 3,
  reelBase: 100
} as const;

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

/**
 * Pick a rarity off a probability table (a Cookbook's published odds, or a
 * fixed-rarity Case's degenerate table). Rarest first: the tiny intervals sit
 * at the bottom of the range where floating-point noise in a wide band ahead
 * of them cannot swallow them.
 */
/**
 * A Cookbook Boost's odds table (spec §6): Rare-and-above weights ×1.15,
 * renormalized to sum to 1. Common/Uncommon are exempt — the boost pushes
 * probability mass at the top of the ladder, exactly once.
 */
export function boostedOdds(odds: Partial<Record<Rarity, number>>): Partial<Record<Rarity, number>> {
  const scaled = Object.fromEntries(
    RARITY_ORDER.map((rarity) => [
      rarity,
      (odds[rarity] ?? 0) * (BOOST_EXEMPT.includes(rarity) ? 1 : BOOST_RARE_PLUS_MULT)
    ])
  ) as Record<Rarity, number>;
  const total = RARITY_ORDER.reduce((sum, r) => sum + scaled[r], 0);
  if (total <= 0) return { ...odds };
  return Object.fromEntries(RARITY_ORDER.map((r) => [r, scaled[r] / total]));
}

export function pickRarity(odds: Partial<Record<Rarity, number>>, value: number): Rarity {
  const entries = RARITY_ORDER
    .map((rarity) => [rarity, odds[rarity] ?? 0] as [Rarity, number])
    .filter(([, w]) => w > 0)
    .sort((a, b) => a[1] - b[1]);
  const total = entries.reduce((sum, [, w]) => sum + w, 0);
  const target = Math.min(Math.max(value, 0), 1 - Number.EPSILON) * total;

  let cumulative = 0;
  for (const [rarity, weight] of entries) {
    cumulative += weight;
    if (target < cumulative) return rarity;
  }
  return entries[entries.length - 1][0]; // unreachable but for rounding
}

/**
 * Uniform pick of a character *design* from the rolled rarity's pool.
 * Rarity lives on the instance, not the design — the same roll unit picks
 * the design, and the caller stamps the rolled rarity onto it via
 * asCharacter(). Secret pools are the brainrot set.
 */
export function pickDesign(value: number, rarity: Rarity): RosterCharacter {
  const pool = mintPool(rarity);
  return pool[Math.min(Math.floor(value * pool.length), pool.length - 1)];
}

// ---------------------------------------------------------------------------
// Opening
// ---------------------------------------------------------------------------

export interface OpenOutcome {
  character: Character;
  /** Rarity of the Case this mint came out of. */
  caseRarity: Rarity;
  baseMintValue: number;
  value: number;
  rolls: DropRolls;
  /** The reel's cosmetic filler — monster instances with their rolled rarity. */
  reel: Character[];
  reelWinnerIndex: number;
  openedAt: string;
}

interface SeedPair {
  serverSeed: string;
  clientSeed: string;
}

/**
 * Mint a ★1 monster of a known rarity — the second half of every container
 * open, shared by Cookbooks and granted Cases.
 */
function mintMonster(
  sourceId: string,
  rarity: Rarity,
  pair: SeedPair,
  nonce: number,
  rarityRoll: number,
  reelOdds: Partial<Record<Rarity, number>>
): OpenOutcome {
  const characterRoll = roll(pair.serverSeed, pair.clientSeed, nonce, CURSOR.character);
  const segmentRoll = roll(pair.serverSeed, pair.clientSeed, nonce, CURSOR.mintSegment);
  const positionRoll = roll(pair.serverSeed, pair.clientSeed, nonce, CURSOR.mintPosition);

  const character = asCharacter(pickDesign(characterRoll, rarity), rarity);
  const baseMintValue = mintValue(rarity, segmentRoll, positionRoll);

  return {
    character,
    caseRarity: rarity,
    baseMintValue,
    value: baseMintValue, // fresh mints are ★1: star bonus is 0
    rolls: {
      rarity: rarityRoll,
      character: characterRoll,
      mintSegment: segmentRoll,
      mintPosition: positionRoll
    },
    reel: buildReel(reelOdds, character, pair.serverSeed, pair.clientSeed, nonce),
    reelWinnerIndex: REEL_WINNER_INDEX,
    openedAt: new Date().toISOString()
  };
}

/**
 * Resolve one Cookbook open (spec §3): the rarity roll picks which Case the
 * book produced, then a monster of that rarity mints. Pure: same seeds and
 * nonce always give this result.
 */
export function openCookbook(
  book: Cookbook,
  serverSeed: string,
  clientSeed: string,
  nonce: number,
  /** Cookbook Boost table — pass boostedOdds(book.odds) when a boost was
   *  consumed for this open. Defaults to the book's published odds. */
  odds: Partial<Record<Rarity, number>> = book.odds
): OpenOutcome {
  const rarityRoll = roll(serverSeed, clientSeed, nonce, CURSOR.rarity);
  const rarity = pickRarity(odds, rarityRoll);
  return mintMonster(book.id, rarity, { serverSeed, clientSeed }, nonce, rarityRoll, odds);
}

/**
 * Resolve a granted Case (ranked win, promo): the rarity is already decided,
 * the roll chain still mints character + net worth. The `rarity` roll is
 * recorded as 1.0 — no rarity was rolled — so verification stays honest.
 */
export function openCaseRarity(
  rarity: Rarity,
  serverSeed: string,
  clientSeed: string,
  nonce: number
): OpenOutcome {
  return mintMonster(
    `case:${rarity}`,
    rarity,
    { serverSeed, clientSeed },
    nonce,
    1,
    { [rarity]: 1 }
  );
}

/**
 * The strip of characters the UI scrolls past before stopping on the winner.
 * Cosmetic, but generated from the same seed chain, so replaying an open
 * reproduces the exact animation and not merely the result.
 */
export function buildReel(
  odds: Partial<Record<Rarity, number>>,
  winner: Character,
  serverSeed: string,
  clientSeed: string,
  nonce: number
): Character[] {
  const reel: Character[] = [];
  for (let slot = 0; slot < REEL_LENGTH; slot++) {
    if (slot === REEL_WINNER_INDEX) {
      reel.push(winner);
      continue;
    }
    const rarity = pickRarity(odds, roll(serverSeed, clientSeed, nonce, CURSOR.reelBase + slot));
    const filler = roll(serverSeed, clientSeed, nonce, CURSOR.reelBase + slot + REEL_LENGTH);
    reel.push(asCharacter(pickDesign(filler, rarity), rarity));
  }
  return reel;
}

/** Per-tier and per-character odds for a Cookbook — real numbers for the UI. */
export function cookbookOdds(book: Cookbook): CrateOdds[] {
  return RARITY_ORDER
    .filter((rarity) => (book.odds[rarity] ?? 0) > 0)
    .map((rarity) => {
      const tierChance = book.odds[rarity];
      const designCount = mintPool(rarity).length;
      return {
        rarity,
        label: RARITY_TIERS[rarity].label,
        colorHex: RARITY_TIERS[rarity].colorHex,
        tierChance,
        oneIn: Math.round(1 / tierChance),
        characterCount: designCount,
        perCharacterChance: tierChance / designCount
      };
    })
    .sort((a, b) => b.tierChance - a.tierChance);
}

/** Look a Cookbook up by id — undefined if the id is not one of the four. */
export function cookbookFor(id: string): Cookbook | undefined {
  return COOKBOOK_BY_ID[id];
}
