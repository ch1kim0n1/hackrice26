import type { Migration } from "../migrate";

/**
 * Widens `coin_ledger.reason` to allow `'case_open'` — the Shop spending
 * coins on the one lootbox case (issue: Shop coin pricing).
 *
 * SQLite has no `ALTER TABLE ... ALTER CONSTRAINT`, so a CHECK constraint can
 * only change by rebuilding the table: rename the old one aside, create the
 * new shape, copy every row across by name, drop the old one. Same recipe
 * `002_integrity.ts` used. 007 is left alone — migrations are append-only.
 */
export const migration: Migration = {
  version: 13,
  name: "case_coin_reason",
  sql: `
    ALTER TABLE coin_ledger RENAME TO __old_coin_ledger;
    CREATE TABLE coin_ledger (
      id         TEXT PRIMARY KEY,
      player_id  TEXT NOT NULL,
      amount     INTEGER NOT NULL CHECK (amount <> 0),
      reason     TEXT NOT NULL CHECK (reason IN (
                   'sell','gamble_stake','gamble_win','gamble_loss',
                   'battle_stake','battle_win','battle_refund',
                   'crash_cashout','grant','case_open'
                 )),
      ref_id     TEXT,
      created_at TEXT NOT NULL
    );
    INSERT INTO coin_ledger (id, player_id, amount, reason, ref_id, created_at)
      SELECT id, player_id, amount, reason, ref_id, created_at FROM __old_coin_ledger;
    DROP TABLE __old_coin_ledger;
    CREATE INDEX idx_coin_ledger_player ON coin_ledger(player_id, created_at);
  `
};
