import type { Migration } from "../migrate";

/**
 * Adds `player_settings_update` -- the other half of the `user_profile` ->
 * TigerData mapping documented in db-documentation/10-schema-parity-audit.md
 * (`user_profile` -> `app.profile_versions` + `app.player_settings`). The
 * `profile_update` kind (020) only ever fed `profile_versions`; this is the
 * settings/preferences half. Same rebuild recipe as 013/020.
 */
export const migration: Migration = {
  version: 21,
  name: "mirror_outbox_kinds_v3",
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
                        'profile_update','player_settings_update'
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
