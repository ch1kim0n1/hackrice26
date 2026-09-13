// Loot crate catalogue: the rarity ladder, the characters that can drop, and
// which crates contain what. Pure data -- re-theme the game here without
// touching the opening logic in services/lootboxEngine.ts.

import { Character, Crate, PowerBand, Rarity, RarityTier } from "../types";

/**
 * Weights are integers out of RARITY_TOTAL so the distribution is exact.
 * Percentages that almost sum to 100 are a classic source of drift in loot
 * systems, and the error always favours the wrong tier.
 *
 * Each tier is one fifth as likely as the one below it -- the same geometric
 * decay CS:GO uses, which is what makes the top of the ladder feel genuinely
 * out of reach rather than merely uncommon.
 */
export const RARITY_TOTAL = 1_000_000;

/**
 * The tier ladder. `statMultiplier` scales a unit's battle stats and is
 * consumed by routes/battle.ts, so every droppable tier is automatically a
 * battle-legal one.
 *
 * The four original multipliers (1.0 / 1.12 / 1.25 / 1.4) are unchanged, so
 * this adds tiers without re-balancing existing matchups. Uncommon sits at the
 * midpoint of the common-to-rare step, and mythic and secret continue the
 * +0.15 cadence that epic -> legendary already set.
 */
export const RARITY_TIERS: Record<Rarity, RarityTier> = {
  common:    { id: "common",    label: "Common",    weight: 800_000, colorHex: "#9AA4B2", order: 0, statMultiplier: 1.0 },
  uncommon:  { id: "uncommon",  label: "Uncommon",  weight: 160_000, colorHex: "#4ADE80", order: 1, statMultiplier: 1.06 },
  rare:      { id: "rare",      label: "Rare",      weight:  32_000, colorHex: "#3B82F6", order: 2, statMultiplier: 1.12 },
  epic:      { id: "epic",      label: "Epic",      weight:   6_400, colorHex: "#A855F7", order: 3, statMultiplier: 1.25 },
  legendary: { id: "legendary", label: "Legendary", weight:   1_280, colorHex: "#F59E0B", order: 4, statMultiplier: 1.4 },
  mythic:    { id: "mythic",    label: "Mythic",    weight:     256, colorHex: "#EF4444", order: 5, statMultiplier: 1.55 },
  secret:    { id: "secret",    label: "Secret",    weight:      64, colorHex: "#22D3EE", order: 6, statMultiplier: 1.7 }
};

/** Tier ids from most to least common. Use wherever order matters. */
export const RARITY_ORDER: Rarity[] = (Object.keys(RARITY_TIERS) as Rarity[]).sort(
  (a, b) => RARITY_TIERS[a].order - RARITY_TIERS[b].order
);

/**
 * Power bands. Unlike a CS:GO float, higher is better here -- a character you
 * pulled at 97 power should read as a trophy, not a defect.
 */
export const POWER_BANDS: PowerBand[] = [
  { label: "Feeble",    min:  0, max: 40,    valueMultiplier: 0.6 },
  { label: "Steady",    min: 40, max: 70,    valueMultiplier: 1.0 },
  { label: "Honed",     min: 70, max: 88,    valueMultiplier: 1.4 },
  { label: "Peak",      min: 88, max: 97,    valueMultiplier: 2.0 },
  { label: "Ascendant", min: 97, max: 100.1, valueMultiplier: 3.0 }
];

// Key crates price a drop off the exponential rarity bands in
// game/rarityBands.ts: the band picks the floor, and the power roll plus holo
// decide where inside it a pull lands. See dropNetWorth().

/**
 * Flat per-rarity base values, used only to price coin-shop case drops
 * (services/lootboxEngine.ts openShopCase). Key crates keep the rarity bands
 * above — this is a deliberate second economy for the shop, nothing else
 * should read it.
 */
export const BASE_VALUES: Record<Rarity, number> = {
  common: 15,
  uncommon: 60,
  rare: 220,
  epic: 850,
  legendary: 3_000,
  mythic: 9_500,
  secret: 50_000
};

type CharacterSeed = Omit<Character, "isLocked"> & { flavor: string };

const CHARACTER_SEEDS: CharacterSeed[] = [
  // --- Common ---
  { id: "broccoli-bud",    name: "Broccoli Bud",       colorHex: "#5FCB82", rarity: "common", statType: "fiber",     flavor: "Small, green, relentlessly wholesome." },
  { id: "oat-sprout",      name: "Oat Sprout",         colorHex: "#C9B27C", rarity: "common", statType: "fiber",     flavor: "Slow release, slow temper." },
  { id: "water-droplet",   name: "Water Droplet",      colorHex: "#7CC5E8", rarity: "common", statType: "hydration", flavor: "Unremarkable until you go without." },
  { id: "bean-sprout",     name: "Bean Sprout",        colorHex: "#8FD16A", rarity: "common", statType: "protein",   flavor: "Punches slightly above its weight." },
  { id: "carrot-cadet",    name: "Carrot Cadet",       colorHex: "#F2913D", rarity: "common", statType: "vitamin",   flavor: "Claims to improve your eyesight." },
  { id: "rice-grain",      name: "Rice Grain",         colorHex: "#EDE3CC", rarity: "common", statType: "fiber",     flavor: "Shows up in every meal, uncomplaining." },

  // --- Uncommon ---
  { id: "spinach-scout",   name: "Spinach Scout",      colorHex: "#3E9B5F", rarity: "uncommon", statType: "vitamin",   flavor: "Wilts dramatically, recovers instantly." },
  { id: "almond-knight",   name: "Almond Knight",      colorHex: "#C08A5E", rarity: "uncommon", statType: "protein",   flavor: "Armoured in its own shell." },
  { id: "yogurt-sage",     name: "Yogurt Sage",        colorHex: "#F4F1E8", rarity: "uncommon", statType: "protein",   flavor: "Cultured, in every sense." },
  { id: "berry-bolt",      name: "Berry Bolt",         colorHex: "#B3477E", rarity: "uncommon", statType: "vitamin",   flavor: "Gone before you finish the bowl." },

  // --- Rare ---
  { id: "salmon-striker",  name: "Salmon Striker",     colorHex: "#F08A70", rarity: "rare", statType: "protein",   flavor: "Swims upstream out of principle." },
  { id: "quinoa-quill",    name: "Quinoa Quill",       colorHex: "#D8C48F", rarity: "rare", statType: "protein",   flavor: "Complete. Insufferably so." },
  { id: "avocado-aegis",   name: "Avocado Aegis",      colorHex: "#6C9B4A", rarity: "rare", statType: "fiber",     flavor: "Ready for exactly eleven minutes." },

  // --- Epic ---
  { id: "kale-colossus",   name: "Kale Colossus",      colorHex: "#2F6B4F", rarity: "epic", statType: "vitamin",   flavor: "Nobody asked for it. It came anyway." },
  { id: "chia-chieftain",  name: "Chia Chieftain",     colorHex: "#5B5B6E", rarity: "epic", statType: "fiber",     flavor: "Expands to fill any vessel." },
  { id: "mango-monarch",   name: "Mango Monarch",      colorHex: "#F5A623", rarity: "epic", statType: "vitamin",   flavor: "Rules a very sticky kingdom." },

  // --- Legendary ---
  { id: "pomegranate-paladin", name: "Pomegranate Paladin", colorHex: "#C0334D", rarity: "legendary", statType: "vitamin", flavor: "Guards a thousand small rubies." },
  { id: "turmeric-titan",  name: "Turmeric Titan",     colorHex: "#E3A008", rarity: "legendary", statType: "vitamin",   flavor: "Stains everything it touches, permanently." },

  // --- Mythic ---
  { id: "spirulina-wyrm",  name: "Spirulina Wyrm",     colorHex: "#1F7A6E", rarity: "mythic", statType: "protein",   flavor: "Older than the lakes it sleeps in." },
  { id: "cacao-phantom",   name: "Cacao Phantom",      colorHex: "#4A2C2A", rarity: "mythic", statType: "vitamin",   flavor: "Bitter until it decides otherwise." },

  // --- Secret ---
  { id: "the-first-seed",  name: "The First Seed",     colorHex: "#22D3EE", rarity: "secret", statType: "fiber",     flavor: "No record of where it came from. Only that it is yours now." },

  // --- Secret crate joke (Italian brainrot). Not in the Pokédex roster. ---
  { id: "shark-brainrot",        name: "Tralalero Tralala",      colorHex: "#3B82F6", rarity: "secret", statType: "protein",   flavor: "A shark in Nike sneakers. This is fine." },
  { id: "zibra-zubra-zibralini", name: "Zibra Zubra Zibralini",  colorHex: "#2F6B4F", rarity: "secret", statType: "vitamin",   flavor: "Zebra head, watermelon body, human legs. Hydration is a lifestyle." },
  { id: "frigo-camello",         name: "Frigo Camello",          colorHex: "#C08A5E", rarity: "secret", statType: "hydration", flavor: "A camel that is also a fridge. Cold storage with extra neck." },
  { id: "bobrini-cocosini",      name: "Bobrini Cocosini",       colorHex: "#8B5A2B", rarity: "secret", statType: "fiber",     flavor: "Capybara in a coconut. Cultured, in the tropical sense." },
  { id: "triple-t-brainrot",     name: "Tung Tung Tung Sahur",   colorHex: "#B45309", rarity: "secret", statType: "protein",   flavor: "A wooden man with a bat. Do not ask about breakfast." }
];

/** Joke-only ids. Kept out of every serious crate and casino reward pool. */
export const JOKE_CHARACTER_IDS = [
  "shark-brainrot",
  "zibra-zubra-zibralini",
  "frigo-camello",
  "bobrini-cocosini",
  "triple-t-brainrot"
] as const;

const JOKE_ID_SET = new Set<string>(JOKE_CHARACTER_IDS);

export const CHARACTER_FLAVOR: Record<string, string> = Object.fromEntries(
  CHARACTER_SEEDS.map((c) => [c.id, c.flavor])
);

export const CHARACTERS: Record<string, Character> = Object.fromEntries(
  CHARACTER_SEEDS.map(({ flavor, ...c }) => [c.id, { ...c, isLocked: false }])
);

const seriousIds = () => Object.keys(CHARACTERS).filter((id) => !JOKE_ID_SET.has(id));

export const CRATES: Record<string, Crate> = {
  "starter-crate": {
    id: "starter-crate",
    name: "Starter Crate",
    description: "The standard drop. Every tier is reachable, including Secret.",
    keyCost: 1,
    characterIds: seriousIds()
  },
  "harvest-crate": {
    id: "harvest-crate",
    name: "Harvest Crate",
    description: "No entry-level filler. Costs more, floors higher.",
    keyCost: 3,
    characterIds: [
      "carrot-cadet", "rice-grain",
      "spinach-scout", "almond-knight", "yogurt-sage", "berry-bolt",
      "salmon-striker", "quinoa-quill", "avocado-aegis",
      "kale-colossus", "chia-chieftain", "mango-monarch",
      "pomegranate-paladin", "turmeric-titan",
      "spirulina-wyrm", "cacao-phantom",
      "the-first-seed"
    ]
  },
  // --- Themed capsules: curated pools over the same roster. Theming is the
  // point — a veggie capsule feels different from a gourmet one even when
  // the underlying odds overlap.
  "garden-crate": {
    id: "garden-crate",
    name: "Garden Capsule",
    description: "Leafy things only. Sprouts, scouts, and one very large kale.",
    keyCost: 1,
    characterIds: [
      "broccoli-bud", "carrot-cadet", "spinach-scout",
      "avocado-aegis", "kale-colossus", "chia-chieftain"
    ]
  },
  "pantry-crate": {
    id: "pantry-crate",
    name: "Pantry Capsule",
    description: "Staples and grains — with a one-in-a-million Seed hiding at the back of the shelf.",
    keyCost: 1,
    characterIds: [
      "rice-grain", "oat-sprout", "water-droplet",
      "quinoa-quill", "avocado-aegis", "the-first-seed"
    ]
  },
  "protein-crate": {
    id: "protein-crate",
    name: "Protein Capsule",
    description: "Every pull hits like a macro. Best odds on protein-type characters.",
    keyCost: 2,
    characterIds: [
      "bean-sprout", "almond-knight", "yogurt-sage",
      "salmon-striker", "quinoa-quill", "spirulina-wyrm"
    ]
  },
  "dessert-crate": {
    id: "dessert-crate",
    name: "Dessert Capsule",
    description: "The sweet shelf. Fruit-forward with a bitter phantom at the bottom.",
    keyCost: 3,
    characterIds: [
      "berry-bolt", "mango-monarch", "pomegranate-paladin",
      "turmeric-titan", "cacao-phantom", "water-droplet"
    ]
  },
  "chefs-table-crate": {
    id: "chefs-table-crate",
    name: "Chef's Table Capsule",
    description: "Epic floor, no filler. What Gordon Ramsay would open if he played gacha.",
    keyCost: 6,
    characterIds: [
      "kale-colossus", "chia-chieftain", "mango-monarch",
      "pomegranate-paladin", "turmeric-titan",
      "spirulina-wyrm", "cacao-phantom", "the-first-seed"
    ]
  },
  "secret-crate": {
    id: "secret-crate",
    name: "Secret Crate",
    description: "Do not open this. We are not sorry.",
    keyCost: 7,
    characterIds: [...JOKE_CHARACTER_IDS]
  }
};

/** A coin-shop case. No key price — the shop charges coins, priced from its odds. */
export interface ShopCase {
  id: string;
  name: string;
  description: string;
  characterIds: string[];
}

/**
 * The coin shop: one case per rarity, cheapest first. Each case stocks its own
 * tier and every rarer one, nothing below — so the renormalisation in
 * lootboxEngine.crateRarityWeights makes a Rare Case 80% Rare, 16% Epic and
 * so on up, with no second set of weights to keep in step. Joke characters
 * stay out — they belong to the secret-crate bit, not the shop.
 */
export const SHOP_CASES: Record<string, ShopCase> = Object.fromEntries(
  RARITY_ORDER.map((floor) => {
    const tier = RARITY_TIERS[floor];
    const id = `${floor}-case`;
    const shopCase: ShopCase = {
      id,
      name: `${tier.label} Case`,
      description:
        floor === "common" ? "Every tier is reachable, including Secret."
        : floor === "secret" ? "Nothing but the rarest tier."
        : `${tier.label} or better, every time.`,
      characterIds: seriousIds().filter(
        (cid) => RARITY_TIERS[CHARACTERS[cid].rarity].order >= tier.order
      )
    };
    return [id, shopCase];
  })
);

// --- Invariants. Catch a bad edit here rather than at 3am mid-demo. ---

const weightSum = RARITY_ORDER.reduce((sum, r) => sum + RARITY_TIERS[r].weight, 0);
if (weightSum !== RARITY_TOTAL) {
  throw new Error(`Rarity weights sum to ${weightSum}, expected ${RARITY_TOTAL}`);
}

// A rarer pull must never be a statistical downgrade.
for (let i = 1; i < RARITY_ORDER.length; i++) {
  const prev = RARITY_TIERS[RARITY_ORDER[i - 1]];
  const curr = RARITY_TIERS[RARITY_ORDER[i]];
  if (curr.statMultiplier <= prev.statMultiplier) {
    throw new Error(
      `statMultiplier must increase with scarcity: ${curr.id} (${curr.statMultiplier}) <= ${prev.id} (${prev.statMultiplier})`
    );
  }
}

for (const crate of Object.values(CRATES)) {
  for (const id of crate.characterIds) {
    if (!CHARACTERS[id]) {
      throw new Error(`Crate '${crate.id}' references unknown character '${id}'`);
    }
  }
}
