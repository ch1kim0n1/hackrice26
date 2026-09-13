import type { Migration } from "../migrate";
import { ROSTER } from "../../data/roster";

/**
 * Character system tables + instance fields (issues #97, #106, #118, #132).
 *
 * **`character_catalog`** — the established roster, seeded here from the same
 * `characters.json` the rest of the backend validates at boot. Pokédex side:
 * what a monster IS. Player-owned rows point at it via `catalog_slug`.
 *
 * **`character_image`** — one row per (character, rarity): the pre-generated
 * art variant the client shows for that tier (#97).
 *
 * **`attack` / `character_attack`** — the moveset schema (#106). `min_rarity`
 * on `attack` gates special attacks to higher tiers; the seed data itself is
 * #108, these tables only have to hold it.
 *
 * **`lootbox_drop` columns** — the owned-monster fields the economy needs as
 * real columns rather than payload archaeology: `star_level` (1..5, from the
 * payload's `stars`), `net_worth` (from `value`, so pot sums and sell pricing
 * are a column read), `locked` (staked / in-pot: no sell, no merge), and
 * `catalog_slug` for roster-born drops.
 */
export const migration: Migration = {
  version: 4,
  name: "character_system",
  sql: `
    CREATE TABLE character_catalog (
      slug        TEXT PRIMARY KEY,
      name        TEXT NOT NULL,
      tagline     TEXT,
      bio         TEXT NOT NULL,
      element     TEXT NOT NULL,
      base_rarity TEXT NOT NULL,
      color_hex   TEXT,
      base_stats  TEXT NOT NULL CHECK(json_valid(base_stats))
    );

    CREATE TABLE character_image (
      character_key TEXT NOT NULL,
      rarity        TEXT NOT NULL,
      image_key     TEXT NOT NULL,
      PRIMARY KEY (character_key, rarity)
    );

    CREATE TABLE attack (
      attack_id  INTEGER PRIMARY KEY,
      name       TEXT NOT NULL,
      kind       TEXT NOT NULL CHECK(kind IN ('basic','signature','special')),
      power      REAL NOT NULL CHECK(power >= 0),
      effect     TEXT CHECK(effect IS NULL OR json_valid(effect)),
      min_rarity TEXT NOT NULL DEFAULT 'common'
    );

    CREATE TABLE character_attack (
      character_key TEXT NOT NULL,
      attack_id     INTEGER NOT NULL REFERENCES attack(attack_id),
      PRIMARY KEY (character_key, attack_id)
    );
  `,
  run: (db) => {
    // Instance columns. Guarded like 003_cauldron: old files may already carry
    // them if a boot-time ALTER ran first, and SQLite has no IF NOT EXISTS for
    // columns.
    const columns = new Set(
      (db.prepare("PRAGMA table_info(lootbox_drop)").all() as unknown as { name: string }[]).map(
        (c) => c.name
      )
    );
    if (!columns.has("star_level")) {
      db.exec(`ALTER TABLE lootbox_drop ADD COLUMN star_level INTEGER NOT NULL DEFAULT 1`);
      db.exec(`UPDATE lootbox_drop SET star_level = MIN(5, MAX(1, CAST(COALESCE(json_extract(payload, '$.stars'), 1) AS INTEGER)))`);
    }
    if (!columns.has("net_worth")) {
      db.exec(`ALTER TABLE lootbox_drop ADD COLUMN net_worth INTEGER NOT NULL DEFAULT 0`);
      db.exec(`UPDATE lootbox_drop SET net_worth = MAX(0, CAST(COALESCE(json_extract(payload, '$.value'), 0) AS INTEGER))`);
    }
    if (!columns.has("catalog_slug")) {
      db.exec(`ALTER TABLE lootbox_drop ADD COLUMN catalog_slug TEXT REFERENCES character_catalog(slug)`);
    }
    if (!columns.has("locked")) {
      db.exec(`ALTER TABLE lootbox_drop ADD COLUMN locked INTEGER NOT NULL DEFAULT 0 CHECK(locked IN (0, 1))`);
    }
    db.exec(`CREATE INDEX IF NOT EXISTS idx_lootbox_drop_unlocked ON lootbox_drop(player_id) WHERE locked = 0`);

    // Seed the 14 established characters. INSERT OR IGNORE so a database that
    // was partially seeded by something else converges instead of failing.
    // The element/base_rarity/base_stats columns belong to the old stat model
    // this table predates; the catalog dropped them, so they carry inert
    // placeholders until a later migration reshapes the table.
    const insert = db.prepare(
      `INSERT OR IGNORE INTO character_catalog
         (slug, name, tagline, bio, element, base_rarity, color_hex, base_stats)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?)`
    );
    for (const c of ROSTER) {
      insert.run(
        c.id,
        c.name,
        c.tagline,
        c.bio,
        "none",
        "common",
        c.colorHex,
        JSON.stringify({ health: c.baseHealth, attack: c.baseAttack, mana: c.baseMana })
      );
    }
  }
};
