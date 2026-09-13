import type { Migration } from "../migrate";

/**
 * Widens `mirror_outbox.kind` for the DB-finalization pass: every live
 * feature that had a SQLite table but no Postgres mirror gets a kind here.
 * Same rebuild recipe as 013 (SQLite has no ALTER ... ALTER CONSTRAINT).
 * 007/012/013 are left alone — migrations are append-only.
 */
export const migration: Migration = {
  version: 20,
  name: "mirror_outbox_kinds_v2",
  sql: `
    ALTER TABLE mirror_outbox RENAME TO __old_mirror_outbox;
    CREATE TABLE mirror_outbox (
      id              INTEGER PRIMARY KEY AUTOINCREMENT,
      kind            TEXT NOT NULL CHECK(kind IN (
                        'mines_round','plinko_drop','portal_wheel_spin','cauldron_round',
                        'meal_intake','friend_battle','gameplay_event','health_snapshot',
                        'streak_event','acquisition_event','dungeon_progress','coin_entry',
                        'body_metric',
                        'scan_mint','case_grant','case_open','fainted_monster',
                        'battle_match_begin','owned_character','squad_snapshot',
                        'promo_redemption','account_created','session_event',
                        'profile_update'
                      )),
      payload         TEXT NOT NULL CHECK(json_valid(payload)),
      idempotency_key TEXT NOT NULL,
      attempts        INTEGER NOT NULL DEFAULT 0,
      next_attempt_at INTEGER NOT NULL DEFAULT 0,
      last_error      TEXT,
      created_at      TEXT NOT NULL DEFAULT (datetime('now'))
    );
    INSERT INTO mirror_outbox (id, kind, payload, idempotency_key, attempts, next_attempt_at, last_error, created_at)
      SELECT id, kind, payload, idempotency_key, attempts, next_attempt_at, last_error, created_at FROM __old_mirror_outbox;
    DROP TABLE __old_mirror_outbox;
    CREATE INDEX idx_mirror_outbox_due ON mirror_outbox(next_attempt_at, id);
    CREATE UNIQUE INDEX idx_mirror_outbox_key ON mirror_outbox(kind, idempotency_key);
  `
};
