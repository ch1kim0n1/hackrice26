import type { Migration } from "../migrate";

/**
 * Coins, and the lock that stops a monster being spent twice.
 *
 * Two things the live backend needs before anything can be sold or staked.
 *
 * **`coin_ledger`** mirrors the Postgres one (`app.currency_entries`): rows
 * are append-only, a balance is `SUM(amount)`, and every row names a reason
 * and the thing it refers to, so any balance can be explained back to the
 * event that produced it. Coins are the soft currency characters trade in;
 * capsule keys stay the pull currency, and the two never convert.
 *
 * **`lootbox_drop.locked_by`** marks an instance as committed to something
 * else — an arena stake today, an escrow tomorrow. A locked monster cannot be
 * sold, gambled, or fused, which is enforced in one place (`consumeDrops`) so
 * a new game mode cannot forget to check. NULL means free.
 *
 * Migration 004 already added a bare `locked` boolean for the same idea, but
 * nothing ever read it and a flag cannot say WHICH battle is holding a
 * monster — so releasing one correctly afterwards would be guesswork. Rather
 * than run two competing locks, `locked_by` becomes the authority and `locked`
 * is kept in step with it as a derived flag, so the partial index 004 built
 * over it (`WHERE locked = 0`) stays correct for anything that reads it later.
 */
export const migration: Migration = {
  version: 7,
  name: "coins_and_locks",
  sql: `
    CREATE TABLE coin_ledger (
      id         TEXT PRIMARY KEY,
      player_id  TEXT NOT NULL,
      amount     INTEGER NOT NULL CHECK (amount <> 0),
      reason     TEXT NOT NULL CHECK (reason IN (
                   'sell','gamble_stake','gamble_win','gamble_loss',
                   'battle_stake','battle_win','battle_refund',
                   'crash_cashout','grant'
                 )),
      -- The character sold, the battle staked. Not a foreign key: the row it
      -- points at is usually deleted (a sold monster is gone) and the ledger
      -- entry has to outlive it.
      ref_id     TEXT,
      created_at TEXT NOT NULL
    );
    CREATE INDEX idx_coin_ledger_player ON coin_ledger(player_id, created_at);
  `,
  run: (db) => {
    const columns = new Set(
      (db.prepare("PRAGMA table_info(lootbox_drop)").all() as unknown as { name: string }[]).map(
        (column) => column.name
      )
    );
    if (!columns.has("locked_by")) {
      // NULL = free to spend. Anything else names what holds it.
      db.exec(`ALTER TABLE lootbox_drop ADD COLUMN locked_by TEXT`);
    }
    db.exec(`CREATE INDEX IF NOT EXISTS idx_lootbox_drop_locked ON lootbox_drop(locked_by)`);

    // Anything 004's boolean already flagged is locked by something nobody
    // recorded. Name it so the two columns agree from here on.
    if (columns.has("locked")) {
      db.exec(`UPDATE lootbox_drop SET locked_by = 'legacy' WHERE locked = 1 AND locked_by IS NULL`);
    }
  }
};
