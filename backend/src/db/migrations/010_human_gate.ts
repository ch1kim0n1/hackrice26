import type { Migration } from "../migrate";

/**
 * Human-gate sessions: the link between the standalone "Prove You're Human"
 * reflex game (persona-challenge/) and account registration.
 *
 * Flow: the signup web app calls POST /human-gate/session for an opaque
 * token, plays the game, POSTs the scored result back, then calls
 * POST /auth/register with the same token. Registration consumes the row:
 * player_id binds the verdict to the new account and the token can never
 * be used twice.
 *
 * verdict is stored verbatim from the client — client-side scoring can be
 * forged, so the value here is binding a gate attempt to an account and
 * making flag/escalate visible for review, not cryptographic proof.
 */
export const migration: Migration = {
  version: 10,
  name: "human_gate",
  sql: `
    CREATE TABLE human_gate_session (
      token_hash  TEXT PRIMARY KEY,          -- sha256(gateToken); raw token never stored
      created_at  TEXT NOT NULL DEFAULT (datetime('now')),
      expires_at  TEXT NOT NULL,
      score       INTEGER,                   -- suspicion score 0-100, null until result posted
      verdict     TEXT CHECK (verdict IN ('pass','escalate','flag')),
      flags       TEXT,                      -- JSON array of tripped signal names
      player_id   TEXT REFERENCES account(player_id),  -- set when register consumes the token
      consumed_at TEXT
    );
    CREATE INDEX idx_human_gate_player ON human_gate_session(player_id);
  `
};
