// Atomic character lifecycle mutations (issue #133).
//
// One transactional entry point for everything that creates, destroys, locks,
// or transfers an owned monster: merge, sell, gamble stake/payout, and arena
// battle stakes. Every op runs inside BEGIN IMMEDIATE, so a mutation either
// commits fully — drops moved, coins credited, ledger rows written — or not
// at all, and two racing requests cannot both spend the same monster because
// the second one's lock acquisition waits on the first's write lock.
//
// Two ledgers are written:
//   - coin_ledger    (007): the money. Positive rows only, so no balance
//                    check is needed inside the caller's transaction.
//   - character_ledger (008): the audit. Every value-bearing change names
//                    the drops it touched, so "no double-spend" is provable
//                    rather than asserted.

import { randomUUID } from "crypto";
import { db } from "../db";
import {
  FUSION_COPIES_PER_LEVEL,
  MAX_STAR_LEVEL,
  StarLevel,
  asStarLevel
} from "../game/rarityBands";
import { SELL_RATE, revalueFromTotal } from "../game/revaluation";
import { CoinReason } from "./coins";
import { Rarity } from "../types";
import { StoredDrop, stateFor } from "./lootboxState";
import { hasDatabaseUrl } from "../db/pg";
import { enqueueMirror } from "./mirrorQueue";

export type MutationKind =
  | "merge"
  | "sell"
  | "gamble_stake"
  | "gamble_payout"
  | "battle_stake"
  | "battle_payout"
  | "battle_refund";

/** Arena settlement: the house burns this share of a coin-equivalent payout. */
export const ARENA_BURN = 0.05;

export const MUTATION_ERRORS = {
  NOT_OWNED: "NOT_OWNED",
  LOCKED: "LOCKED",
  MAX_STAR: "MAX_STAR",
  MISMATCH: "MISMATCH",
  RACE: "RACE",
  STAKE_NOT_FOUND: "STAKE_NOT_FOUND",
  STAKE_SETTLED: "STAKE_SETTLED",
  WORTHLESS: "WORTHLESS"
} as const;

/**
 * Run `fn` inside a single SQLite write transaction. BEGIN IMMEDIATE takes
 * the write lock up front, so a second mutator queues instead of reading
 * pre-mutation state — that is the "lock rows" half of the contract on a
 * single-file store.
 */
function transact<T>(fn: () => T): T {
  db.exec("BEGIN IMMEDIATE");
  try {
    const result = fn();
    db.exec("COMMIT");
    return result;
  } catch (err) {
    db.exec("ROLLBACK");
    throw err;
  }
}

/** Append the audit row. Called inside the mutation's own transaction. */
function ledger(playerId: string, kind: MutationKind, dropIds: string[], detail?: object): void {
  db.prepare(
    `INSERT INTO character_ledger (player_id, kind, drop_ids, detail) VALUES (?, ?, ?, ?)`
  ).run(playerId, kind, JSON.stringify(dropIds), detail ? JSON.stringify(detail) : null);
}

/**
 * Credit coins inside the caller's transaction — recordCoins() cannot be
 * used here because it opens its own BEGIN IMMEDIATE and SQLite rejects
 * nested write transactions. Credits only: a positive amount needs no
 * balance check, so the whole sale stays one commit.
 */
function creditCoins(playerId: string, amount: number, reason: CoinReason, refId: string | null): string {
  if (!Number.isInteger(amount) || amount <= 0) throw new Error(MUTATION_ERRORS.WORTHLESS);
  const id = randomUUID();
  const createdAt = new Date().toISOString();
  db.prepare(
    `INSERT INTO coin_ledger (id, player_id, amount, reason, ref_id, created_at)
     VALUES (?, ?, ?, ?, ?, ?)`
  ).run(id, playerId, amount, reason, refId, createdAt);
  // Mirror the credit to the authoritative Postgres ledger. Enqueued inside
  // the sale's own transaction, so the queue row and the coin row commit
  // together -- a sale that rolls back never queues a credit for coins the
  // player did not get.
  if (hasDatabaseUrl()) {
    enqueueMirror("coin_entry", id, {
      id, playerId, amount, reason, refId, createdAt
    });
  }
  return id;
}

/** Ledger rows for one player, newest first. Read path for tests + history. */
export function ledgerFor(playerId: string, limit = 50): { kind: MutationKind; dropIds: string[]; detail: object | null; createdAt: string }[] {
  const rows = db
    .prepare(`SELECT kind, drop_ids, detail, created_at FROM character_ledger WHERE player_id = ? ORDER BY seq DESC LIMIT ?`)
    .all(playerId, limit) as { kind: string; drop_ids: string; detail: string | null; created_at: string }[];
  return rows.map((r) => ({
    kind: r.kind as MutationKind,
    dropIds: JSON.parse(r.drop_ids) as string[],
    detail: r.detail ? (JSON.parse(r.detail) as object) : null,
    createdAt: r.created_at
  }));
}

/** Assert every id is an owned, unlocked monster; return them. */
function ownUnlocked(playerId: string, dropIds: string[]): StoredDrop[] {
  const session = stateFor(playerId);
  const found = dropIds.map((id) => session.dropById(id));
  if (found.some((d) => d === undefined)) throw new Error(MUTATION_ERRORS.NOT_OWNED);
  if (found.some((d) => d!.lockedBy)) throw new Error(MUTATION_ERRORS.LOCKED);
  return found as StoredDrop[];
}

/**
 * Consume a wager: the monsters leave the inventory up front and the gamble
 * keeps them in its own round record. Rejects locked (staked) monsters.
 */
export function wagerDrops(playerId: string, dropIds: string[], context: string): StoredDrop[] {
  return transact(() => {
    const wager = stateFor(playerId).consumeDrops(dropIds);
    if (!wager) throw new Error(MUTATION_ERRORS.NOT_OWNED);
    ledger(playerId, "gamble_stake", dropIds, { context, value: wager.reduce((s, d) => s + d.value, 0) });
    return wager;
  });
}

/** Pay a gamble win back into the inventory. */
export function payoutDrop(playerId: string, drop: Omit<StoredDrop, "id">, context: string): StoredDrop {
  return transact(() => {
    const stored = stateFor(playerId).record(drop);
    ledger(playerId, "gamble_payout", [stored.id], { context, value: stored.value });
    return stored;
  });
}

/**
 * Merge: three same-character, same-rarity, same-star, unlocked instances
 * become one instance at the next star. Atomic — either all three are
 * consumed and the merged drop exists, or nothing happened.
 *
 * Merging never changes rarity (net worth spec §14): the revaluation lives
 * in game/revaluation.ts, and `valuation.rarity` is the monster's own tier.
 */
export function mergeDrops(
  playerId: string,
  dropIds: string[]
): {
  merged: StoredDrop;
  consumedIds: string[];
  from: { star: number; count: number };
  to: { star: number; rarity: Rarity; value: number; power: number };
} {
  return transact(() => {
    const session = stateFor(playerId);
    const drops = ownUnlocked(playerId, dropIds);

    const characterId = drops[0].character.id;
    const rarity = drops[0].character.rarity;
    const star = asStarLevel(drops[0].stars);
    if (star >= MAX_STAR_LEVEL) throw new Error(MUTATION_ERRORS.MAX_STAR);
    if (!drops.every((d) => d.character.id === characterId)) throw new Error(MUTATION_ERRORS.MISMATCH);
    if (!drops.every((d) => d.character.rarity === rarity)) throw new Error(MUTATION_ERRORS.MISMATCH);
    if (!drops.every((d) => asStarLevel(d.stars) === star)) throw new Error(MUTATION_ERRORS.MISMATCH);

    const newStar = (star + 1) as StarLevel;
    const valuation = revalueFromTotal(Math.max(...drops.map((d) => d.value)), drops[0].character.rarity, star, newStar);

    const consumed = session.consumeDrops(dropIds);
    if (!consumed) throw new Error(MUTATION_ERRORS.RACE);

    const merged = session.record({
      // Keep the source's crateId so the client groups the fused monster
      // under the same card its copies lived on; the merge itself is
      // recorded in character_ledger.
      crateId: drops[0].crateId,
      character: { ...drops[0].character, rarity: valuation.rarity },
      stars: newStar,
      power: drops[0].power,
      powerLabel: drops[0].powerLabel,
      shiny: drops.some((d) => d.shiny),
      value: valuation.value,
      rolls: drops[0].rolls,
      fairness: drops[0].fairness,
      openedAt: new Date().toISOString()
    });

    ledger(playerId, "merge", dropIds, {
      mergedId: merged.id,
      fromStar: star,
      toStar: newStar,
      value: valuation.value,
      valueBand: valuation.valueBand
    });

    return {
      merged,
      consumedIds: consumed.map((d) => d.id),
      from: { star, count: consumed.length },
      to: { star: newStar, rarity: valuation.rarity, value: valuation.value, power: drops[0].power }
    };
  });
}

/**
 * Sell: monsters out, coins in. Pays the full current net worth (SELL_RATE =
 * 1 — selling is a conversion, not a haircut) into coin_ledger, inside the
 * same transaction that removes the drops. A zero-value monster refuses
 * rather than writing a no-op row.
 */
export function sellDrops(
  playerId: string,
  dropIds: string[]
): { sold: { drop: StoredDrop; netWorth: number; payout: number; entryId: string }[]; coins: number } {
  return transact(() => {
    const session = stateFor(playerId);
    const drops = ownUnlocked(playerId, dropIds);

    const sold = drops.map((drop) => {
      // `drop.value` is the monster's current total (base + star bonus
      // already folded in) -- feeding it straight in as `baseValue` would
      // have `revalue` add the star bonus a second time. `revalueFromTotal`
      // is the helper built for exactly this ("a monster already carrying a
      // total"): it recovers the base first, same as the merge path above.
      const valuation = revalueFromTotal(drop.value, drop.character.rarity, drop.stars, drop.stars ?? 1);
      const netWorth = valuation.value;
      const payout = Math.floor(netWorth * SELL_RATE);
      const entryId = creditCoins(playerId, payout, "sell", drop.id);
      return { drop, netWorth, payout, entryId };
    });
    const coins = sold.reduce((sum, s) => sum + s.payout, 0);

    const consumed = session.consumeDrops(dropIds);
    if (!consumed) throw new Error(MUTATION_ERRORS.RACE);

    ledger(playerId, "sell", dropIds, { coins });
    return { sold, coins };
  });
}

// ===== Arena escrow (issue #116) ===========================================

/**
 * Lock the challenger's stake. The monsters stay owned but un-spendable
 * until settleArena/refundArena runs. Fails if any id is already locked —
 * a monster can only be staked on one battle at a time.
 */
export function stakeDrops(playerId: string, dropIds: string[], battleId: string): StoredDrop[] {
  return transact(() => {
    const locked = stateFor(playerId).lockDrops(dropIds, `arena:${battleId}`);
    if (!locked) throw new Error(MUTATION_ERRORS.NOT_OWNED);
    db.prepare(
      `INSERT INTO arena_stake (battle_id, player_id, drop_ids, status) VALUES (?, ?, ?, 'LOCKED')`
    ).run(battleId, playerId, JSON.stringify(dropIds));
    ledger(playerId, "battle_stake", dropIds, { battleId });
    return locked;
  });
}

interface StakeRow {
  battle_id: string;
  player_id: string;
  drop_ids: string;
  status: string;
}

function lockedStake(battleId: string, playerId: string): StakeRow | null {
  const row = db
    .prepare(`SELECT * FROM arena_stake WHERE battle_id = ? AND player_id = ?`)
    .get(battleId, playerId) as StakeRow | undefined;
  if (!row) return null;
  if (row.status !== "LOCKED") throw new Error(MUTATION_ERRORS.STAKE_SETTLED);
  return row;
}

/**
 * Settle an arena battle (issue #116). One transaction:
 *
 *   - the winner's own stake unlocks and comes back untouched;
 *   - the loser's staked monsters transfer into the winner's inventory —
 *     "winner takes the stake" (docs/BATTLE-SYSTEM.md §Arena);
 *   - if the loser never staked (async arena: only the challenger puts
 *     monsters up), the winner instead takes the coin equivalent — coins
 *     priced at the winner's own stake value minus the 5% arena burn.
 *
 * A crash between unlock and transfer cannot leave a monster unowned or
 * duplicated.
 */
export function settleArena(
  battleId: string,
  winnerId: string,
  loserId: string
): { transferred: StoredDrop[]; coinsPaid: number } {
  return transact(() => {
    const winnerStake = lockedStake(battleId, winnerId);
    const loserStake = lockedStake(battleId, loserId);
    const winnerIds = winnerStake ? (JSON.parse(winnerStake.drop_ids) as string[]) : [];
    const loserIds = loserStake ? (JSON.parse(loserStake.drop_ids) as string[]) : [];

    const winnerSession = stateFor(winnerId);

    // Winner's own monsters come back untouched.
    if (winnerIds.length) winnerSession.unlockDrops(winnerIds);

    let transferred: StoredDrop[] = [];
    let coinsPaid = 0;
    if (loserIds.length) {
      // Loser's monsters change hands. removeDrops clears the lock as part
      // of removal; record() writes them under the winner with fresh ids.
      const lost = stateFor(loserId).removeDrops(loserIds);
      transferred = lost.map((drop) => {
        const { id: _oldId, lockedBy: _lockedBy, ...rest } = drop;
        return winnerSession.record(rest);
      });
      ledger(loserId, "battle_payout", loserIds, { battleId, to: winnerId });
      ledger(winnerId, "battle_payout", loserIds, { battleId, from: loserId });
    } else if (winnerIds.length) {
      // Coin equivalent: the winner's stake worth at its current valuation,
      // minus the arena burn.
      const stakeValue = winnerIds.reduce((sum, id) => {
        const d = winnerSession.dropById(id);
        if (!d) return sum;
        // Same fix as sellDrops: d.value is already a total, not a base.
        return sum + revalueFromTotal(d.value, d.character.rarity, d.stars, d.stars ?? 1).value;
      }, 0);
      coinsPaid = Math.floor(stakeValue * (1 - ARENA_BURN));
      if (coinsPaid > 0) creditCoins(winnerId, coinsPaid, "battle_win", battleId);
      ledger(winnerId, "battle_payout", winnerIds, { battleId, coinsPaid });
    }
    if (winnerIds.length) ledger(winnerId, "battle_refund", winnerIds, { battleId });

    const now = new Date().toISOString();
    db.prepare(`UPDATE arena_stake SET status = 'SETTLED', settled_at = ? WHERE battle_id = ? AND status = 'LOCKED'`).run(now, battleId);
    return { transferred, coinsPaid };
  });
}

/**
 * Self-heal escrows stranded by a crashed request. Arena battles resolve
 * synchronously inside the request, so a stake still LOCKED after
 * `maxAgeMinutes` can only mean the process died between stake and settle —
 * refund it before the player stakes again, or their monsters stay frozen
 * forever. Returns the number of stakes released.
 */
export function refundStaleArenaStakes(playerId: string, maxAgeMinutes = 10): number {
  const rows = db
    .prepare(
      `SELECT battle_id FROM arena_stake
       WHERE player_id = ? AND status = 'LOCKED'
         AND created_at < datetime('now', ?)`
    )
    .all(playerId, `-${Math.max(1, Math.floor(maxAgeMinutes))} minutes`) as { battle_id: string }[];
  for (const row of rows) refundArena(row.battle_id);
  return rows.length;
}

/**
 * Hand both sides their stake back (draw, cancelled challenge, opponent
 * vanished). Idempotent per side — settling twice is a no-op via the status
 * check rather than a double unlock.
 */
export function refundArena(battleId: string): void {
  transact(() => {
    const rows = db
      .prepare(`SELECT * FROM arena_stake WHERE battle_id = ? AND status = 'LOCKED'`)
      .all(battleId) as unknown as StakeRow[];
    for (const row of rows) {
      const ids = JSON.parse(row.drop_ids) as string[];
      stateFor(row.player_id).unlockDrops(ids);
      ledger(row.player_id, "battle_refund", ids, { battleId });
    }
    if (rows.length) {
      db.prepare(`UPDATE arena_stake SET status = 'REFUNDED', settled_at = ? WHERE battle_id = ? AND status = 'LOCKED'`)
        .run(new Date().toISOString(), battleId);
    }
  });
}
