// The master authored-character catalog — the spec §2 "master catalog with
// immutable IDs" contract — enforced at import time so a malformed
// characters.json fails the boot, not the user.
//
// The schema this enforces (schemas/monster.ts catalogCharacterSchema, plus
// the roster-local rules below):
//   - `id` is permanent and independent of the display name: lower-kebab,
//     unique, and carried verbatim through the API and DB so a rename is
//     always cosmetic (immutable-ID requirement).
//   - Combat stats are `baseHealth` + `baseAttack` + `baseMana` and nothing
//     else: there is no `element`, no four-stat `baseStats` blob, and no
//     `statType` anywhere in the catalog.
//   - There is no `rarity` on a catalog entry. Rarity is rolled per monster
//     instance at mint (NutritionScore roll for barcodes, cookbook table for
//     crates) — a character design is never intrinsically rare.
//   - Every character embeds exactly 3 authored standard moves and one Mana
//     Special (move shape: schemas/monster.ts moveSchema); `special` +
//     `baseMana` only come into play when the monster instance is Epic+.
//   - `imageKey` names the sprite set under public/monster/ (see
//     characterArt.ts) and `bio`/`tagline` are the lore fields.

import { z } from "zod";
import fs from "fs";
import path from "path";
import { Character, Rarity } from "../types";
import { catalogCharacterObjectSchema } from "../schemas/monster";
import { hasMana } from "../game/spec";

/**
 * The catalog schema is the shared contract; the roster adds the two rules
 * that are this file's job rather than the protocol's: lore is mandatory
 * (not optional) and authored stats sit inside the sane design envelope.
 */
export const rosterCharacterSchema = catalogCharacterObjectSchema.extend({
  // Re-applied manually below: extend() is only legal on the unrefined
  // object, so the special->baseMana rule is re-checked after extension.
  tagline: z.string().min(1).max(80),
  bio: z.string().min(10).max(500),
  baseHealth: z.number().int().min(40).max(200),
  baseAttack: z.number().int().min(20).max(100),
  baseMana: z.number().int().min(40).max(200)
}).superRefine((c, ctx) => {
  if (c.special && !c.baseMana) {
    ctx.addIssue({ code: z.ZodIssueCode.custom, message: "special requires baseMana", path: ["special"] });
  }
});

export type RosterCharacter = z.infer<typeof rosterCharacterSchema>;

interface RosterFile {
  characters: unknown[];
}

function loadRoster(): RosterCharacter[] {
  const file = path.join(__dirname, "characters.json");
  const raw = JSON.parse(fs.readFileSync(file, "utf8")) as RosterFile;
  const parsed = raw.characters.map((entry, index) => {
    const result = rosterCharacterSchema.safeParse(entry);
    if (!result.success) {
      const issues = result.error.issues.map((i) => `${i.path.join(".")}: ${i.message}`).join("; ");
      throw new Error(`characters.json entry ${index}: ${issues}`);
    }
    return result.data;
  });

  const seen = new Set<string>();
  for (const character of parsed) {
    if (seen.has(character.id)) {
      throw new Error(`duplicate roster id '${character.id}'`);
    }
    seen.add(character.id);
  }
  return parsed;
}

export const ROSTER: RosterCharacter[] = loadRoster();
export const ROSTER_SIZE = ROSTER.length;

export function rosterCharacter(id: string): RosterCharacter | undefined {
  return ROSTER.find((c) => c.id === id);
}

export function isRosterCharacterId(id: string): boolean {
  return rosterCharacter(id) !== undefined;
}

/**
 * A minted monster's identity view of a catalog entry: the same shape the
 * API serves for owned instances. `rarity` lives on the instance, never the
 * design — callers pass the rolled rarity in. The instance's combat base is
 * the catalog's by default; barcode mints may override baseHealth/baseAttack
 * with their nutrition-derived profile via `stats` (source-neutral combat:
 * the monster fights on its stored numbers, not on where it came from).
 */
export function asCharacter(
  entry: RosterCharacter,
  rarity: Rarity,
  stats?: { baseHealth: number; baseAttack: number }
): Character {
  return {
    id: entry.id,
    name: entry.name,
    colorHex: entry.colorHex,
    imageKey: entry.imageKey,
    tagline: entry.tagline,
    bio: entry.bio,
    rarity,
    baseHealth: stats?.baseHealth ?? entry.baseHealth,
    baseAttack: stats?.baseAttack ?? entry.baseAttack,
    // Only Epic+ instances carry Mana — the catalog always lists it because
    // any design can mint at Epic+.
    ...(hasMana(rarity) ? { baseMana: entry.baseMana } : {}),
    moves: entry.moves.map((m) => m.id),
    ...(hasMana(rarity) && entry.special ? { special: entry.special.id } : {}),
    isLocked: false
  };
}

// --- Invariants: hard errors at import, not lint warnings -------------------

if (ROSTER_SIZE !== 14) {
  throw new Error(`catalog must hold exactly 14 characters (spec §2), has ${ROSTER_SIZE}`);
}

for (const character of ROSTER) {
  const moveIds = new Set(character.moves.map((m) => m.id));
  if (moveIds.size !== 3) {
    throw new Error(`${character.id} has duplicate standard-move ids`);
  }
  for (const move of character.moves) {
    if (!move.id.startsWith(`${character.id}-`)) {
      throw new Error(`${character.id} move '${move.id}' is not namespaced to its owner`);
    }
    if (move.statusChance !== undefined && move.statusEffect === undefined) {
      throw new Error(`${character.id} move '${move.id}' has statusChance without statusEffect`);
    }
  }
  if (!character.special) {
    throw new Error(`${character.id} must author a Mana Special`);
  }
  if (!character.special.id.startsWith(`${character.id}-`)) {
    throw new Error(`${character.id} special '${character.special.id}' is not namespaced to its owner`);
  }
}
