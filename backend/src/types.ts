// Mirrors the Swift models 1:1 (see ios/Sources/NutriQuest/Models) so both
// sides of the app agree on the shape of a character, a scan, and a battle.

// 7-tier superset: the loot crate system uses uncommon/mythic/secret.
// Game characters (scans) only mint the 4 core tiers; Swift maps
// unknown tiers -> common on decode.
export type Rarity =
  | "common"
  | "uncommon"
  | "rare"
  | "epic"
  | "legendary"
  | "mythic"
  | "secret";
/** Mirrors ColorMode in DesignTokens.swift -- how the accent color is sourced. */
export type ColorMode = "active" | "bestUnselected" | "none";

/**
 * A monster as the API presents it — catalog identity fields plus the owning
 * instance's combat base. The catalog (data/characters.json) defines
 * baseHealth/baseAttack/baseMana and the authored moves; a barcode mint may
 * override the combat base with its nutrition-derived profile (source-neutral
 * combat: the instance fights on its own stored numbers).
 *
 * There is deliberately no `element`, `statType` or four-stat blob — the spec
 * removed the type system entirely.
 */
export interface Character {
  id: string;
  name: string;
  /** Hex string, e.g. "#5FCB82" -- mirrors Character.colorHex in the Swift app. */
  colorHex: string;
  /** Sprite/art lookup key (checked-in asset name). */
  imageKey?: string;
  tagline?: string;
  /** Lore. */
  bio?: string;
  /** Instance rarity — rolled at mint, never a property of the design. */
  rarity: Rarity;
  baseHealth: number;
  baseAttack: number;
  /** Present only on Epic+ instances — Mana exists only there. */
  baseMana?: number;
  /** Authored move ids (resolve via data/attacks.ts / the catalog endpoint). */
  moves?: string[];
  /** The Mana Special's move id; present only on Epic+ instances. */
  special?: string;
  isLocked: boolean;
}

/** Nutrition snapshot persisted per scan mint (anti-cheat) and shown to the
 *  user — per-100g fields as reported by the nutrition source. */
export interface ScanNutrition {
  calories?: number;
  proteinG?: number;
  carbsG?: number;
  fatG?: number;
  fiberG?: number;
  sugarG?: number;
  sodiumMg?: number;
  satFatG?: number;
}

export interface ScanResult {
  barcode: string;
  foodName: string;
  /** 0..100 — the holistic quality score the rarity roll tilted on. */
  nutritionScore?: number;
  /** Set when this scan minted a new ★1 monster (first-ever scan of this
   *  barcode by this player; barcode is the only mint path). */
  summonedCharacter?: Character;
  /** Nutrition the scan logged — present whether or not it minted. */
  nutrition?: ScanNutrition;
  /** True when this player has already minted from this barcode — the scan
   *  still logs nutrition and counts for tasks, it just never mints again. */
  duplicate?: boolean;
}

export interface BattleMove {
  name: string;
  description: string;
}

export interface BattleState {
  yourSquad: Character[];
  opponentSquad: Character[];
  fatigued: boolean;
  moves: BattleMove[];
  turn: "you" | "opponent";
}

export interface UserProfile {
  id: string;
  displayName: string;
  level: number;
  /** Lifetime experience points. Level is derived — see xpProgression. */
  xp: number;
  streakDays: number;
  battlesWon: number;
  activeCharacterId: string | null;
  colorMode: ColorMode;
}

// ===== Vitals (Apple Watch pipeline) =====

export interface WorkoutSummary {
  activityType: string;
  /** ISO 8601. */
  start: string;
  /** ISO 8601. */
  end: string;
  durationMinutes: number;
  activeCalories: number | null;
  distanceMeters: number | null;
  averageHeartRateBpm: number | null;
  maxHeartRateBpm: number | null;
}

/** One point-in-time reading posted by the iOS app. */
export interface HealthSnapshot {
  /** ISO 8601. */
  timestamp: string;
  /** Random project-local tester id. Never a name or account identifier. */
  testerId: string | null;

  heartRateBpm: number | null;
  restingHeartRateBpm: number | null;
  hrvMs: number | null;
  stepsToday: number | null;
  activeCaloriesToday: number | null;

  // Activity ring figures, from the Fitness app's own summary.
  // `standHoursToday` is the ring's hour count (goal normally 12), not minutes
  // spent standing -- those are different HealthKit values with similar names.
  exerciseMinutesToday: number | null;
  exerciseGoalMinutes: number | null;
  standHoursToday: number | null;
  standGoalHours: number | null;

  recentWorkouts: WorkoutSummary[];
}

/** A snapshot as stored, with what the server made of it. */
export interface StoredSnapshot {
  receivedAt: string;
  snapshot: HealthSnapshot;
  analysis: Record<string, string>;
}

export interface FieldError {
  field: string;
  reason: string;
}

// ===== Loot crates =====

export interface RarityTier {
  id: Rarity;
  label: string;
  /** Out of RARITY_TOTAL. Integers so the distribution stays exact. */
  weight: number;
  colorHex: string;
  /** Ascending scarcity, for sorting and display. */
  order: number;
  /**
   * Battle stat scaling for this tier, mirroring BattleRarity.statMultiplier
   * in BattleKit. Lives here so the loot table is the single source of truth:
   * battle.ts derives its multiplier map from these, which is what stops a new
   * tier from being droppable but unusable in combat.
   */
  statMultiplier: number;
}

/**
 * A Cookbook — the only purchasable loot container (spec §3). Specs (price,
 * 7-tier odds) live in game/spec.ts; flavour text lives in data/lootTable.ts.
 */
export interface Cookbook {
  id: string;
  name: string;
  description: string;
  price: number;
  odds: Record<Rarity, number>;
}

/**
 * The disclosed rolls behind a mint. Every roll is a uniform float in [0,1)
 * derived from the commit-reveal seed pair — kept so /lootbox/verify can
 * reproduce the exact outcome.
 */
export interface DropRolls {
  rarity: number;
  character: number;
  /** Band-segment pick (55/27/13/4/1). -1 when the drop was budget-priced
   *  (casino rewards) and no segment was rolled. */
  mintSegment: number;
  /** Position inside the band/segment. */
  mintPosition: number;
}

export interface Fairness {
  serverSeedHash: string;
  clientSeed: string;
  nonce: number;
}

export interface LootDrop {
  /** Container/source that produced this drop: a cookbook id, a granted case
   *  source ("case:<rarity>"), "scan", "starter-roster", "merge", ... */
  crateId: string;
  character: Character;
  /** Mastery stars (1-5). Raised by fusion; fresh mints always land at 1. */
  stars?: number;
  /** The ★1 value rolled at mint — permanent, inherited by fusion (max wins). */
  baseMintValue: number;
  /** Current net worth: baseMintValue + star bonus (spec §2). */
  value: number;
  rolls: DropRolls;
  /** Rarity of the Case that produced this mint, when opened via a case. */
  caseRarity?: Rarity;
  fairness: Fairness;
  openedAt: string;
}

export interface CrateOdds {
  rarity: Rarity;
  label: string;
  colorHex: string;
  tierChance: number;
  oneIn: number;
  characterCount: number;
  perCharacterChance: number;
}
