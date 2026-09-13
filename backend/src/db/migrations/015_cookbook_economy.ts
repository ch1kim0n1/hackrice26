import type { DatabaseSync } from "node:sqlite";
import type { Migration } from "../migrate";

function columns(db: DatabaseSync, table: string): Set<string> {
  return new Set(
    (db.prepare(`PRAGMA table_info(${table})`).all() as { name: string }[]).map((row) => row.name)
  );
}

/**
 * The cookbook economy (spec §2/§3):
 *
 *  - `lootbox_session` loses `keys`, `since_epic` and `since_legendary` —
 *    keys and pity are gone; a session is a seed pair and nothing else.
 *  - `lootbox_drop.overflow` marks drops sitting in the mailbox because the
 *    200-slot inventory was full when they were minted (checklist: overflow,
 *    never evict).
 *  - `pending_case` holds granted Cases — ranked wins and promos hand out a
 *    fixed-rarity Case that the player opens later; the row existing is what
 *    makes a double-open impossible.
 */
export const migration: Migration = {
  version: 15,
  name: "cookbook_economy",
  run(db) {
    const sessionCols = columns(db, "lootbox_session");
    for (const col of ["keys", "since_epic", "since_legendary"]) {
      if (sessionCols.has(col)) {
        db.exec(`ALTER TABLE lootbox_session DROP COLUMN ${col}`);
      }
    }

    if (!columns(db, "lootbox_drop").has("overflow")) {
      db.exec(`ALTER TABLE lootbox_drop ADD COLUMN overflow INTEGER NOT NULL DEFAULT 0 CHECK(overflow IN (0, 1))`);
    }

    // Cookbook/Case opens mint into the inventory — those mints are
    // value-bearing mutations and belong in character_ledger next to merge and
    // sell. The kind CHECK constraint predates them, so rebuild the table with
    // the extended kind list (same recipe as 002/013).
    const ledgerSql = db
      .prepare(`SELECT sql FROM sqlite_master WHERE type = 'table' AND name = 'character_ledger'`)
      .get() as { sql: string } | undefined;
    if (ledgerSql && !ledgerSql.sql.includes("'case_open'")) {
      db.exec(`
        ALTER TABLE character_ledger RENAME TO __old_character_ledger;
        CREATE TABLE character_ledger (
          seq        INTEGER PRIMARY KEY AUTOINCREMENT,
          player_id  TEXT NOT NULL,
          kind       TEXT NOT NULL CHECK(kind IN (
            'merge','sell',
            'gamble_stake','gamble_payout',
            'battle_stake','battle_payout','battle_refund',
            'cookbook_open','case_open'
          )),
          drop_ids   TEXT NOT NULL CHECK(json_valid(drop_ids)),
          detail     TEXT CHECK(detail IS NULL OR json_valid(detail)),
          created_at TEXT NOT NULL DEFAULT (datetime('now'))
        );
        INSERT INTO character_ledger (seq, player_id, kind, drop_ids, detail, created_at)
          SELECT seq, player_id, kind, drop_ids, detail, created_at FROM __old_character_ledger;
        DROP TABLE __old_character_ledger;
        CREATE INDEX IF NOT EXISTS idx_character_ledger_player
          ON character_ledger(player_id, seq);
      `);
    }

    db.exec(`
      CREATE TABLE IF NOT EXISTS pending_case (
        case_id    TEXT PRIMARY KEY,
        player_id  TEXT NOT NULL REFERENCES players(id) ON DELETE CASCADE,
        rarity     TEXT NOT NULL,
        source     TEXT NOT NULL,
        created_at TEXT NOT NULL DEFAULT (datetime('now'))
      );
      CREATE INDEX IF NOT EXISTS idx_pending_case_player ON pending_case(player_id);
      -- Same convention as 002's autoTables: header-auth players materialize
      -- their parent row on first insert, or the FK fails for a player who
      -- never registered an account.
      CREATE TRIGGER IF NOT EXISTS trg_pending_case_ensure_player BEFORE INSERT ON pending_case
      BEGIN
        INSERT OR IGNORE INTO players(id, display_name, is_portable)
        VALUES (NEW.player_id, substr('Trainer ' || NEW.player_id, 1, 32), 0);
      END;
    `);
  }
};
