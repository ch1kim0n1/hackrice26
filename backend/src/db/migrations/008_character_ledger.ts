import type { Migration } from "../migrate";

/**
 * Mutation ledger + arena escrow (issues #133, #116).
 *
 * **`character_ledger`** — one append-only row per character lifecycle
 * mutation (merge, sell, gamble stake/payout, battle stake/payout/refund).
 * Every value-bearing change to an owned monster writes here through
 * services/characterMutations.ts, so a disputed inventory has an audit trail
 * and the double-spend class of bugs leaves evidence instead of just damage.
 *
 * **`arena_stake`** — the escrow record for staked arena battles: which drops
 * are locked behind which battle, and whether the stake settled or refunded.
 * A crash between "stake" and "settle" is recoverable from this table alone.
 */
export const migration: Migration = {
  version: 8,
  name: "character_ledger",
  sql: `
    CREATE TABLE IF NOT EXISTS character_ledger (
      seq        INTEGER PRIMARY KEY AUTOINCREMENT,
      player_id  TEXT NOT NULL,
      kind       TEXT NOT NULL CHECK(kind IN (
        'merge','sell',
        'gamble_stake','gamble_payout',
        'battle_stake','battle_payout','battle_refund'
      )),
      drop_ids   TEXT NOT NULL CHECK(json_valid(drop_ids)),
      detail     TEXT CHECK(detail IS NULL OR json_valid(detail)),
      created_at TEXT NOT NULL DEFAULT (datetime('now'))
    );
    CREATE INDEX IF NOT EXISTS idx_character_ledger_player
      ON character_ledger(player_id, seq);

    CREATE TABLE IF NOT EXISTS arena_stake (
      battle_id  TEXT NOT NULL,
      player_id  TEXT NOT NULL,
      drop_ids   TEXT NOT NULL CHECK(json_valid(drop_ids)),
      status     TEXT NOT NULL CHECK(status IN ('LOCKED','SETTLED','REFUNDED')),
      created_at TEXT NOT NULL DEFAULT (datetime('now')),
      settled_at TEXT,
      PRIMARY KEY (battle_id, player_id)
    );
    CREATE INDEX IF NOT EXISTS idx_arena_stake_locked
      ON arena_stake(player_id) WHERE status = 'LOCKED';
  `
};
