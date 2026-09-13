// Turning a cash-out budget into an actual monster.
//
// Shared by every game that pays out in monsters -- Cauldron Crash, Kitchen
// Mines, Plinko, the Portal Wheel. It lives here rather than inside one game
// because two implementations of "what does this much net worth buy" is two
// economies, and the rarity bands were unified to stop exactly that
// (see game/rarityBands.ts, docs/NET-WORTH.md).
//
// The rule, in one line: the budget picks the band, the band picks the pool,
// and a roll picks the monster. The player never chooses.

import { mintPool } from "../data/lootTable";
import { RosterCharacter, asCharacter } from "../data/roster";
import { Character, Rarity } from "../types";
import { RARITY_BANDS, rarityForValue } from "./rarityBands";

export interface MonsterReward {
  character: Character;
  rarity: Rarity;
  /**
   * The mint's permanent ★1 value. Budget-priced: the highest in-band value
   * the budget affords, so a cash-out rounds down inside the band but never
   * mints net worth the player did not earn.
   */
  baseMintValue: number;
  /** The reward's own net worth, which is what the inventory stores. */
  value: number;
  /** The cash-out budget it was bought with. */
  budget: number;
  /** Winnings are always fresh monsters: mastery is fused, never bought. */
  stars: number;
}

/** Designs a reward can mint, in a stable order — the whole catalog, since
 *  rarity is a property of the instance the budget bought, not of the design. */
export function rewardPool(): RosterCharacter[] {
  return [...mintPool()].sort((a, b) => a.id.localeCompare(b.id));
}

/**
 * Buy a monster with a cash-out budget.
 *
 * The budget picks the rarity band; the character is then uniformly random
 * within it. The mint value is priced, not rolled: it lands at the largest
 * in-band value the budget covers (never below the floor — the floor is what
 * `rarityForValue(budget)` already guaranteed, and never above the band cap).
 */
export function rewardFor(budget: number, characterRoll: number, positionRoll: number): MonsterReward {
  const rarity = rarityForValue(budget);
  const pool = rewardPool();
  const character = asCharacter(
    pool[Math.min(Math.floor(characterRoll * pool.length), pool.length - 1)],
    rarity
  );

  const band = RARITY_BANDS[rarity];
  const baseMintValue = Math.min(band.max, Math.max(band.min, Math.floor(budget)));

  return {
    character,
    rarity,
    baseMintValue,
    value: baseMintValue,
    budget,
    stars: 1
  };
}
