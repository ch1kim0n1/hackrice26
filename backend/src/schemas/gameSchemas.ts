// Zod request validators for the Postgres-backed game routes
// (docs/CONVENTIONS.md: "Zod-validate every body"). player_id is ALWAYS taken
// from the verified JWT (req.playerId), never accepted from these bodies.

import { z } from "zod";

const uuid = z.string().uuid();

export const profileUpsertSchema = z.object({
  age: z.number().int().min(10).max(100),
  sex: z.enum(["male", "female"]),
  heightCm: z.number().min(80).max(260),
  weightKg: z.number().min(25).max(400),
  activity: z.enum(["sedentary", "light", "moderate", "active"]),
  goal: z.enum(["cut", "maintain", "bulk"])
});

export const scanSchema = z.object({
  barcode: z.string().min(4).max(64).regex(/^[0-9A-Za-z_-]+$/)
});

// --- Meal log (spec §1: barcode / photo / manual intake) ---------------------
//
// The dashboard contract is kcal/protein/carbs/fat; the wider nutrient fields
// are optional provenance. A manual entry is a log, never a mint — nothing
// here can create a monster.

const mealNutrient = z.number().min(0).max(10_000);

export const manualMealSchema = z.object({
  name: z.string().min(1).max(120),
  calories: mealNutrient,
  proteinG: mealNutrient,
  carbsG: mealNutrient,
  fatG: mealNutrient,
  fiberG: mealNutrient.optional(),
  sugarG: mealNutrient.optional(),
  sodiumMg: mealNutrient.optional(),
  satFatG: mealNutrient.optional()
});

export const mealEditSchema = z
  .object({
    name: z.string().min(1).max(120).optional(),
    calories: mealNutrient.optional(),
    proteinG: mealNutrient.optional(),
    carbsG: mealNutrient.optional(),
    fatG: mealNutrient.optional()
  })
  .refine((e) => Object.values(e).some((v) => v !== undefined), {
    message: "at least one field to edit is required"
  });

export const fusionSchema = z.object({
  // Spec §2: fusion consumes exactly 3 copies.
  consumedIds: z.array(uuid).length(3)
});

export const rankedBattleSchema = z.object({
  // client sends only character IDs; the backend rebuilds squads from the DB
  squad: z.array(uuid).length(3),
  opponentId: uuid.optional()
});

export const arenaCreateSchema = z.object({
  opponentId: uuid,
  squad: z.array(uuid).length(3),
  stake: z.number().int().min(1).max(10)
});

export const capsuleOpenSchema = z.object({
  // optional idempotency key; the backend generates one if absent
  openId: z.string().min(8).max(64).optional()
});

/** Shared by cookbook opens and case opens: the player's commit-reveal entropy. */
export const clientSeedBodySchema = z.object({
  clientSeed: z.string().min(6).max(64).optional()
});

/** POST /lootbox/mailbox/claim — which overflow drops to move into inventory. */
export const mailboxClaimSchema = z.object({
  dropIds: z.array(z.string().min(1).max(64)).min(1).max(500)
});

/** POST /lootbox/verify — recompute a past cookbook open. */
export const verifyOpenSchema = z.object({
  bookId: z.string().min(1).max(64),
  serverSeed: z.string().min(1),
  clientSeed: z.string().min(1),
  nonce: z.number().int().min(0)
});

/**
 * The canonical character stat set (issue #101).
 *
 * Four stats, not five. This is the set the whole game already runs on --
 * BattleKit's `BattleStats`, the Postgres `compute_base_stats()` function,
 * `game/baseStats.ts`, and every battle replay -- so it is documented and
 * validated here rather than replaced. docs/DATA-MODELS.md §Character stats is
 * the prose; this is the machine-checked version, and the two must agree.
 *
 * Each stat is an integer 10..100. Nothing outside that range is a legal stat:
 * the floor stops a zero-protein snack from being unplayable, and the ceiling
 * is what rarity and star multipliers scale *from*, never to.
 */
export const STAT_KEYS = ["power", "guard", "vitality", "tempo"] as const;
export type StatKey = (typeof STAT_KEYS)[number];

export const STAT_MIN = 10;
export const STAT_MAX = 100;

const statValue = z.number().int().min(STAT_MIN).max(STAT_MAX);

export const baseStatsSchema = z.object({
  /** Offence. Driven by protein. */
  power: statValue,
  /** Defence. Driven by fibre. */
  guard: statValue,
  /** Effective HP. Driven by micronutrient coverage. */
  vitality: statValue,
  /** Turn order and evasion. Driven by the protein:sugar ratio. */
  tempo: statValue
});

/** The element a character fights as, derived from its dominant stat. */
export const ELEMENTS = ["protein", "fiber", "vitamin", "hydration"] as const;
export const elementSchema = z.enum(ELEMENTS);

/** Which stat decides the element. Mirrors `element_from_stats()` in SQL. */
export const STAT_ELEMENT: Record<StatKey, (typeof ELEMENTS)[number]> = {
  power: "protein",
  guard: "fiber",
  vitality: "vitamin",
  tempo: "hydration"
};

export const RARITIES = [
  "common", "uncommon", "rare", "epic", "legendary", "mythic", "secret"
] as const;
export const raritySchema = z.enum(RARITIES);

/** 1..5. Star level is 1-based: every monster has at least one star. */
export const starLevelSchema = z.number().int().min(1).max(5);

export type BaseStatsInput = z.infer<typeof baseStatsSchema>;

export type ProfileUpsert = z.infer<typeof profileUpsertSchema>;
export type ScanBody = z.infer<typeof scanSchema>;
export type FusionBody = z.infer<typeof fusionSchema>;
export type RankedBattleBody = z.infer<typeof rankedBattleSchema>;
export type ArenaCreateBody = z.infer<typeof arenaCreateSchema>;
export type CapsuleOpenBody = z.infer<typeof capsuleOpenSchema>;
export type CharacterStats = z.infer<typeof baseStatsSchema>;
