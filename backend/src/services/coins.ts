// Coins: the soft currency characters are traded in.
//
// Append-only, exactly like the capsule ledger and its Postgres twin
// (app.currency_entries, backend/migrations/0004 + 0012, held append-only by
// 0018). A balance is never a column that gets
// decremented; it is `SUM(amount)` over rows that each name a reason and the
// thing they refer to. That is what makes a balance explainable after the fact
// and what makes "spend" safe under concurrency: two racing spends cannot both
// pass the same balance check, because the check and the write are one
// statement inside one transaction.
//
// Coins are what monsters are worth and what cookbooks cost; they buy
// nothing but more monsters. The spec removed keys entirely — cookbooks are
// bought with coins directly.

import { randomUUID } from "crypto";
import { db } from "../db";
import { hasDatabaseUrl } from "../db/pg";
import { enqueueMirror } from "./mirrorQueue";

export type CoinReason =
  | "sell"
  | "gamble_stake"
  | "gamble_win"
  | "gamble_loss"
  | "battle_stake"
  | "battle_win"
  | "battle_refund"
  | "crash_cashout"
  | "grant"
  /** Spending coins on the shop's lootbox case — see 013_case_coin_reason. */
  | "case_open"
  /** Dungeon floor rewards — spec §5: 100 + 25×(floor−1), ×3 on boss floors. */
  | "dungeon"
  /** Daily-task payouts — spec §6: 250 per task, 500 all-three bonus. */
  | "task"
  | "task_bonus"
  /** Dungeon idle income claim (best-floor accrual). */
  | "dungeon_idle";

export const COIN_ERRORS = {
  INSUFFICIENT: "INSUFFICIENT_COINS",
  BAD_AMOUNT: "COIN_AMOUNT_INVALID"
} as const;

export interface CoinEntry {
  id: string;
  playerId: string;
  amount: number;
  reason: CoinReason;
  refId: string | null;
  createdAt: string;
}

/** Balance = SUM(amount). The only way to read one. */
export function coinBalance(playerId: string): number {
  const row = db
    .prepare(`SELECT COALESCE(SUM(amount), 0) AS balance FROM coin_ledger WHERE player_id = ?`)
    .get(playerId) as unknown as { balance: number } | undefined;
  return row?.balance ?? 0;
}

/**
 * Write one ledger row.
 *
 * A negative amount is a spend and is refused if it would drive the balance
 * below zero -- there is no overdraft, and no path that quietly allows one.
 * The balance check and the insert share a transaction so two concurrent
 * spends cannot both see the same balance and both succeed.
 */
export function recordCoins(
  playerId: string,
  amount: number,
  reason: CoinReason,
  refId: string | null = null,
  now = Date.now()
): CoinEntry {
  if (!Number.isInteger(amount) || amount === 0) {
    throw new Error(COIN_ERRORS.BAD_AMOUNT);
  }

  const entry: CoinEntry = {
    id: randomUUID(),
    playerId,
    amount,
    reason,
    refId,
    createdAt: new Date(now).toISOString()
  };

  db.exec("BEGIN IMMEDIATE");
  try {
    writeCoinEntryInTransaction(entry);
    db.exec("COMMIT");
  } catch (err) {
    try {
      db.exec("ROLLBACK");
    } catch {
      // A failed BEGIN leaves nothing to roll back; report the real error.
    }
    throw err;
  }

  return entry;
}

/**
 * Insert a ledger row inside a transaction the CALLER already opened — the
 * atomic cookbook open needs coin debit + mint + drop row to commit or roll
 * back together, and SQLite rejects nested write transactions, so the shared
 * insert lives here instead of being copy-pasted per caller.
 *
 * Negative amounts still carry the no-overdraft check; with BEGIN IMMEDIATE
 * held by the caller, the check and the insert are one atomic step.
 */
export function writeCoinEntryInTransaction(entry: CoinEntry): void {
  if (entry.amount < 0 && coinBalance(entry.playerId) + entry.amount < 0) {
    throw new Error(COIN_ERRORS.INSUFFICIENT);
  }
  db.prepare(
    `INSERT INTO coin_ledger (id, player_id, amount, reason, ref_id, created_at)
     VALUES (?, ?, ?, ?, ?, ?)`
  ).run(entry.id, entry.playerId, entry.amount, entry.reason, entry.refId, entry.createdAt);
  // Postgres is the record of truth for balances (services/coinsPg.ts). The
  // entry id is generated here, not there, so the delivery is idempotent and
  // a retry credits nothing twice. Enqueued inside the same SQLite
  // transaction as the row it mirrors, so the two commit or roll back
  // together and a credit can never be committed locally with no way to
  // reach Postgres.
  if (hasDatabaseUrl()) {
    enqueueMirror("coin_entry", entry.id, entry);
  }
}

/** Convenience: build + write a coin row inside the caller's transaction. */
export function recordCoinsInTransaction(
  playerId: string,
  amount: number,
  reason: CoinReason,
  refId: string | null = null,
  now = Date.now()
): CoinEntry {
  if (!Number.isInteger(amount) || amount === 0) {
    throw new Error(COIN_ERRORS.BAD_AMOUNT);
  }
  const entry: CoinEntry = {
    id: randomUUID(),
    playerId,
    amount,
    reason,
    refId,
    createdAt: new Date(now).toISOString()
  };
  writeCoinEntryInTransaction(entry);
  return entry;
}

/** This player's ledger, newest first. */
export function coinHistory(playerId: string, limit = 50): CoinEntry[] {
  const rows = db
    .prepare(
      `SELECT id, player_id, amount, reason, ref_id, created_at
       FROM coin_ledger WHERE player_id = ? ORDER BY created_at DESC, rowid DESC LIMIT ?`
    )
    .all(playerId, limit) as unknown as {
    id: string;
    player_id: string;
    amount: number;
    reason: string;
    ref_id: string | null;
    created_at: string;
  }[];

  return rows.map((row) => ({
    id: row.id,
    playerId: row.player_id,
    amount: row.amount,
    reason: row.reason as CoinReason,
    refId: row.ref_id,
    createdAt: row.created_at
  }));
}
