// Turning a cash-out budget into an actual monster.
//
// Shared by every game that pays out in monsters -- Cauldron Crash, Kitchen
// Mines, and whatever the casino adds next. It lives here rather than inside
// one game because two implementations of "what does this much net worth buy"
// is two economies, and the rarity bands were just unified to stop exactly
// that (see game/rarityBands.ts, docs/NET-WORTH.md).
//
// The rule, in one line: the budget picks the band, the band picks the pool,
// and a roll picks the monster. The player never chooses.

import { CHARACTERS, JOKE_CHARACTER_IDS, POWER_BANDS } from "../data/lootTable";

const JOKE_ID_SET = new Set<string>(JOKE_CHARACTER_IDS);
import { Character, PowerBand, Rarity } from "../types";
import { dropNetWorth, rarityForValue } from "./rarityBands";

export interface MonsterReward {
  character: Character;
  rarity: Rarity;
  power: number;
  powerLabel: string;
  shiny: boolean;
  /** The reward's own net worth, which is what the inventory stores. */
  value: number;
  /** The cash-out budget it was bought with. */
  budget: number;
  /** Winnings are always fresh monsters: mastery is fused, never bought. */
  stars: number;
}

/** Monsters of one tier, in a stable order. */
export function rewardPool(rarity: Rarity): Character[] {
  return Object.values(CHARACTERS)
    .filter((character) => character.rarity === rarity && !JOKE_ID_SET.has(character.id))
    .sort((a, b) => a.id.localeCompare(b.id));
}

/** Every value a monster of this tier can actually be minted at. */
function mintableValues(rarity: Rarity): { band: PowerBand; shiny: boolean; value: number }[] {
  const combos: { band: PowerBand; shiny: boolean; value: number }[] = [];
  for (const band of POWER_BANDS) {
    for (const shiny of [false, true]) {
      combos.push({ band, shiny, value: dropNetWorth(rarity, band.valueMultiplier, shiny) });
    }
  }
  return combos;
}

/**
 * Buy a monster with a cash-out budget.
 *
 * The budget picks the rarity band; the character is then uniformly random
 * within it. Power and the shiny roll are not free either: they are chosen so
 * the reward's own value is the closest one this tier can be minted at, which
 * is what stops a Legendary bought near the top of its band from arriving at
 * the band floor.
 *
 * Ties go to the cheaper monster, and a minted reward never exceeds the
 * budget: closest-within-budget, so a cash-out can round down but never mint
 * net worth the player did not earn.
 */
export function rewardFor(budget: number, characterRoll: number, powerRoll: number): MonsterReward {
  const rarity = rarityForValue(budget);
  const pool = rewardPool(rarity);
  const character = pool[Math.min(Math.floor(characterRoll * pool.length), pool.length - 1)];

  // Values this tier can be minted at that the budget can actually afford.
  // The band floor is always affordable — rarityForValue(budget) picked the
  // rarity whose range contains budget — but if that ever stops being true,
  // fall back to the cheapest mintable value rather than overshooting.
  const mintable = mintableValues(rarity);
  const affordable = mintable.filter((c) => c.value <= budget);
  const candidates = affordable.length ? affordable : mintable;
  const best = candidates.reduce((chosen, candidate) => {
    const delta = Math.abs(candidate.value - budget);
    const chosenDelta = Math.abs(chosen.value - budget);
    if (delta < chosenDelta) return candidate;
    if (delta === chosenDelta && candidate.value < chosen.value) return candidate;
    return chosen;
  });

  // Power is uniform inside the chosen band: the band fixes the value, the
  // roll decides where in the band the number lands.
  const span = best.band.max - best.band.min;
  const power = Math.round((best.band.min + powerRoll * span) * 10) / 10;

  return {
    character,
    rarity,
    power: Math.min(power, 100),
    powerLabel: best.band.label,
    shiny: best.shiny,
    value: best.value,
    budget,
    stars: 1
  };
}
