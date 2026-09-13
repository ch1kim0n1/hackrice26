import type { Migration } from "../migrate";

/**
 * Heal databases whose user_version advanced past migrations that never ran.
 *
 * A database can reach version 18 while still missing `plinko_drop` (006) and
 * the `mirror_outbox` pair (012) — e.g. a file whose version stamp was set by
 * a build that briefly lacked those migrations, then upgraded on a build that
 * had them. `applyMigrations` only runs versions above the stamp, so the
 * tables never come back: /plinko/state 500s with "no such table" and the
 * casino wager picker renders empty.
 *
 * Every statement is IF NOT EXISTS — databases that applied 006/012 normally
 * are untouched, databases that skipped them are repaired.
 */
export const migration: Migration = {
  version: 19,
  name: "heal_missing_tables",
  sql: `
    -- 006: plinko history. No live round to protect; the row is the record.
    CREATE TABLE IF NOT EXISTS plinko_drop (
      drop_id         TEXT PRIMARY KEY,
      player_id       TEXT NOT NULL,
      wager           TEXT NOT NULL,
      wager_value     INTEGER NOT NULL,
      path            TEXT NOT NULL,
      slot            INTEGER NOT NULL,
      multiplier      REAL NOT NULL,
      final_net_worth INTEGER NOT NULL,
      reward          TEXT,
      created_at      TEXT NOT NULL,
      fairness        TEXT NOT NULL
    );
    CREATE INDEX IF NOT EXISTS idx_plinko_drop_player ON plinko_drop(player_id, created_at);

    -- 012: the durable mirror queue + dead-letter table.
    CREATE TABLE IF NOT EXISTS mirror_outbox (
      id              INTEGER PRIMARY KEY AUTOINCREMENT,
      kind            TEXT NOT NULL CHECK(kind IN (
                        'mines_round','plinko_drop','portal_wheel_spin','cauldron_round',
                        'meal_intake','friend_battle','gameplay_event','health_snapshot',
                        'streak_event','acquisition_event','dungeon_progress','coin_entry',
                        'body_metric'
                      )),
      payload         TEXT NOT NULL CHECK(json_valid(payload)),
      idempotency_key TEXT NOT NULL,
      attempts        INTEGER NOT NULL DEFAULT 0,
      next_attempt_at INTEGER NOT NULL DEFAULT 0,
      last_error      TEXT,
      created_at      TEXT NOT NULL DEFAULT (datetime('now'))
    );
    CREATE INDEX IF NOT EXISTS idx_mirror_outbox_due
      ON mirror_outbox(next_attempt_at, id);
    CREATE UNIQUE INDEX IF NOT EXISTS idx_mirror_outbox_key
      ON mirror_outbox(kind, idempotency_key);

    CREATE TABLE IF NOT EXISTS mirror_outbox_dead (
      id              INTEGER PRIMARY KEY,
      kind            TEXT NOT NULL,
      payload         TEXT NOT NULL,
      idempotency_key TEXT NOT NULL,
      attempts        INTEGER NOT NULL,
      last_error      TEXT,
      created_at      TEXT NOT NULL,
      died_at         TEXT NOT NULL DEFAULT (datetime('now'))
    );
  `
};
