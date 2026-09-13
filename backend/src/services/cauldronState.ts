// Cauldron Crash round lifecycle: the authoritative, transactional part.
//
// Real owned monsters are destroyed here, so the rules are deliberately
// unforgiving (spec §18):
//
//   - The wager leaves the inventory the moment the round starts. A locked
//     monster is one that is no longer there to sell, fuse, or wager again.
//   - One active round per player. Starting a second is refused, which is what
//     stops the same monster being spent twice by two racing requests.
//   - The crash point is fixed at start and written down before the multiplier
//     moves. Nothing that happens afterwards — a disconnect, an app restart, a
//     redeploy — can change it.
//   - A round resolves exactly once. Cashing out twice, or cashing out a round
//     that already crashed, changes nothing and returns what actually happened.
//
// The clock is the only live input: the multiplier is derived from how long
// ago the round started, so a client that stops asking simply finds out later.

import { randomUUID } from "crypto";
import { MAX_ROUND_AGE_MS } from "../data/cauldron";
import { db } from "../db";
import { Fairness } from "../types";
import {
  CAULDRON_CURSOR,
  CauldronReward,
  cashOutValue,
  crashPointFrom,
  elapsedForMultiplier,
  isWagerSizeLegal,
  multiplierAt,
  rewardFor,
  startingNetWorth
} from "./cauldronEngine";
import { roll } from "./lootboxEngine";
import { StoredDrop, stateFor } from "./lootboxState";
import { payoutDrop, wagerDrops } from "./characterMutations";

export type CauldronRoundStatus = "ACTIVE" | "CASHED_OUT" | "CRASHED";

/** Operational failures. Routes map these to status codes. */
export const CAULDRON_ERRORS = {
  WAGER_SIZE: "CAULDRON_WAGER_SIZE",
  WAGER_UNAVAILABLE: "CAULDRON_WAGER_UNAVAILABLE",
  ROUND_IN_PROGRESS: "CAULDRON_ROUND_IN_PROGRESS",
  ROUND_NOT_FOUND: "CAULDRON_ROUND_NOT_FOUND"
} as const;

export interface CauldronRound {
  roundId: string;
  playerId: string;
  /** The monsters that went in. Kept on the round because they are gone from
   *  the inventory — this is the only remaining record of them. */
  wager: StoredDrop[];
  startingNetWorth: number;
  /** Hidden while the round is ACTIVE. Never include it in a live payload. */
  crashMultiplier: number;
  status: CauldronRoundStatus;
  startedAt: string;
  cashOutAt: string | null;
  cashOutMultiplier: number | null;
  finalNetWorth: number | null;
  reward: (StoredDrop & { budget: number; overflowed?: boolean }) | null;
  completedAt: string | null;
  fairness: Fairness;
}

interface RoundRow {
  round_id: string;
  player_id: string;
  wager: string;
  starting_net_worth: number;
  crash_multiplier: number;
  status: string;
  started_at: string;
  cash_out_at: string | null;
  cash_out_multiplier: number | null;
  final_net_worth: number | null;
  reward: string | null;
  completed_at: string | null;
  fairness: string;
}

function hydrate(row: RoundRow): CauldronRound {
  return {
    roundId: row.round_id,
    playerId: row.player_id,
    wager: JSON.parse(row.wager) as StoredDrop[],
    startingNetWorth: row.starting_net_worth,
    crashMultiplier: row.crash_multiplier,
    status: row.status as CauldronRoundStatus,
    startedAt: row.started_at,
    cashOutAt: row.cash_out_at,
    cashOutMultiplier: row.cash_out_multiplier,
    finalNetWorth: row.final_net_worth,
    reward: row.reward ? (JSON.parse(row.reward) as StoredDrop & { budget: number }) : null,
    completedAt: row.completed_at,
    fairness: JSON.parse(row.fairness) as Fairness
  };
}

function persist(round: CauldronRound): void {
  db.prepare(
    `INSERT INTO cauldron_round (
       round_id, player_id, wager, starting_net_worth, crash_multiplier, status,
       started_at, cash_out_at, cash_out_multiplier, final_net_worth, reward, completed_at, fairness
     ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
     ON CONFLICT(round_id) DO UPDATE SET
       status = excluded.status,
       cash_out_at = excluded.cash_out_at,
       cash_out_multiplier = excluded.cash_out_multiplier,
       final_net_worth = excluded.final_net_worth,
       reward = excluded.reward,
       completed_at = excluded.completed_at`
  ).run(
    round.roundId,
    round.playerId,
    JSON.stringify(round.wager),
    round.startingNetWorth,
    round.crashMultiplier,
    round.status,
    round.startedAt,
    round.cashOutAt,
    round.cashOutMultiplier,
    round.finalNetWorth,
    round.reward ? JSON.stringify(round.reward) : null,
    round.completedAt,
    JSON.stringify(round.fairness)
  );
}

/** When this round's cauldron blows up, in wall-clock ms. */
export function crashAtMs(round: CauldronRound): number {
  return Date.parse(round.startedAt) + elapsedForMultiplier(round.crashMultiplier);
}

/** The multiplier a live round is showing at `now`, capped at its crash point. */
export function liveMultiplier(round: CauldronRound, now: number): number {
  const shown = multiplierAt(now - Date.parse(round.startedAt));
  return Math.min(shown, round.crashMultiplier);
}

/**
 * Resolve a round whose crash point has passed.
 *
 * This is what makes closing the app mid-round safe to reason about: the
 * outcome was decided when the round started, and the first request to arrive
 * after the crash time simply writes down what already happened. Nothing is
 * refunded and nothing is auto-cashed-out (spec §19).
 */
export function settle(round: CauldronRound, now = Date.now()): CauldronRound {
  if (round.status !== "ACTIVE") return round;
  const age = now - Date.parse(round.startedAt);
  if (now < crashAtMs(round) && age < MAX_ROUND_AGE_MS) return round;

  const crashed: CauldronRound = {
    ...round,
    status: "CRASHED",
    completedAt: new Date(Math.min(now, crashAtMs(round) + MAX_ROUND_AGE_MS)).toISOString()
  };
  persist(crashed);
  return crashed;
}

/** The player's live round, if any. Settles it first, so an ACTIVE round
 *  returned from here is genuinely still running. */
export function activeRound(playerId: string, now = Date.now()): CauldronRound | null {
  const row = db
    .prepare(`SELECT * FROM cauldron_round WHERE player_id = ? AND status = 'ACTIVE' LIMIT 1`)
    .get(playerId) as unknown as RoundRow | undefined;
  if (!row) return null;
  const settled = settle(hydrate(row), now);
  return settled.status === "ACTIVE" ? settled : null;
}

export function roundById(playerId: string, roundId: string): CauldronRound | null {
  const row = db
    .prepare(`SELECT * FROM cauldron_round WHERE round_id = ? AND player_id = ?`)
    .get(roundId, playerId) as unknown as RoundRow | undefined;
  return row ? hydrate(row) : null;
}

export function recentRounds(playerId: string, limit = 20): CauldronRound[] {
  const rows = db
    .prepare(
      `SELECT * FROM cauldron_round WHERE player_id = ? ORDER BY started_at DESC LIMIT ?`
    )
    .all(playerId, limit) as unknown as RoundRow[];
  return rows.map(hydrate);
}

/**
 * Lock a wager and start the multiplier.
 *
 * The crash point is drawn here, from the player's commit-reveal seed pair
 * (the same one the crates use), and the wagered monsters leave the inventory
 * in the same call. Order matters: the drops are consumed first, so a wager
 * that cannot be paid for never produces a round.
 */
export function startRound(playerId: string, dropIds: string[], now = Date.now()): CauldronRound {
  if (!isWagerSizeLegal(dropIds.length)) throw new Error(CAULDRON_ERRORS.WAGER_SIZE);
  if (activeRound(playerId, now)) throw new Error(CAULDRON_ERRORS.ROUND_IN_PROGRESS);

  let wager: StoredDrop[];
  try {
    // Through the mutation service (#133): consume + ledger, one transaction.
    wager = wagerDrops(playerId, dropIds, "cauldron-crash");
  } catch {
    throw new Error(CAULDRON_ERRORS.WAGER_UNAVAILABLE);
  }
  const session = stateFor(playerId);

  const pair = session.current;
  const nonce = session.consumeNonce();
  const crashMultiplier = crashPointFrom(
    roll(pair.serverSeed, pair.clientSeed, nonce, CAULDRON_CURSOR.crash)
  );

  const round: CauldronRound = {
    roundId: randomUUID(),
    playerId,
    wager,
    startingNetWorth: startingNetWorth(wager.map((drop) => drop.value)),
    crashMultiplier,
    status: "ACTIVE",
    startedAt: new Date(now).toISOString(),
    cashOutAt: null,
    cashOutMultiplier: null,
    finalNetWorth: null,
    reward: null,
    completedAt: null,
    fairness: session.fairnessFor(pair, nonce)
  };
  persist(round);
  return round;
}

/**
 * Take the money.
 *
 * The multiplier paid is the one the *server* reads off its own clock when the
 * request lands — never a number the client sent. If the crash point has
 * already passed, this is simply the request that discovers it, and the wager
 * is gone.
 */
export function cashOut(playerId: string, roundId: string, now = Date.now()): CauldronRound {
  const existing = roundById(playerId, roundId);
  if (!existing) throw new Error(CAULDRON_ERRORS.ROUND_NOT_FOUND);

  // A resolved round is final. Returning it (rather than erroring) makes a
  // retried or duplicated cash-out a no-op instead of a second payout.
  const round = settle(existing, now);
  if (round.status !== "ACTIVE") return round;

  const multiplier = liveMultiplier(round, now);
  const finalNetWorth = cashOutValue(round.startingNetWorth, multiplier);

  const session = stateFor(playerId);
  // The round's OWN seed pair, matched by the hash it disclosed at start —
  // a rotation mid-round must not change what the reward rolls derive from,
  // or the disclosed fairness values stop matching the roll.
  const pair = session.pairForHash(round.fairness.serverSeedHash);
  const prize: CauldronReward = rewardFor(
    finalNetWorth,
    roll(pair.serverSeed, round.fairness.clientSeed, round.fairness.nonce, CAULDRON_CURSOR.rewardCharacter),
    roll(pair.serverSeed, round.fairness.clientSeed, round.fairness.nonce, CAULDRON_CURSOR.rewardPower)
  );

  const { drop: stored, overflowed } = payoutDrop(playerId, {
    crateId: "cauldron-crash",
    character: prize.character,
    // Crash is rarity progression, not mastery: the reward always starts at
    // one star however large the pot was (spec §11).
    stars: prize.stars,
    baseMintValue: prize.baseMintValue,
    value: prize.value,
    // The round's own rolls, disclosed like a cookbook open's. No segment was
    // rolled — the budget priced the mint — so mintSegment records -1.
    rolls: {
      rarity: roll(pair.serverSeed, round.fairness.clientSeed, round.fairness.nonce, CAULDRON_CURSOR.crash),
      character: roll(pair.serverSeed, round.fairness.clientSeed, round.fairness.nonce, CAULDRON_CURSOR.rewardCharacter),
      mintSegment: -1,
      mintPosition: roll(pair.serverSeed, round.fairness.clientSeed, round.fairness.nonce, CAULDRON_CURSOR.rewardPower)
    },
    fairness: round.fairness,
    openedAt: new Date(now).toISOString()
  }, "cauldron-crash");

  const cashed: CauldronRound = {
    ...round,
    status: "CASHED_OUT",
    cashOutAt: new Date(now).toISOString(),
    cashOutMultiplier: multiplier,
    finalNetWorth,
    reward: { ...stored, budget: prize.budget, overflowed },
    completedAt: new Date(now).toISOString()
  };
  persist(cashed);
  return cashed;
}
