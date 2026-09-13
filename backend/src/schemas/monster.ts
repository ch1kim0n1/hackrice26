// ============================================================================
// MONSTER CONTRACT — Phase 0 (final-dev-doc.pdf is ground truth)
//
// The shapes every workstream builds against. Two layers:
//
//   CatalogCharacter — the authored design (one of the 14). Immutable id,
//   base Health/Attack, authored moves, optional Mana Special. No element,
//   no type, no 4-stat blob.
//
//   MonsterInstance — one owned monster. Carries its OWN base combat stats
//   (copied from the catalog for cases, generated from nutrition for scans —
//   acquisition source gives no combat edge, doc checklist), its rarity,
//   stars, and its permanent baseMintValue. Net worth is derived:
//
//       netWorth = baseMintValue + starBonus(rarity, stars)
//       effectiveHealth = baseHealth * rarityMult * starCombatMult
//       effectiveAttack = baseAttack * rarityMult * starCombatMult
//       startingMana    = floor(baseMana * starManaMult)   (Epic+ only)
//
// These schemas describe the NEW model. Existing code keeps its old shapes
// until its owning workstream migrates it — nothing here is wired in yet.
// ============================================================================

import { z } from "zod";
import { raritySchema } from "./gameSchemas";
import { hasMana, maxStarsFor } from "../game/spec";

// ---------------------------------------------------------------------------
// Moves (doc §4)
// ---------------------------------------------------------------------------

/**
 * Authored status/effect identifier. Free-form for now — the battle
 * workstream defines the concrete effect set; catalog entries reference ids.
 * Examples: "burn", "stun", "atk_down", "heal_over_time", "mana_drain".
 */
export const statusEffectSchema = z.string().min(1).max(40);

export const moveSchema = z.object({
  id: z.string().regex(/^[a-z][a-z0-9-]{2,39}$/, "move id must be lower-kebab-case"),
  name: z.string().min(2).max(48),
  /** Damage multiplier feeding BaseDamage = (power * EffectiveAttack)/Scale + 2.
   *  0 for pure status/utility moves. */
  power: z.number().min(0).max(10),
  /** Hit chance in percent, 1..100. A miss deals 0 damage and skips
   *  hit-dependent statuses. */
  accuracy: z.number().min(1).max(100),
  statusEffect: statusEffectSchema.optional(),
  /** P(status | hit) in percent. Applied chance = accuracy/100 * statusChance/100. */
  statusChance: z.number().min(0).max(100).optional(),
  /** Status duration in turns, when the effect is timed. */
  duration: z.number().int().min(1).max(10).optional(),
  /** Mana spent on use. 0 for standard moves; >0 on Specials. */
  manaCost: z.number().int().min(0).default(0),
  /** Flavour text for the UI. */
  description: z.string().max(160).optional()
});

export type MoveDef = z.infer<typeof moveSchema>;

// ---------------------------------------------------------------------------
// Catalog character (doc §2 + checklist "master authored-character catalog")
// ---------------------------------------------------------------------------

/**
 * The catalog shape BEFORE cross-field refinement, exported so callers that
 * need `.extend()` (e.g. data/roster.ts) can build on it — zod refinements
 * return ZodEffects, which cannot be extended.
 */
export const catalogCharacterObjectSchema = z.object({
  /** Permanent internal id. Never derived from the display name; renaming
   *  must not change any reference. */
  id: z.string().regex(/^[a-z][a-z0-9-]{2,39}$/, "id must be lower-kebab-case"),
  name: z.string().min(2).max(40),
  colorHex: z.string().regex(/^#[0-9A-Fa-f]{6}$/),
  /** Art lookup key (checked-in asset name). */
  imageKey: z.string().regex(/^[a-z][a-z0-9-]{2,39}$/),
  tagline: z.string().min(8).max(120).optional(),
  /** Optional short lore/description field. */
  bio: z.string().min(40).max(400).optional(),
  baseHealth: z.number().int().min(1).max(10_000),
  baseAttack: z.number().int().min(1).max(10_000),
  /** Base Mana. Required iff the character has a Special (Epic+ playstyle);
   *  monsters below Epic never carry Mana even if the catalog lists it. */
  baseMana: z.number().int().min(1).max(1_000).optional(),
  /** Exactly 3 authored standard moves. No Mana cost. */
  moves: z.array(moveSchema.refine((m) => m.manaCost === 0, {
    message: "standard moves do not consume Mana"
  })).length(3),
  /** The one authored Mana Special. Present only on characters intended for
   *  Epic+; requires baseMana and a manaCost > 0. */
  special: moveSchema.optional(),
  /** Optional rarity whitelist. Omit = droppable at any rarity. */
  rarityEligibility: z.array(raritySchema).min(1).optional()
});

export const catalogCharacterSchema = catalogCharacterObjectSchema.superRefine((c, ctx) => {
  if (c.special) {
    if (!c.baseMana) {
      ctx.addIssue({ code: z.ZodIssueCode.custom, message: "special requires baseMana", path: ["special"] });
    }
    if (c.special.manaCost <= 0) {
      ctx.addIssue({ code: z.ZodIssueCode.custom, message: "special must have manaCost > 0", path: ["special", "manaCost"] });
    }
  }
});

export type CatalogCharacter = z.infer<typeof catalogCharacterSchema>;

// ---------------------------------------------------------------------------
// Monster instance (owned drop)
// ---------------------------------------------------------------------------

/** Where a monster came from. Cosmetic for combat (source-neutral), real for
 *  provenance, anti-cheat and analytics. */
export const mintSourceSchema = z.enum([
  "scan",        // barcode mint — the only user food input that mints
  "cookbook",    // cookbook -> rarity case -> monster
  "ranked_case", // ranked win reward case
  "fusion",      // merged up from 3 copies
  "starter",     // starting roster grant
  "casino",      // minigame reward
  "reward"       // any other system-granted monster
]);
export type MintSource = z.infer<typeof mintSourceSchema>;

export const monsterInstanceSchema = z.object({
  /** Per-instance uuid. Two copies of the same character are two monsters. */
  id: z.string().uuid(),
  /** Catalog/character-design id this instance is based on. */
  characterId: z.string().min(1).max(64),
  rarity: raritySchema,
  /** 1..5; Secret instances never exceed 2 (see maxStarsFor). */
  stars: z.number().int().min(1).max(5),
  /** The instance's own combat base — generated (scan) or catalog-derived
   *  (case). Stored per instance so combat never reads acquisition source. */
  baseHealth: z.number().int().min(1),
  baseAttack: z.number().int().min(1),
  /** Present only on Epic+ instances. */
  baseMana: z.number().int().min(1).optional(),
  /** Permanent lineage value inside the rarity band (weighted segment roll).
   *  Fusion keeps the highest among consumed copies. */
  baseMintValue: z.number().int().min(0),
  source: mintSourceSchema,
  /** ISO 8601. */
  mintedAt: z.string(),
  /** Barcode-scan provenance (checklist): barcode + the nutrition snapshot
   *  actually used for generation + the data source. Only for source=scan. */
  provenance: z.object({
    barcode: z.string(),
    nutrition: z.record(z.number()),
    nutritionSource: z.string()
  }).optional()
}).superRefine((m, ctx) => {
  if (m.stars > maxStarsFor(m.rarity)) {
    ctx.addIssue({ code: z.ZodIssueCode.custom, message: `${m.rarity} cannot exceed ${maxStarsFor(m.rarity)} stars`, path: ["stars"] });
  }
  if (!hasMana(m.rarity) && m.baseMana !== undefined) {
    ctx.addIssue({ code: z.ZodIssueCode.custom, message: "only Epic+ monsters carry Mana", path: ["baseMana"] });
  }
  if (m.source === "scan" && !m.provenance) {
    ctx.addIssue({ code: z.ZodIssueCode.custom, message: "scan mints must store barcode + nutrition provenance", path: ["provenance"] });
  }
});

export type MonsterInstance = z.infer<typeof monsterInstanceSchema>;
