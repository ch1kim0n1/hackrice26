// Portal Wheel spin resolution: the authoritative part.
//
// Like Plinko and unlike the cauldron, there is no live round: one call spends
// the monster, stops the pointer, prices the result and mints the reward before
// the client has drawn a frame. There is nothing to race and nothing to
// withhold — the winning section is sent back precisely so the wheel on screen
// can spin to it.
//
// What has to hold, exactly as in the other games:
//
//   - The monster leaves the inventory and never comes back, whatever the
//     pointer does (spec §13). A wrong colour destroys it and pays nothing.
//   - The colour is locked before the spin. It is read from the request that
//     committed the wager, so there is no later request that could change it.
//   - Nothing about the wager touches the odds. `spinSection` is handed a roll
//     function and nothing else (spec §21).

import { randomUUID } from "crypto";
import { db } from "../db";
import { PortalColor } from "../data/portalWheel";
import { Fairness } from "../types";
import {
  PORTAL_WHEEL_CURSOR,
  colorAtSection,
  finalNetWorth as computeFinalNetWorth,
  multiplierFor,
  spinSection
} from "./portalWheelEngine";
import { MonsterReward, rewardFor } from "../game/rewards";
import { roll } from "./lootboxEngine";
import { StoredDrop, stateFor } from "./lootboxState";
import { payoutDrop, wagerDrops } from "./characterMutations";

export const PORTAL_WHEEL_ERRORS = {
  WAGER_UNAVAILABLE: "PORTAL_WHEEL_WAGER_UNAVAILABLE",
  BAD_COLOR: "PORTAL_WHEEL_BAD_COLOR",
  SPIN_NOT_FOUND: "PORTAL_WHEEL_SPIN_NOT_FOUND"
} as const;

export interface PortalWheelSpin {
  spinId: string;
  playerId: string;
  wager: StoredDrop;
  wagerValue: number;
  /** The colour the player committed to. */
  pick: PortalColor;
  /** Which of the sixteen sections the pointer stopped on. */
  section: number;
  winningColor: PortalColor;
  won: boolean;
  /**
   * What the chosen colour was quoted at, frozen at spin time.
   *
   * Stored rather than re-derived because the layout is tunable: a wheel
   * rebalanced next month must not silently restate what an old spin paid.
   */
  multiplier: number;
  finalNetWorth: number;
  /** null on a wrong colour — the monster is spent, nothing returns. */
  reward: (StoredDrop & { budget: number }) | null;
  createdAt: string;
  fairness: Fairness;
}

interface SpinRow {
  spin_id: string;
  player_id: string;
  wager: string;
  wager_value: number;
  pick: string;
  section: number;
  winning_color: string;
  won: number;
  multiplier: number;
  final_net_worth: number;
  reward: string | null;
  created_at: string;
  fairness: string;
}

function hydrate(row: SpinRow): PortalWheelSpin {
  return {
    spinId: row.spin_id,
    playerId: row.player_id,
    wager: JSON.parse(row.wager) as StoredDrop,
    wagerValue: row.wager_value,
    pick: row.pick as PortalColor,
    section: row.section,
    winningColor: row.winning_color as PortalColor,
    won: row.won === 1,
    multiplier: row.multiplier,
    finalNetWorth: row.final_net_worth,
    reward: row.reward ? (JSON.parse(row.reward) as StoredDrop & { budget: number }) : null,
    createdAt: row.created_at,
    fairness: JSON.parse(row.fairness) as Fairness
  };
}

function persist(spin: PortalWheelSpin): void {
  db.prepare(
    `INSERT INTO portal_wheel_spin (
       spin_id, player_id, wager, wager_value, pick, section, winning_color,
       won, multiplier, final_net_worth, reward, created_at, fairness
     ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`
  ).run(
    spin.spinId,
    spin.playerId,
    JSON.stringify(spin.wager),
    spin.wagerValue,
    spin.pick,
    spin.section,
    spin.winningColor,
    spin.won ? 1 : 0,
    spin.multiplier,
    spin.finalNetWorth,
    spin.reward ? JSON.stringify(spin.reward) : null,
    spin.createdAt,
    JSON.stringify(spin.fairness)
  );
}

export function spinById(playerId: string, spinId: string): PortalWheelSpin | null {
  const row = db
    .prepare(`SELECT * FROM portal_wheel_spin WHERE spin_id = ? AND player_id = ?`)
    .get(spinId, playerId) as unknown as SpinRow | undefined;
  return row ? hydrate(row) : null;
}

export function recentSpins(playerId: string, limit = 20): PortalWheelSpin[] {
  const rows = db
    .prepare(
      `SELECT * FROM portal_wheel_spin WHERE player_id = ? ORDER BY created_at DESC, rowid DESC LIMIT ?`
    )
    .all(playerId, limit) as unknown as SpinRow[];
  return rows.map(hydrate);
}

/**
 * Spend one monster and spin the wheel.
 *
 * Order matters: the monster is consumed first, so a spin that cannot be paid
 * for never produces a result. Everything after that is decided in this call
 * and written down before it returns — there is no window in which the player
 * owns neither the monster nor its outcome, and no refresh, reconnect or app
 * relaunch that could put the wager back (spec §13).
 */
export function spin(
  playerId: string,
  wagerDropId: string,
  pick: PortalColor,
  now = Date.now()
): PortalWheelSpin {
  const session = stateFor(playerId);
  // Through the mutation service (#133): consume + ledger row, atomically.
  let wager: StoredDrop;
  try {
    wager = wagerDrops(playerId, [wagerDropId], "portal-wheel")[0];
  } catch {
    throw new Error(PORTAL_WHEEL_ERRORS.WAGER_UNAVAILABLE);
  }

  const pair = session.current;
  const nonce = session.consumeNonce();
  const rollAt = (cursor: number) => roll(pair.serverSeed, pair.clientSeed, nonce, cursor);

  const section = spinSection(rollAt);
  const winningColor = colorAtSection(section);
  const won = winningColor === pick;
  // The quoted price of the bet, win or lose. On a loss it is what was passed
  // up, which is worth recording; it is never paid.
  const multiplier = multiplierFor(pick);
  const finalNetWorth = computeFinalNetWorth(wager.value, multiplier, won);
  const fairness = session.fairnessFor(pair, nonce);

  // A wrong colour is a real outcome, not a failure: the monster is spent and
  // nothing is minted.
  let reward: (StoredDrop & { budget: number }) | null = null;
  if (finalNetWorth > 0) {
    const prize: MonsterReward = rewardFor(
      finalNetWorth,
      rollAt(PORTAL_WHEEL_CURSOR.rewardCharacter),
      rollAt(PORTAL_WHEEL_CURSOR.rewardPower)
    );
    const stored = payoutDrop(playerId, {
      crateId: "portal-wheel",
      character: prize.character,
      stars: prize.stars,
      power: prize.power,
      powerLabel: prize.powerLabel,
      shiny: prize.shiny,
      value: prize.value,
      rolls: {
        rarity: 0,
        character: rollAt(PORTAL_WHEEL_CURSOR.rewardCharacter),
        power: rollAt(PORTAL_WHEEL_CURSOR.rewardPower),
        shiny: 0
      },
      fairness,
      openedAt: new Date(now).toISOString()
    }, "portal-wheel");
    reward = { ...stored, budget: prize.budget };
  }

  const resolved: PortalWheelSpin = {
    spinId: randomUUID(),
    playerId,
    wager,
    wagerValue: wager.value,
    pick,
    section,
    winningColor,
    won,
    multiplier,
    finalNetWorth,
    reward,
    createdAt: new Date(now).toISOString(),
    fairness
  };
  persist(resolved);
  return resolved;
}
