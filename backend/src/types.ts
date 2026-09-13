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
export type StatType = "protein" | "fiber" | "vitamin" | "hydration";

/** Mirrors ColorMode in DesignTokens.swift -- how the accent color is sourced. */
export type ColorMode = "active" | "bestUnselected" | "none";

export interface Character {
  id: string;
  name: string;
  /** Hex string, e.g. "#5FCB82" -- mirrors Character.colorHex in the Swift app. */
  colorHex: string;
  rarity: Rarity;
  statType: StatType;
  isLocked: boolean;
  /** produce/grain/dairy/protein/other. Set for dish-photo characters, where
   *  it drives the procedural artwork so different kinds of meal read as
   *  different creatures. Absent for barcode scans and sample characters. */
  foodGroup?: string;
}

export interface ScanResult {
  barcode: string;
  foodName: string;
  /** Which stat this food primarily boosts -- determines which character it can summon. */
  statType: StatType;
  /** Set when this scan was novel/balanced enough to summon a new character. */
  summonedCharacter?: Character;
}

export interface BattleMove {
  name: string;
  statType: StatType;
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

export interface Crate {
  id: string;
  name: string;
  description: string;
  keyCost: number;
  /** Character ids this crate can yield. */
  characterIds: string[];
}

/** Which band a power roll fell into, and what it does to the drop's value. */

export interface PowerBand {
  label: string;
  min: number;
  max: number;
  valueMultiplier: number;
}

export interface DropRolls {
  rarity: number;
  character: number;
  power: number;
  shiny: number;
}

export interface Fairness {
  serverSeedHash: string;
  clientSeed: string;
  nonce: number;
}

export interface LootDrop {
  crateId: string;
  character: Character;
  /** Mastery stars. Raised by fusion; a Cauldron Crash reward always lands at
   *  1, because Crash is rarity progression and never mastery. */
  stars?: number;
  /** 0-100. Higher is better, unlike a CS:GO float. */
  power: number;
  powerLabel: string;
  /** The holo variant. Cosmetic, but doubles the drop's value. */
  shiny: boolean;
  value: number;
  rolls: DropRolls;
  /** Set when the pity guarantee lifted the rolled tier (see lootboxEngine). */
  pityForced?: "epic" | "legendary" | null;
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
