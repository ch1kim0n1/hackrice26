// Kitchen Mines round lifecycle: the authoritative, transactional part.
//
// Same contract as Cauldron Crash, because it destroys real owned monsters for
// the same reasons:
//
//   - The wager leaves the inventory when the round starts. A committed
//     monster is one that is no longer there to sell, fuse, or wager again.
//   - One active round per player, so the same monster cannot be spent twice
//     by two racing requests.
//   - The board is fixed at start and written down before the first dish is
//     lifted. Nothing afterwards -- a disconnect, a restart, a replayed
//     request -- can move a mine.
//   - A round resolves exactly once. Cashing out twice, or cashing out a
//     burnt board, changes nothing and returns what actually happened.
//
// The layout never leaves this module while a round is live. `publicRound()`
// in routes/mines.ts is the only shape the client sees.

import { randomUUID } from "crypto";
import { MAX_ROUND_AGE_MS, TILE_COUNT } from "../data/mines";
import { db } from "../db";
import { Fairness } from "../types";
import {
  MINES_CURSOR,
  isMineCountLegal,
  isTileIndexLegal,
  mineLayout,
  multiplierAfter,
  potValue,
  safeTiles
} from "./minesEngine";
import { MonsterReward, rewardFor } from "../game/rewards";
import { roll } from "./lootboxEngine";
import { StoredDrop, stateFor } from "./lootboxState";
import { payoutDrop, wagerDrops } from "./characterMutations";

export type MinesRoundStatus = "ACTIVE" | "SERVED" | "BURNT";

export const MINES_ERRORS = {
  MINE_COUNT: "MINES_BAD_MINE_COUNT",
  WAGER_UNAVAILABLE: "MINES_WAGER_UNAVAILABLE",
  ROUND_IN_PROGRESS: "MINES_ROUND_IN_PROGRESS",
  ROUND_NOT_FOUND: "MINES_ROUND_NOT_FOUND",
  ROUND_OVER: "MINES_ROUND_OVER",
  BAD_TILE: "MINES_BAD_TILE",
  TILE_ALREADY_REVEALED: "MINES_TILE_ALREADY_REVEALED"
} as const;

export interface MinesRound {
  roundId: string;
  playerId: string;
  wager: StoredDrop;
  wagerValue: number;
  mines: number;
  /** Hidden while the round is ACTIVE. Never put this in a live payload. */
  layout: number[];
  /** Safe tiles the player has turned over, in order. */
  revealed: number[];
  status: MinesRoundStatus;
  startedAt: string;
  cashOutMultiplier: number | null;
  finalNetWorth: number | null;
  reward: (StoredDrop & { budget: number }) | null;
  completedAt: string | null;
  fairness: Fairness;
}

interface RoundRow {
  round_id: string;
  player_id: string;
  wager: string;
  wager_value: number;
  mines: number;
  layout: string;
  revealed: string;
  status: string;
  started_at: string;
  cash_out_multiplier: number | null;
  final_net_worth: number | null;
  reward: string | null;
  completed_at: string | null;
  fairness: string;
}

function hydrate(row: RoundRow): MinesRound {
  return {
    roundId: row.round_id,
    playerId: row.player_id,
    wager: JSON.parse(row.wager) as StoredDrop,
    wagerValue: row.wager_value,
    mines: row.mines,
    layout: JSON.parse(row.layout) as number[],
    revealed: JSON.parse(row.revealed) as number[],
    status: row.status as MinesRoundStatus,
    startedAt: row.started_at,
    cashOutMultiplier: row.cash_out_multiplier,
    finalNetWorth: row.final_net_worth,
    reward: row.reward ? (JSON.parse(row.reward) as StoredDrop & { budget: number }) : null,
    completedAt: row.completed_at,
    fairness: JSON.parse(row.fairness) as Fairness
  };
}

function persist(round: MinesRound): void {
  db.prepare(
    `INSERT INTO mines_round (
       round_id, player_id, wager, wager_value, mines, layout, revealed, status,
       started_at, cash_out_multiplier, final_net_worth, reward, completed_at, fairness
     ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
     ON CONFLICT(round_id) DO UPDATE SET
       revealed = excluded.revealed,
       status = excluded.status,
       cash_out_multiplier = excluded.cash_out_multiplier,
       final_net_worth = excluded.final_net_worth,
       reward = excluded.reward,
       completed_at = excluded.completed_at`
  ).run(
    round.roundId,
    round.playerId,
    JSON.stringify(round.wager),
    round.wagerValue,
    round.mines,
    JSON.stringify(round.layout),
    JSON.stringify(round.revealed),
    round.status,
    round.startedAt,
    round.cashOutMultiplier,
    round.finalNetWorth,
    round.reward ? JSON.stringify(round.reward) : null,
    round.completedAt,
    JSON.stringify(round.fairness)
  );
}

/** The multiplier this round is currently standing on. */
export function currentMultiplier(round: MinesRound): number {
  return multiplierAfter(round.mines, round.revealed.length);
}

/** Has the player turned over every safe dish there is? */
export function isBoardCleared(round: MinesRound): boolean {
  return round.revealed.length >= safeTiles(round.mines);
}

/**
 * Abandon a round left running far too long.
 *
 * Unlike the cauldron there is no clock pressure here -- a Mines board waits
 * forever -- so this only exists to stop a forgotten round blocking the
 * player's next one. It resolves as BURNT: the wager was already consumed, and
 * silently refunding it would make "start a round and walk away" a way to try
 * boards for free.
 */
export function settle(round: MinesRound, now = Date.now()): MinesRound {
  if (round.status !== "ACTIVE") return round;
  if (now - Date.parse(round.startedAt) < MAX_ROUND_AGE_MS) return round;

  const abandoned: MinesRound = {
    ...round,
    status: "BURNT",
    completedAt: new Date(now).toISOString()
  };
  persist(abandoned);
  return abandoned;
}

export function activeRound(playerId: string, now = Date.now()): MinesRound | null {
  const row = db
    .prepare(`SELECT * FROM mines_round WHERE player_id = ? AND status = 'ACTIVE' LIMIT 1`)
    .get(playerId) as unknown as RoundRow | undefined;
  if (!row) return null;
  const settled = settle(hydrate(row), now);
  return settled.status === "ACTIVE" ? settled : null;
}

export function roundById(playerId: string, roundId: string): MinesRound | null {
  const row = db
    .prepare(`SELECT * FROM mines_round WHERE round_id = ? AND player_id = ?`)
    .get(roundId, playerId) as unknown as RoundRow | undefined;
  return row ? hydrate(row) : null;
}

export function recentRounds(playerId: string, limit = 20): MinesRound[] {
  const rows = db
    .prepare(`SELECT * FROM mines_round WHERE player_id = ? ORDER BY started_at DESC LIMIT ?`)
    .all(playerId, limit) as unknown as RoundRow[];
  return rows.map(hydrate);
}

/**
 * Commit one monster and lay the board.
 *
 * The layout is drawn from the player's commit-reveal seed pair -- the same
 * chain the crates and the cauldron use -- so the board was determined by a
 * secret the server had already published a hash of, and can be checked once
 * that seed is rotated.
 */
export function startRound(
  playerId: string,
  dropId: string,
  mines: number,
  now = Date.now()
): MinesRound {
  if (!isMineCountLegal(mines)) throw new Error(MINES_ERRORS.MINE_COUNT);
  if (activeRound(playerId, now)) throw new Error(MINES_ERRORS.ROUND_IN_PROGRESS);

  let wager: StoredDrop;
  try {
    // Through the mutation service (#133): consume + ledger, one transaction.
    wager = wagerDrops(playerId, [dropId], "kitchen-mines")[0];
  } catch {
    throw new Error(MINES_ERRORS.WAGER_UNAVAILABLE);
  }
  const session = stateFor(playerId);

  const pair = session.current;
  const nonce = session.consumeNonce();
  const layout = mineLayout(mines, (cursor) => roll(pair.serverSeed, pair.clientSeed, nonce, cursor));

  const round: MinesRound = {
    roundId: randomUUID(),
    playerId,
    wager,
    wagerValue: wager.value,
    mines,
    layout,
    revealed: [],
    status: "ACTIVE",
    startedAt: new Date(now).toISOString(),
    cashOutMultiplier: null,
    finalNetWorth: null,
    reward: null,
    completedAt: null,
    fairness: session.fairnessFor(pair, nonce)
  };
  persist(round);
  return round;
}

export interface RevealResult {
  round: MinesRound;
  /** What was under the dish the player just lifted. */
  tile: number;
  safe: boolean;
}

/**
 * Lift one dish.
 *
 * The answer was decided at `startRound`; this only looks it up and writes
 * down what happened. A burnt tile ends the round on the spot -- the wager is
 * already gone, so there is nothing to take.
 */
export function reveal(
  playerId: string,
  roundId: string,
  tile: number,
  now = Date.now()
): RevealResult {
  const existing = roundById(playerId, roundId);
  if (!existing) throw new Error(MINES_ERRORS.ROUND_NOT_FOUND);
  if (!isTileIndexLegal(tile)) throw new Error(MINES_ERRORS.BAD_TILE);

  const round = settle(existing, now);
  if (round.status !== "ACTIVE") throw new Error(MINES_ERRORS.ROUND_OVER);
  if (round.revealed.includes(tile)) throw new Error(MINES_ERRORS.TILE_ALREADY_REVEALED);

  if (round.layout.includes(tile)) {
    const burnt: MinesRound = {
      ...round,
      status: "BURNT",
      // The losing tile joins the record so the result screen can show which
      // dish ended it, but it is NOT a safe reveal and never pays.
      cashOutMultiplier: currentMultiplier(round),
      completedAt: new Date(now).toISOString()
    };
    persist(burnt);
    return { round: burnt, tile, safe: false };
  }

  const advanced: MinesRound = { ...round, revealed: [...round.revealed, tile] };
  persist(advanced);
  return { round: advanced, tile, safe: true };
}

/**
 * Serve the dish: take the multiplier and buy a monster with it.
 *
 * Cashing out at zero reveals is legal and pays 1.00x -- the player gets a
 * monster worth what they wagered. It is a strange thing to do, but refusing
 * it would mean the first pick is compulsory, which is a different game.
 */
export function cashOut(playerId: string, roundId: string, now = Date.now()): MinesRound {
  const existing = roundById(playerId, roundId);
  if (!existing) throw new Error(MINES_ERRORS.ROUND_NOT_FOUND);

  // A resolved round is final. Returning it makes a retried cash-out a no-op
  // rather than a second payout.
  const round = settle(existing, now);
  if (round.status !== "ACTIVE") return round;

  const multiplier = currentMultiplier(round);
  const finalNetWorth = potValue(round.wagerValue, multiplier);

  const session = stateFor(playerId);
  // The round's OWN seed pair, matched by the hash it disclosed at start —
  // a rotation mid-round must not change what the reward rolls derive from.
  const pair = session.pairForHash(round.fairness.serverSeedHash);
  const prize: MonsterReward = rewardFor(
    finalNetWorth,
    roll(pair.serverSeed, round.fairness.clientSeed, round.fairness.nonce, MINES_CURSOR.rewardCharacter),
    roll(pair.serverSeed, round.fairness.clientSeed, round.fairness.nonce, MINES_CURSOR.rewardPower)
  );

  const stored = payoutDrop(playerId, {
    crateId: "kitchen-mines",
    character: prize.character,
    stars: prize.stars,
    power: prize.power,
    powerLabel: prize.powerLabel,
    shiny: prize.shiny,
    value: prize.value,
    rolls: {
      rarity: 0,
      character: roll(pair.serverSeed, round.fairness.clientSeed, round.fairness.nonce, MINES_CURSOR.rewardCharacter),
      power: roll(pair.serverSeed, round.fairness.clientSeed, round.fairness.nonce, MINES_CURSOR.rewardPower),
      shiny: 0
    },
    fairness: round.fairness,
    openedAt: new Date(now).toISOString()
  }, "kitchen-mines");

  const served: MinesRound = {
    ...round,
    status: "SERVED",
    cashOutMultiplier: multiplier,
    finalNetWorth,
    reward: { ...stored, budget: prize.budget },
    completedAt: new Date(now).toISOString()
  };
  persist(served);
  return served;
}

/** Tiles never turned over. Only ever disclosed once a round is finished. */
export function unrevealedTiles(round: MinesRound): number[] {
  return Array.from({ length: TILE_COUNT }, (_, i) => i).filter(
    (tile) => !round.revealed.includes(tile)
  );
}
