import type { DatabaseSync } from "node:sqlite";
import type { Migration } from "../migrate";

function columns(db: DatabaseSync, table: string): Set<string> {
  return new Set(
    (db.prepare(`PRAGMA table_info(${table})`).all() as { name: string }[]).map((row) => row.name)
  );
}

/**
 * `lootbox_session.collection_seeded` — one-shot marker so the backfill that
 * turns the starter roster and previously scanned characters into real,
 * owned drops runs exactly once per player. Without a flag the backfill
 * could not tell "never seeded" apart from "seeded, then sold" and would
 * re-mint sellable monsters on every attach — a free coin faucet.
 */
export const migration: Migration = {
  version: 14,
  name: "collection_drops",
  run(db) {
    if (!columns(db, "lootbox_session").has("collection_seeded")) {
      db.exec(`ALTER TABLE lootbox_session ADD COLUMN collection_seeded INTEGER NOT NULL DEFAULT 0`);
    }
  }
};
