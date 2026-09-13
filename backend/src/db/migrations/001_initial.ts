// 001 — the schema as it stood before there was a migration runner.
//
// Consolidated verbatim from the three places it used to be declared: the
// SCHEMA constant in the old src/db.ts, plus the `db.exec(...)` calls that ran
// as import side effects in auth/store.ts and services/promoCodes.ts. Nothing
// is changed here, by design: every table is CREATE TABLE IF NOT EXISTS, so a
// database in the field arrives at version 1 without a single write, and a
// fresh file ends up byte-identical to one the old code would have produced.
//
// Two columns below (scan_seen.seen_at, and lootbox_session's pity counters)
// reached existing databases through the ad-hoc ALTER blocks the old
// openDatabase() ran on every boot. They are inlined here so a fresh database
// gets them too; 002 re-adds them defensively for any file that somehow missed.

import type { Migration } from "../migrate";

export const migration: Migration = {
  version: 1,
  name: "initial",
  sql: `
-- ---- accounts (was auth/store.ts) ----------------------------------------
CREATE TABLE IF NOT EXISTS account (
  player_id      TEXT PRIMARY KEY,          -- the id all player state is keyed by
  username       TEXT NOT NULL UNIQUE COLLATE NOCASE,
  password_hash  TEXT NOT NULL,             -- scrypt: salt$hash hex
  display_name   TEXT NOT NULL DEFAULT '',
  created_at     TEXT NOT NULL DEFAULT (datetime('now')),
  last_login_at  TEXT
);
CREATE TABLE IF NOT EXISTS session (
  token_hash    TEXT PRIMARY KEY,           -- sha256(token); raw token never stored
  player_id     TEXT NOT NULL REFERENCES account(player_id),
  created_at    TEXT NOT NULL DEFAULT (datetime('now')),
  expires_at    TEXT NOT NULL,
  revoked       INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX IF NOT EXISTS idx_session_player ON session(player_id);

-- ---- loot boxes ----------------------------------------------------------
CREATE TABLE IF NOT EXISTS lootbox_session (
  player_id       TEXT PRIMARY KEY,
  keys            INTEGER NOT NULL,
  server_seed     TEXT NOT NULL,
  server_seed_hash TEXT NOT NULL,
  client_seed     TEXT NOT NULL,
  nonce           INTEGER NOT NULL,
  created_at      TEXT NOT NULL,
  since_epic      INTEGER NOT NULL DEFAULT 0,
  since_legendary INTEGER NOT NULL DEFAULT 0
);
CREATE TABLE IF NOT EXISTS lootbox_retired (
  player_id       TEXT NOT NULL,
  server_seed     TEXT NOT NULL,
  server_seed_hash TEXT NOT NULL,
  client_seed     TEXT NOT NULL,
  nonce           INTEGER NOT NULL,
  created_at      TEXT NOT NULL,
  retired_at      TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_lootbox_retired_player ON lootbox_retired(player_id);
CREATE TABLE IF NOT EXISTS lootbox_drop (
  seq      INTEGER PRIMARY KEY AUTOINCREMENT,
  player_id TEXT NOT NULL,
  payload  TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_lootbox_drop_player ON lootbox_drop(player_id);

-- ---- profile / collection ------------------------------------------------
CREATE TABLE IF NOT EXISTS user_profile (
  player_id  TEXT PRIMARY KEY,
  payload    TEXT NOT NULL,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS scan_seen (
  player_id TEXT NOT NULL,
  barcode   TEXT NOT NULL,
  seen_at   TEXT NOT NULL DEFAULT '1970-01-01T00:00:00Z',
  PRIMARY KEY (player_id, barcode)
);
CREATE TABLE IF NOT EXISTS scan_character (
  player_id TEXT NOT NULL,
  char_id   TEXT NOT NULL,
  payload   TEXT NOT NULL,
  PRIMARY KEY (player_id, char_id)
);

-- ---- vitals / dish photo -------------------------------------------------
CREATE TABLE IF NOT EXISTS vitals_snapshot (
  seq      INTEGER PRIMARY KEY AUTOINCREMENT,
  player_id TEXT NOT NULL,
  payload  TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_vitals_snapshot_player ON vitals_snapshot(player_id);
CREATE TABLE IF NOT EXISTS dish_analysis (
  analysis_id TEXT PRIMARY KEY,
  player_id   TEXT NOT NULL,
  payload     TEXT NOT NULL,
  created_at  TEXT NOT NULL DEFAULT (datetime('now')),
  consumed    INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX IF NOT EXISTS idx_dish_analysis_player ON dish_analysis(player_id);

-- ---- retention -----------------------------------------------------------
CREATE TABLE IF NOT EXISTS quest_claim (
  player_id TEXT NOT NULL,
  day       TEXT NOT NULL,
  quest_id  TEXT NOT NULL,
  claimed_at TEXT NOT NULL DEFAULT (datetime('now')),
  PRIMARY KEY (player_id, day, quest_id)
);
CREATE TABLE IF NOT EXISTS player_seen (
  player_id            TEXT PRIMARY KEY,
  last_seen_at         TEXT NOT NULL,
  comeback_pending_at  TEXT,
  comeback_claimed_at  TEXT
);

-- ---- async PvP -----------------------------------------------------------
CREATE TABLE IF NOT EXISTS friend_squad (
  player_id  TEXT PRIMARY KEY,
  payload    TEXT NOT NULL,
  updated_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS async_battle (
  seq           INTEGER PRIMARY KEY AUTOINCREMENT,
  challenger_id TEXT NOT NULL,
  defender_id   TEXT NOT NULL,
  winner_side   INTEGER NOT NULL, -- 0 challenger, 1 defender
  rounds        INTEGER NOT NULL,
  created_at    TEXT NOT NULL DEFAULT (datetime('now')),
  seen_by_defender INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX IF NOT EXISTS idx_async_battle_defender ON async_battle(defender_id, seen_by_defender);

-- ---- dungeon -------------------------------------------------------------
CREATE TABLE IF NOT EXISTS dungeon_state (
  player_id     TEXT PRIMARY KEY,
  best_floor    INTEGER NOT NULL DEFAULT 0,
  last_claim_at TEXT NOT NULL,
  last_run_at   TEXT
);

-- ---- promo codes (was services/promoCodes.ts) ----------------------------
CREATE TABLE IF NOT EXISTS promo_code (
  code TEXT PRIMARY KEY,
  reward TEXT NOT NULL,
  uses_limit INTEGER NOT NULL DEFAULT 0,
  uses INTEGER NOT NULL DEFAULT 0,
  created_at TEXT NOT NULL DEFAULT (datetime('now')),
  expires_at TEXT
);
CREATE TABLE IF NOT EXISTS promo_redeem (
  player_id TEXT NOT NULL,
  code TEXT NOT NULL,
  redeemed_at TEXT NOT NULL DEFAULT (datetime('now')),
  PRIMARY KEY (player_id, code)
);
CREATE INDEX IF NOT EXISTS idx_promo_redeem_code ON promo_redeem(code);
`
};
