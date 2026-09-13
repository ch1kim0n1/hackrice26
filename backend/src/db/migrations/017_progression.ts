import type { Migration } from "../migrate";

/**
 * Progression tables (final-dev-doc §5/§6) plus the coin reasons the new
 * systems pay out with.
 *
 * **`battle_history`** — one row per completed battle the server resolved:
 * mode (ranked/friendly/dungeon), result, the opponent (player id, 'bot',
 * 'custom', 'dungeon'), the RR delta the result applied (0 for friendly),
 * the three monsters fielded, and a JSON detail blob (floors cleared, etc).
 * Profile stats and the leaderboard read from here and the profile's RR.
 *
 * **`fainted_monster`** — a 0-HP monster stays fainted until the daily
 * reset or a nutrition-task revive. Rows are day-stamped: anything older
 * than today is already recovered, so the reset is just "ignore yesterday".
 *
 * **`coin_ledger` rebuild** — SQLite cannot alter a CHECK constraint, so the
 * table is rebuilt with three new reasons: `task`, `task_bonus` (daily-task
 * payouts) and `dungeon` (floor rewards). Same recipe as 013.
 */
export const migration: Migration = {
  version: 17,
  name: "progression",
  sql: `
    CREATE TABLE battle_history (
      seq        INTEGER PRIMARY KEY AUTOINCREMENT,
      player_id  TEXT NOT NULL,
      mode       TEXT NOT NULL CHECK(mode IN ('ranked','friendly','dungeon')),
      result     TEXT NOT NULL CHECK(result IN ('win','loss')),
      opponent   TEXT,
      rr_delta   INTEGER NOT NULL DEFAULT 0,
      squad      TEXT NOT NULL CHECK(json_valid(squad)),
      detail     TEXT CHECK(detail IS NULL OR json_valid(detail)),
      created_at TEXT NOT NULL DEFAULT (datetime('now'))
    );
    CREATE INDEX idx_battle_history_player ON battle_history(player_id, seq DESC);

    CREATE TABLE fainted_monster (
      player_id TEXT NOT NULL,
      char_id   TEXT NOT NULL,
      day       TEXT NOT NULL,
      fainted_at TEXT NOT NULL DEFAULT (datetime('now')),
      PRIMARY KEY (player_id, char_id)
    );

    ALTER TABLE coin_ledger RENAME TO __old_coin_ledger;
    CREATE TABLE coin_ledger (
      id         TEXT PRIMARY KEY,
      player_id  TEXT NOT NULL,
      amount     INTEGER NOT NULL CHECK (amount <> 0),
      reason     TEXT NOT NULL CHECK (reason IN (
                   'sell','gamble_stake','gamble_win','gamble_loss',
                   'battle_stake','battle_win','battle_refund',
                   'crash_cashout','grant','case_open',
                   'task','task_bonus','dungeon','dungeon_idle'
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
