// Plinko drop resolution: the authoritative part.
//
// The simplest lifecycle in the casino, because the game has no mid-round
// decisions. One call spends the monster, rolls the path, prices the landing
// and mints the reward — all of it before the client has drawn a single frame.
// There is no live round to protect and no cash-out to race.
//
// What still has to hold, exactly as in the other games:
//
//   - The monster leaves the inventory and never comes back, whatever the orb
//     does. A 0x landing destroys it and pays nothing.
//   - The outcome is fixed before the animation starts. The client is handed
//     the path the server rolled, so the orb it draws is bouncing along the
//     route that actually decided the result — the animation cannot disagree
//     with the outcome because it is derived from it.
//   - Nothing about the wager touches the odds. `dropPath` takes a roll
//     function and nothing else.

import { randomUUID } from "crypto";
import { db } from "../db";
import { Fairness } from "../types";
import {
  PLINKO_CURSOR,
  dropPath,
  finalNetWorth as computeFinalNetWorth,
  multiplierForSlot,
  slotForPath
} from "./plinkoEngine";
import { MonsterReward, rewardFor } from "../game/rewards";
import { roll } from "./lootboxEngine";
import { StoredDrop, stateFor } from "./lootboxState";
import { payoutDrop, wagerDrops } from "./characterMutations";

export const PLINKO_ERRORS = {
  WAGER_UNAVAILABLE: "PLINKO_WAGER_UNAVAILABLE",
  DROP_NOT_FOUND: "PLINKO_DROP_NOT_FOUND"
} as const;

export interface PlinkoDrop {
  dropId: string;
  playerId: string;
  wager: StoredDrop;
  wagerValue: number;
  /** One left/right decision per peg row; `true` is a step right. */
  path: boolean[];
  slot: number;
  multiplier: number;
  finalNetWorth: number;
  /** null when the orb landed on 0x — the monster is spent, nothing returns. */
  reward: (StoredDrop & { budget: number; overflowed?: boolean }) | null;
  createdAt: string;
  fairness: Fairness;
}

interface DropRow {
  drop_id: string;
  player_id: string;
  wager: string;
  wager_value: number;
  path: string;
  slot: number;
  multiplier: number;
  final_net_worth: number;
  reward: string | null;
  created_at: string;
  fairness: string;
}

function hydrate(row: DropRow): PlinkoDrop {
  return {
    dropId: row.drop_id,
    playerId: row.player_id,
    wager: JSON.parse(row.wager) as StoredDrop,
    wagerValue: row.wager_value,
    path: JSON.parse(row.path) as boolean[],
    slot: row.slot,
    multiplier: row.multiplier,
    finalNetWorth: row.final_net_worth,
    reward: row.reward ? (JSON.parse(row.reward) as StoredDrop & { budget: number; overflowed?: boolean }) : null,
    createdAt: row.created_at,
    fairness: JSON.parse(row.fairness) as Fairness
  };
}

function persist(drop: PlinkoDrop): void {
  db.prepare(
    `INSERT INTO plinko_drop (
       drop_id, player_id, wager, wager_value, path, slot, multiplier,
       final_net_worth, reward, created_at, fairness
     ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`
  ).run(
    drop.dropId,
    drop.playerId,
    JSON.stringify(drop.wager),
    drop.wagerValue,
    JSON.stringify(drop.path),
    drop.slot,
    drop.multiplier,
    drop.finalNetWorth,
    drop.reward ? JSON.stringify(drop.reward) : null,
    drop.createdAt,
    JSON.stringify(drop.fairness)
  );
}

export function dropById(playerId: string, dropId: string): PlinkoDrop | null {
  const row = db
    .prepare(`SELECT * FROM plinko_drop WHERE drop_id = ? AND player_id = ?`)
    .get(dropId, playerId) as unknown as DropRow | undefined;
  return row ? hydrate(row) : null;
}

export function recentDrops(playerId: string, limit = 20): PlinkoDrop[] {
  const rows = db
    .prepare(`SELECT * FROM plinko_drop WHERE player_id = ? ORDER BY created_at DESC, rowid DESC LIMIT ?`)
    .all(playerId, limit) as unknown as DropRow[];
  return rows.map(hydrate);
}

/**
 * Spend one monster and drop the orb.
 *
 * Order matters: the monster is consumed first, so a drop that cannot be paid
 * for never produces a result. Everything after that is decided in this call
 * and written down before it returns — there is no window in which the player
 * owns neither the monster nor its outcome.
 */
export function drop(playerId: string, wagerDropId: string, now = Date.now()): PlinkoDrop {
  const session = stateFor(playerId);
  // Through the mutation service (#133): consume + ledger row, atomically.
  let wager: StoredDrop;
  try {
    wager = wagerDrops(playerId, [wagerDropId], "plinko")[0];
  } catch {
    throw new Error(PLINKO_ERRORS.WAGER_UNAVAILABLE);
  }

  const pair = session.current;
  const nonce = session.consumeNonce();
  const rollAt = (cursor: number) => roll(pair.serverSeed, pair.clientSeed, nonce, cursor);

  const path = dropPath(rollAt);
  const slot = slotForPath(path);
  const multiplier = multiplierForSlot(slot);
  const finalNetWorth = computeFinalNetWorth(wager.value, multiplier);
  const fairness = session.fairnessFor(pair, nonce);

  // A 0x landing is a real outcome, not a failure: the monster is spent and
  // nothing is minted.
  let reward: (StoredDrop & { budget: number; overflowed?: boolean }) | null = null;
  if (finalNetWorth > 0) {
    const prize: MonsterReward = rewardFor(
      finalNetWorth,
      rollAt(PLINKO_CURSOR.rewardCharacter),
      rollAt(PLINKO_CURSOR.rewardPower)
    );
    const { drop: stored, overflowed } = payoutDrop(playerId, {
      crateId: "plinko",
      character: prize.character,
      stars: prize.stars,
      baseMintValue: prize.baseMintValue,
      value: prize.value,
      rolls: {
        rarity: 0,
        character: rollAt(PLINKO_CURSOR.rewardCharacter),
        mintSegment: -1,
        mintPosition: rollAt(PLINKO_CURSOR.rewardPower)
      },
      fairness,
      openedAt: new Date(now).toISOString()
    }, "plinko");
    reward = { ...stored, budget: prize.budget, overflowed };
  }

  const resolved: PlinkoDrop = {
    dropId: randomUUID(),
    playerId,
    wager,
    wagerValue: wager.value,
    path,
    slot,
    multiplier,
    finalNetWorth,
    reward,
    createdAt: new Date(now).toISOString(),
    fairness
  };
  persist(resolved);
  return resolved;
}
