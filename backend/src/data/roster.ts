// The MVP roster (issue #92): 14 established characters, Pokédex-style.
//
// characters.json is the authored data; this module is the contract it has to
// satisfy. The schema runs at import time, so a roster with a missing bio, an
// illegal stat, or an element that disagrees with its own stat line fails at
// boot rather than halfway through a demo.
//
// Deliberately absent: base net worth. What a monster is worth is decided at
// mint time by its rarity band (game/rarityBands.ts) and the valuation work is
// still ahead; putting a price here now would create a second source of truth
// for exactly the thing the economy is being unified around.

import raw from "./characters.json";
import { z } from "zod";
import {
  STAT_ELEMENT,
  STAT_KEYS,
  baseStatsSchema,
  elementSchema,
  raritySchema
} from "../schemas/gameSchemas";
import { Rarity, StatType } from "../types";

/** How many characters the MVP roster is specified to contain. */
export const ROSTER_SIZE = 14;

export const rosterCharacterSchema = z.object({
  /** Stable key. Also the art seed and the image key, so it must never change. */
  id: z.string().regex(/^[a-z][a-z0-9-]{2,39}$/, "id must be lower-kebab-case"),
  name: z.string().min(2).max(40),
  rarity: raritySchema,
  element: elementSchema,
  colorHex: z.string().regex(/^#[0-9A-Fa-f]{6}$/),
  /** One line, shown on cards. */
  tagline: z.string().min(8).max(120),
  /** The Pokédex paragraph, shown on the character sheet. */
  bio: z.string().min(40).max(400),
  /** Resolves to art. Matches the checked-in asset name (issue #93). */
  imageKey: z.string().regex(/^[a-z][a-z0-9-]{2,39}$/),
  baseStats: baseStatsSchema
});

export const rosterSchema = z.object({
  version: z.number().int().positive(),
  characters: z.array(rosterCharacterSchema).length(ROSTER_SIZE)
});

export type RosterCharacter = z.infer<typeof rosterCharacterSchema>;

function loadRoster(): RosterCharacter[] {
  const parsed = rosterSchema.safeParse(raw);
  if (!parsed.success) {
    throw new Error(`characters.json is invalid: ${parsed.error.issues
      .map((issue) => `${issue.path.join(".")} ${issue.message}`)
      .join("; ")}`);
  }
  const characters = parsed.data.characters;

  const ids = new Set<string>();
  for (const character of characters) {
    if (ids.has(character.id)) throw new Error(`duplicate roster id '${character.id}'`);
    ids.add(character.id);

    // A character's element must be the one its own stat line implies, or the
    // Pokédex and the battle engine would disagree about what it is. Mirrors
    // element_from_stats() in SQL and elementFor() in game/baseStats.ts.
    const dominant = STAT_KEYS.reduce((best, key) =>
      character.baseStats[key] > character.baseStats[best] ? key : best
    );
    if (STAT_ELEMENT[dominant] !== character.element) {
      throw new Error(
        `${character.id} is element '${character.element}' but its highest stat is ` +
          `${dominant}, which is '${STAT_ELEMENT[dominant]}'`
      );
    }
  }

  return characters;
}

export const ROSTER: RosterCharacter[] = loadRoster();

export const ROSTER_BY_ID: Record<string, RosterCharacter> = Object.fromEntries(
  ROSTER.map((character) => [character.id, character])
);

export function rosterCharacter(id: string): RosterCharacter | undefined {
  return ROSTER_BY_ID[id];
}

/** Roster entries of one rarity, in authored order. */
export function rosterByRarity(rarity: Rarity): RosterCharacter[] {
  return ROSTER.filter((character) => character.rarity === rarity);
}

/** The roster entry as the rest of the backend's `Character` shape. */
export function asCharacter(entry: RosterCharacter) {
  return {
    id: entry.id,
    name: entry.name,
    colorHex: entry.colorHex,
    rarity: entry.rarity as Rarity,
    statType: entry.element as StatType,
    isLocked: false
  };
}
