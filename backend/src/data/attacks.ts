// Authored attack set (issue #108). Schema: `attack` / `character_attack`
// tables (migration 004 / PG 0012); this file is the data they hold, and the
// sim reads it through attacksFor() so the same list drives combat and seeds
// the DB.
//
// Contract: every roster character gets a basic + a signature. Specials are
// gated by `minRarity` — an epic-or-better monster unlocks one, lower tiers
// never see it (Pokémon-style: rarity unlocks the stronger move).

import { Rarity, StatType } from "../types";
import { ROSTER } from "./roster";

export type AttackKind = "basic" | "signature" | "special";
export type StatKind = "power" | "guard" | "vitality" | "tempo";

export interface AttackDef {
  id: string;
  name: string;
  kind: AttackKind;
  /** Damage multiplier — Strike 1.0, signatures ~1.45, specials higher. */
  power: number;
  /** Which stat the move attacks with. */
  usesStat: StatKind;
  /** Lowest rarity allowed to use it. */
  minRarity: Rarity;
  /** Flavour/effect text for the UI. */
  effect?: string;
}

const RARITY_RANK: Record<Rarity, number> = {
  common: 0, uncommon: 1, rare: 2, epic: 3, legendary: 4, mythic: 5, secret: 6
};

/** Element -> the stat it plays through (mirrors STAT_ELEMENT, inverted). */
export const ELEMENT_STAT: Record<StatType, StatKind> = {
  protein: "power",
  fiber: "guard",
  vitamin: "vitality",
  hydration: "tempo"
};

const basic = (id: string): AttackDef => ({
  id,
  name: "Strike",
  kind: "basic",
  power: 1.0,
  usesStat: "power",
  minRarity: "common"
});

const signature = (id: string, name: string, stat: StatType, effect: string): AttackDef => ({
  id,
  name,
  kind: "signature",
  power: 1.45,
  usesStat: ELEMENT_STAT[stat],
  minRarity: "common",
  effect
});

const special = (id: string, name: string, stat: StatType, minRarity: Rarity, effect: string): AttackDef => ({
  id,
  name,
  kind: "special",
  power: 1.8,
  usesStat: ELEMENT_STAT[stat],
  minRarity,
  effect
});

export const ATTACKS: AttackDef[] = [
  // Shared basic — every character carries it implicitly.
  basic("strike"),

  // -- signatures, one per roster character -------------------------------
  signature("sig-broccoli-bud", "Verdant Slam", "fiber", "A headbutt with the structural integrity of a cruciferous vegetable."),
  signature("sig-carrot-cadet", "Night Patrol Jab", "vitamin", "Strikes where it cannot see. Allegedly."),
  signature("sig-water-droplet", "Undertow", "hydration", "Pulls the fight down to its level."),
  signature("sig-bean-sprout", "Underdog Uppercut", "protein", "Hits harder than anything that size should."),
  signature("sig-spinach-scout", "Iron Rebound", "vitamin", "Collapses, then returns the hit with interest."),
  signature("sig-almond-knight", "Shellbreaker", "protein", "Armour meeting armour, ending badly for one of them."),
  signature("sig-salmon-striker", "Upstream Rush", "protein", "Charges directly into whatever current the fight is running."),
  signature("sig-avocado-aegis", "Eleven-Minute Wall", "fiber", "Becomes briefly immovable."),
  signature("sig-kale-colossus", "Gardenquake", "vitamin", "The largest thing in the garden lands on you."),
  signature("sig-chia-chieftain", "Siege Expansion", "fiber", "Fills every gap in the defence, then all of yours."),
  signature("sig-pomegranate-paladin", "Ruby Barrage", "vitamin", "Opens the treasury for exactly one volley."),
  signature("sig-turmeric-titan", "Golden Stain", "vitamin", "Marks the target. Permanently."),
  signature("sig-spirulina-wyrm", "Ancient Bloom", "protein", "Surfaces for the first time this generation."),
  signature("sig-the-first-seed", "Genesis Bloom", "fiber", "Everything else grew from something like this."),

  // -- specials, rarity-gated ---------------------------------------------
  special("spc-kale-colossus", "Overgrowth", "vitamin", "epic", "The garden expands until the fight is inside it."),
  special("spc-chia-chieftain", "Absorb All", "fiber", "epic", "Takes on the weight of everything thrown at it."),
  special("spc-pomegranate-paladin", "Sealed Treasury", "vitamin", "legendary", "A thousand rubies, spent at once."),
  special("spc-turmeric-titan", "Permanent Mark", "vitamin", "legendary", "The stain outlives the battle."),
  special("spc-spirulina-wyrm", "Primordial Depths", "protein", "mythic", "The lake remembers being an ocean."),
  special("spc-the-first-seed", "Origin Pulse", "fiber", "secret", "The thing everything else is a copy of.")
];

export const ATTACKS_BY_ID: Record<string, AttackDef> = Object.fromEntries(
  ATTACKS.map((a) => [a.id, a])
);

/** Attack ids each character owns, in display order. */
export const CHARACTER_ATTACKS: Record<string, string[]> = Object.fromEntries(
  ROSTER.map((c) => [
    c.id,
    [
      "strike",
      `sig-${c.id}`,
      ...(ATTACKS.some((a) => a.id === `spc-${c.id}`) ? [`spc-${c.id}`] : [])
    ]
  ])
);

/**
 * The moves a character can actually use at `rarity`: its whole moveset
 * filtered by each attack's `minRarity`. Generated characters fall back to
 * strike + a nameless signature handled by the sim.
 */
export function attacksFor(characterKey: string, rarity: Rarity): AttackDef[] {
  const ids = CHARACTER_ATTACKS[characterKey] ?? ["strike"];
  const rank = RARITY_RANK[rarity];
  return ids
    .map((id) => ATTACKS_BY_ID[id])
    .filter((a) => a && RARITY_RANK[a.minRarity] <= rank);
}
