// Shared test factories for the spec economy.
//
// Every test that needs a monster in inventory builds it through testDrop so
// the drop shape lives in exactly one place — when the payload changes, the
// tests change here, not in a dozen files.

import { Character, LootDrop, Rarity } from "./types";
import { StoredDrop } from "./services/lootboxState";
import { mintPool } from "./data/lootTable";
import { asCharacter, rosterCharacter } from "./data/roster";
import { RARITY_BANDS, netWorthFor, StarLevel } from "./game/rarityBands";

/** A roster design stamped with an instance rarity. */
export function testCharacter(rarity: Rarity = "common", id?: string): Character {
  const design = id ? rosterCharacter(id) : mintPool()[0];
  if (!design) {
    // Tests name characters from the retired catalog; keep the id (identity
    // is what tests assert on) and borrow the first design's stats.
    return { ...asCharacter(mintPool()[0], rarity), id: id!, name: id! };
  }
  return asCharacter(design, rarity);
}

/**
 * A drop in the new shape: baseMintValue is the permanent ★1 mint value and
 * value is the current net worth (base + star bonus) unless overridden.
 */
export function testDrop(overrides: Partial<LootDrop> = {}): Omit<StoredDrop, "id"> {
  const character = overrides.character ?? testCharacter("common");
  const stars = (overrides.stars ?? 1) as StarLevel;
  const baseMintValue =
    overrides.baseMintValue ??
    overrides.value ??
    RARITY_BANDS[character.rarity].min;
  const value = overrides.value ?? netWorthFor(baseMintValue, character.rarity, stars);
  return {
    crateId: "test",
    character,
    stars,
    baseMintValue,
    value,
    rolls: { rarity: 0.1, character: 0.1, mintSegment: 0, mintPosition: 0.1 },
    fairness: { serverSeedHash: "hash", clientSeed: "seed", nonce: 0 },
    openedAt: new Date().toISOString(),
    ...overrides
  };
}
