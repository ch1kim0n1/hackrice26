import type { Migration } from "../migrate";

/**
 * Plinko drops.
 *
 * Unlike the cauldron and the mines board there is no live round to protect:
 * a drop is decided, paid and finished inside one request. The row is history
 * — what was wagered, the path the orb actually took, where it landed, and
 * what came back — so a result screen survives a refresh and a disputed drop
 * can be replayed from its fairness record.
 */
export const migration: Migration = {
  version: 6,
  name: "plinko",
  sql: `
    CREATE TABLE plinko_drop (
      drop_id         TEXT PRIMARY KEY,
      player_id       TEXT NOT NULL,
      -- The wagered monster, copied in full: it is gone from the inventory, so
      -- this is the only surviving record of it.
      wager           TEXT NOT NULL,
      wager_value     INTEGER NOT NULL,
      -- JSON array of 12 booleans: the left/right decision at each peg row.
      path            TEXT NOT NULL,
      slot            INTEGER NOT NULL,
      multiplier      REAL NOT NULL,
      final_net_worth INTEGER NOT NULL,
      reward          TEXT,            -- JSON drop; null on a 0x landing
      created_at      TEXT NOT NULL,
      fairness        TEXT NOT NULL
    );
    CREATE INDEX idx_plinko_drop_player ON plinko_drop(player_id, created_at);
  `
};
