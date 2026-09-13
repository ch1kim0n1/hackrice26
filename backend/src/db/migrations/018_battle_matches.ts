import type { Migration } from "../migrate";

/**
 * Pending interactive battles (spec §4/§5).
 *
 * Ranked and friendly play are two-phase: begin matchmakes, resolves both
 * squads server-side, draws the seed, and parks it all here; commit replays
 * the player's submitted action script against that locked snapshot. The
 * table is what makes the seed un-rollable — the client cannot pick or
 * re-pick it, and `consumed_at` makes every match single-use.
 *
 * `own_squad` / `opp_squad` hold the RESOLVED unit snapshots (trusted
 * rarity/star/stats/moves), never the client's claims.
 */
export const migration: Migration = {
  version: 18,
  name: "battle_matches",
  sql: `
    CREATE TABLE battle_match (
      id          TEXT PRIMARY KEY,
      player_id   TEXT NOT NULL,
      mode        TEXT NOT NULL CHECK(mode IN ('ranked','friendly')),
      own_squad   TEXT NOT NULL CHECK(json_valid(own_squad)),
      opp_squad   TEXT NOT NULL CHECK(json_valid(opp_squad)),
      opponent_id TEXT,
      is_bot      INTEGER NOT NULL DEFAULT 0,
      meta        TEXT CHECK(meta IS NULL OR json_valid(meta)),
      seed        TEXT NOT NULL,
      consumed_at TEXT,
      expires_at  TEXT NOT NULL,
      created_at  TEXT NOT NULL DEFAULT (datetime('now'))
    );
    CREATE INDEX idx_battle_match_player ON battle_match(player_id, created_at DESC);
  `
};
