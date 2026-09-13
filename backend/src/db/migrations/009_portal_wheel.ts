import type { Migration } from "../migrate";

/**
 * Portal Wheel spins.
 *
 * Like a Plinko drop and unlike a cauldron round, a spin is decided, paid and
 * finished inside one request, so there is no live state here — the row is
 * history. What was wagered, which colour was bet, which of the sixteen
 * sections the pointer stopped on, and what came back.
 *
 * `multiplier` is the price the chosen colour was quoted at, stored rather than
 * recomputed: the section layout in data/portalWheel.ts is tunable, and a wheel
 * rebalanced later must not silently restate what an old spin paid.
 *
 * `section` is kept alongside `winning_color` even though the colour is
 * derivable from it, because the reverse is not true and the section is what a
 * disputed spin has to be replayed against.
 */
export const migration: Migration = {
  version: 9,
  name: "portal_wheel",
  sql: `
    CREATE TABLE portal_wheel_spin (
      spin_id         TEXT PRIMARY KEY,
      player_id       TEXT NOT NULL,
      -- The wagered monster, copied in full: it is gone from the inventory, so
      -- this is the only surviving record of it.
      wager           TEXT NOT NULL,
      wager_value     INTEGER NOT NULL,
      pick            TEXT NOT NULL CHECK (pick IN ('blue','red','yellow','green')),
      section         INTEGER NOT NULL CHECK (section >= 0),
      winning_color   TEXT NOT NULL CHECK (winning_color IN ('blue','red','yellow','green')),
      won             INTEGER NOT NULL CHECK (won IN (0, 1)),
      -- What the picked colour was quoted at, frozen at spin time. Paid only
      -- when won = 1.
      multiplier      REAL NOT NULL,
      final_net_worth INTEGER NOT NULL,
      reward          TEXT,            -- JSON drop; null on a wrong colour
      created_at      TEXT NOT NULL,
      fairness        TEXT NOT NULL,
      -- A win pays and a loss does not. Enforced here so a bug in the service
      -- cannot write a row that claims both.
      CHECK ((won = 1) = (final_net_worth > 0) OR wager_value = 0)
    );
    CREATE INDEX idx_portal_wheel_spin_player ON portal_wheel_spin(player_id, created_at);
  `
};
