import type { Migration } from "../migrate";

/**
 * Kitchen Mines rounds.
 *
 * One row per round, written before the first dish is lifted, holding the
 * wagered monster, the mine layout, and every tile revealed so far.
 *
 * The layout is stored because it is decided up front: a game that picked
 * where the mines were *after* you clicked would not be the game the published
 * odds describe. Keeping it server-side and out of every live payload is what
 * makes that claim checkable rather than merely stated.
 */
export const migration: Migration = {
  version: 5,
  name: "mines",
  sql: `
    CREATE TABLE mines_round (
      round_id            TEXT PRIMARY KEY,
      player_id           TEXT NOT NULL,
      -- The wagered monster, copied in full: it is gone from the inventory, so
      -- this is the only surviving record of what was risked.
      wager               TEXT NOT NULL,
      wager_value         INTEGER NOT NULL,
      mines               INTEGER NOT NULL,
      -- JSON arrays of tile indices 0..24.
      layout              TEXT NOT NULL,
      revealed            TEXT NOT NULL DEFAULT '[]',
      status              TEXT NOT NULL,   -- ACTIVE | SERVED | BURNT
      started_at          TEXT NOT NULL,
      cash_out_multiplier REAL,
      final_net_worth     INTEGER,
      reward              TEXT,            -- JSON drop, when the round was served
      completed_at        TEXT,
      fairness            TEXT NOT NULL
    );
    CREATE INDEX idx_mines_round_player ON mines_round(player_id, started_at);
  `
};
