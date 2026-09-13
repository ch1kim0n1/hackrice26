// The starter six — a brand-new player's opening roster, minted as real
// owned drops on first attach (lootboxState.seedStarterRoster).
//
// These are instances of the master catalog, not bespoke designs: permanent
// catalog ids, catalog movesets, instance rarities. Six commons-to-rare
// spread across the stat envelope so a starter team can fight immediately.

import { Character, Rarity } from "../types";
import { asCharacter, rosterCharacter } from "./roster";

const STARTERS: [characterId: string, rarity: Rarity][] = [
  ["broccoli-bud", "common"],
  ["bean-sprout", "common"],
  ["carrot-cadet", "common"],
  ["water-droplet", "common"],
  ["spinach-scout", "uncommon"],
  ["almond-knight", "rare"]
];

export const sampleCharacters: Character[] = STARTERS.map(([id, rarity]) => {
  const entry = rosterCharacter(id);
  if (!entry) throw new Error(`starter '${id}' is not in the catalog`);
  return asCharacter(entry, rarity);
});
