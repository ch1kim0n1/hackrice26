import type { Migration } from "../migrate";

/**
 * Scan pipeline persistence (spec §1 checklist).
 *
 * **`scan_mint`** — the anti-cheat record for barcode mints. One row per
 * (player, barcode) ever: the barcode, the exact nutrition snapshot the
 * monster was generated from, the nutrition data source, and the timestamp.
 * Its PRIMARY KEY is what enforces the once-per-user-ever rule at the data
 * layer — a second insert for the same pair fails outright, so a race or a
 * retry can never double-mint.
 *
 * **`meal_log`** — durable intake record for all three input paths (barcode,
 * photo, manual). The dashboard contract is kcal/protein/carbs/fat only, so
 * those are real columns; the wider nutrient fields stay for provenance and
 * task evaluation. `removed` is a tombstone — deleting a logged meal never
 * erases the row, which keeps ledgers and mirrors replayable.
 */
export const migration: Migration = {
  version: 16,
  name: "scan_mint_and_meals",
  sql: `
    CREATE TABLE scan_mint (
      player_id    TEXT NOT NULL,
      barcode      TEXT NOT NULL,
      drop_id      TEXT NOT NULL,
      character_id TEXT NOT NULL,
      nutrition    TEXT NOT NULL CHECK(json_valid(nutrition)),
      source       TEXT NOT NULL,
      created_at   TEXT NOT NULL DEFAULT (datetime('now')),
      PRIMARY KEY (player_id, barcode)
    );

    CREATE TABLE meal_log (
      meal_id     TEXT PRIMARY KEY,
      player_id   TEXT NOT NULL,
      source      TEXT NOT NULL CHECK(source IN ('barcode','photo','manual')),
      name        TEXT NOT NULL,
      calories    REAL,
      protein_g   REAL,
      carbs_g     REAL,
      fat_g       REAL,
      fiber_g     REAL,
      sugar_g     REAL,
      sodium_mg   REAL,
      sat_fat_g   REAL,
      barcode     TEXT,
      analysis_id TEXT,
      flagged     INTEGER NOT NULL DEFAULT 0 CHECK(flagged IN (0, 1)),
      logged_at   TEXT NOT NULL DEFAULT (datetime('now')),
      updated_at  TEXT NOT NULL DEFAULT (datetime('now')),
      removed     INTEGER NOT NULL DEFAULT 0 CHECK(removed IN (0, 1))
    );
    CREATE INDEX idx_meal_log_player_day ON meal_log(player_id, logged_at);
  `
};
