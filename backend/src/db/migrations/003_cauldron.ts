import type { Migration } from "../migrate";

/**
 * Cauldron Crash: per-instance monster ids, and the round ledger.
 *
 * Two things the casino needs that nothing before it did.
 *
 * **`lootbox_drop.drop_id`** — a wager destroys one specific monster, so the
 * inventory needs an identity finer than the character id it used to be
 * addressed by. A player holding three Salmon Strikers is holding three
 * separate monsters. Rows written before this get `legacy-<seq>` rather than a
 * fresh random id: it is derived from data already in the row, so re-running
 * cannot rename a row a live wager is pointing at.
 *
 * **`cauldron_round`** — one row per round, written before the multiplier
 * starts moving, holding the wager and the hidden crash point. Real owned
 * items are destroyed against this table, so it is the record that has to
 * survive a disconnect, a redeploy, and a replayed request.
 */
export const migration: Migration = {
  version: 3,
  name: "cauldron",
  sql: `
    CREATE TABLE cauldron_round (
      round_id            TEXT PRIMARY KEY,
      player_id           TEXT NOT NULL REFERENCES players(id) ON DELETE CASCADE,
      -- The wagered drops, copied in full: they are gone from the inventory,
      -- so this is the only surviving record of what was risked.
      wager               TEXT NOT NULL CHECK(json_valid(wager)),
      starting_net_worth  INTEGER NOT NULL CHECK(starting_net_worth >= 0),
      crash_multiplier    REAL NOT NULL CHECK(crash_multiplier >= 1),
      status              TEXT NOT NULL CHECK(status IN ('ACTIVE', 'CASHED_OUT', 'CRASHED')),
      started_at          TEXT NOT NULL,
      cash_out_at         TEXT,
      cash_out_multiplier REAL,
      final_net_worth     INTEGER,
      reward              TEXT CHECK(reward IS NULL OR json_valid(reward)),
      completed_at        TEXT,
      fairness            TEXT NOT NULL CHECK(json_valid(fairness))
    );
    CREATE INDEX idx_cauldron_round_player ON cauldron_round(player_id, started_at);

    -- Header-based demo players have no registration event, so the insert
    -- materializes its parent first, exactly as every other player-scoped
    -- table does (see 002_integrity).
    CREATE TRIGGER trg_cauldron_round_ensure_player BEFORE INSERT ON cauldron_round
      BEGIN
        INSERT OR IGNORE INTO players(id, display_name, is_portable)
        VALUES (
          NEW.player_id,
          substr('Trainer ' || NEW.player_id, 1, 32),
          CASE WHEN length(NEW.player_id) = 36
            AND substr(NEW.player_id, 9, 1) = '-' AND substr(NEW.player_id, 14, 1) = '-'
            AND substr(NEW.player_id, 19, 1) = '-' AND substr(NEW.player_id, 24, 1) = '-'
          THEN 1 ELSE 0 END
        );
      END;
  `,
  run: (db) => {
    // SQLite has no `ADD COLUMN IF NOT EXISTS`, and this migration may meet a
    // database that already took the column from an earlier build.
    const columns = new Set(
      (db.prepare("PRAGMA table_info(lootbox_drop)").all() as unknown as { name: string }[]).map(
        (column) => column.name
      )
    );
    if (!columns.has("drop_id")) {
      // NOT NULL needs a constant default; the backfill below replaces it.
      db.exec(`ALTER TABLE lootbox_drop ADD COLUMN drop_id TEXT NOT NULL DEFAULT ''`);
    }
    db.exec(`UPDATE lootbox_drop SET drop_id = 'legacy-' || seq WHERE drop_id = ''`);
    db.exec(`CREATE UNIQUE INDEX IF NOT EXISTS idx_lootbox_drop_id ON lootbox_drop(drop_id)`);
  }
};
