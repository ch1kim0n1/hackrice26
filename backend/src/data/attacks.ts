// Moveset resolution — the bridge between the master catalog
// (data/characters.json, where every character embeds its 3 authored
// standard moves + one Mana Special) and the battle engine's MoveSpec.
//
// Contract (final-dev-doc §4 + schemas/monster.ts moveSchema):
//   * power is a 0-10 scale feeding BaseDamage = (power × EffAtk)/Scale + 2;
//     0 means a pure status/utility move.
//   * accuracy is a percent (1-100); a miss deals 0 and skips statuses.
//   * statusEffect is one of the engine's status ids (see StatusEffectId in
//     services/battleEngine.ts); statusChance is P(status | hit) in percent;
//     duration is in the target side's turns.
//   * Specials exist on every catalog character but only resolve for Epic+
//     instances — sub-Epic monsters never see the Mana move.

import { Rarity } from "../types";
import { rosterCharacter } from "./roster";
import { hasMana } from "../game/spec";
import type { MoveDef } from "../schemas/monster";
import type { MoveSpec } from "../services/battleEngine";

/** Catalog move -> engine move. A Special is just a move with a Mana cost. */
function toSpec(move: MoveDef, kind: MoveSpec["kind"]): MoveSpec {
  return {
    id: move.id,
    name: move.name,
    kind,
    power: move.power,
    accuracy: move.accuracy,
    manaCost: move.manaCost,
    statusEffect: move.statusEffect as MoveSpec["statusEffect"],
    statusChance: move.statusChance,
    duration: move.duration,
    description: move.description
  };
}

/** Fallback for units with no authored catalog entry. */
export const STRIKE: MoveSpec = {
  id: "strike",
  name: "Strike",
  kind: "standard",
  power: 3,
  accuracy: 100,
  manaCost: 0
};

/**
 * The moves a monster can use at `rarity`: the character's 3 authored
 * standards, plus its Mana Special when the instance is Epic+ and the
 * catalog authored one. Unknown characters fight with Strike alone.
 */
export function attacksFor(characterKey: string, rarity: Rarity): MoveSpec[] {
  const character = rosterCharacter(characterKey);
  if (!character) return [STRIKE];
  const moves = character.moves.map((m: MoveDef) => toSpec(m, "standard"));
  if (character.special && hasMana(rarity)) moves.push(toSpec(character.special, "special"));
  return moves;
}
