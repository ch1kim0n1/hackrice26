// Account system backbone.
//
// Adds real accounts on top of the existing X-Player-Id identity model:
//
//   account  — username + scrypt password hash, owns one player_id
//   session  — bearer token -> player_id, 30-day expiry, refreshable
//
// Auth flow: POST /auth/register or /auth/login returns { playerId, token }.
// The client then sends `Authorization: Bearer <token>` on every request.
// requirePlayerId resolves the token to the account's player_id, so all
// existing per-player routes (scan, lootbox, vitals, profile, battle) work
// unchanged — the account system layers identity ON TOP of the header model.
//
// Tokens are opaque random strings, not JWTs: hackathon scope favors a
// session table (instant revocation, no secret management) over signed
// tokens. Swap for Sign in with Apple post-hackathon.

import crypto, { randomBytes, scryptSync, timingSafeEqual, createHash } from "crypto";
import { db } from "../db";
import { hasDatabaseUrl } from "../db/pg";
import { enqueueMirror } from "../services/mirrorQueue";

// ===== Password hashing (scrypt, stdlib crypto — no deps) =====

const SCRYPT_OPTS = { N: 16384, r: 8, p: 1 };
const SALT_BYTES = 16;
const KEY_LEN = 32;

function hashPassword(password: string): string {
  const salt = randomBytes(SALT_BYTES);
  const hash = scryptSync(password, salt, KEY_LEN, SCRYPT_OPTS);
  return `${salt.toString("hex")}$${hash.toString("hex")}`;
}

function verifyPassword(password: string, stored: string): boolean {
  const [saltHex, hashHex] = stored.split("$");
  if (!saltHex || !hashHex) return false;
  const salt = Buffer.from(saltHex, "hex");
  const expected = Buffer.from(hashHex, "hex");
  const actual = scryptSync(password, salt, expected.length, SCRYPT_OPTS);
  return timingSafeEqual(actual, expected);
}

// ===== Validation =====

export const USERNAME_PATTERN = /^[a-zA-Z0-9_.-]{3,24}$/;
const MIN_PASSWORD = 8;
const MAX_PASSWORD = 128;

export function validateCredentials(username: unknown, password: unknown): string | null {
  if (typeof username !== "string" || !USERNAME_PATTERN.test(username)) {
    return "username must be 3-24 chars of [a-zA-Z0-9_.-]";
  }
  if (typeof password !== "string" || password.length < MIN_PASSWORD || password.length > MAX_PASSWORD) {
    return `password must be ${MIN_PASSWORD}-${MAX_PASSWORD} characters`;
  }
  return null;
}

// ===== Accounts =====

export interface Account {
  player_id: string;
  username: string;
  display_name: string;
  created_at: string;
}

export function createAccount(username: string, password: string, displayName?: string): Account {
  const playerId = crypto.randomUUID();
  const name = displayName?.trim() || username;
  const passwordHash = hashPassword(password);
  db.exec("BEGIN");
  try {
    db.prepare(`INSERT INTO players (id, display_name, is_portable) VALUES (?, ?, 1)`).run(playerId, name);
    db.prepare(
      `INSERT INTO account (player_id, username, password_hash, display_name)
       VALUES (?, ?, ?, ?)`
    ).run(playerId, username, passwordHash, displayName ?? "");
    db.exec("COMMIT");
  } catch (error) {
    db.exec("ROLLBACK");
    throw error;
  }
  if (hasDatabaseUrl()) {
    // The already-computed hash crosses to Postgres, same as it just crossed
    // into SQLite's own `account` table -- never the plaintext password.
    enqueueMirror("account_created", playerId, {
      playerId,
      username,
      displayName: name,
      passwordHash,
    });
  }
  return accountFor(playerId)!;
}

export function accountFor(playerId: string): Account | null {
  const row = db
    .prepare(`SELECT player_id, username, display_name, created_at FROM account WHERE player_id = ?`)
    .get(playerId) as Account | undefined;
  return row ?? null;
}

export function login(username: string, password: string): Account | null {
  const row = db
    .prepare(`SELECT player_id, username, display_name, created_at, password_hash FROM account WHERE username = ?`)
    .get(username) as (Account & { password_hash: string }) | undefined;
  if (!row || !verifyPassword(password, row.password_hash)) return null;
  db.prepare(`UPDATE account SET last_login_at = datetime('now') WHERE player_id = ?`).run(row.player_id);
  return { player_id: row.player_id, username: row.username, display_name: row.display_name, created_at: row.created_at };
}

export function usernameTaken(username: string): boolean {
  return !!db.prepare(`SELECT 1 FROM account WHERE username = ?`).get(username);
}

export function setDisplayName(playerId: string, name: string): void {
  db.prepare(`UPDATE account SET display_name = ? WHERE player_id = ?`).run(name, playerId);
}

// ===== Sessions =====

const SESSION_TTL_MS = 30 * 24 * 60 * 60 * 1000; // 30 days
const tokenHash = (token: string) => createHash("sha256").update(token).digest("hex");

export function createSession(playerId: string): string {
  const token = randomBytes(32).toString("base64url");
  const hash = tokenHash(token);
  db.prepare(
    `INSERT INTO session (token_hash, player_id, expires_at)
     VALUES (?, ?, datetime('now', '+30 days'))`
  ).run(hash, playerId);
  if (hasDatabaseUrl()) {
    enqueueMirror("session_event", `session:${hash}`, {
      action: "create",
      playerId,
      tokenHashHex: hash,
      expiresAt: new Date(Date.now() + SESSION_TTL_MS).toISOString(),
    });
  }
  return token;
}

/** Resolve a bearer token to a player_id. Returns null if unknown/expired/revoked. */
export function resolveSession(token: string): string | null {
  const row = db
    .prepare(
      `SELECT player_id FROM session
       WHERE token_hash = ? AND revoked = 0 AND expires_at > datetime('now')`
    )
    .get(tokenHash(token)) as { player_id: string } | undefined;
  return row?.player_id ?? null;
}

export function revokeSession(token: string): void {
  const hash = tokenHash(token);
  // Look up the owner before revoking -- resolveSession filters on
  // revoked = 0, so it would come back null if asked after the UPDATE below.
  const row = db.prepare(`SELECT player_id FROM session WHERE token_hash = ?`).get(hash) as
    | { player_id: string }
    | undefined;
  db.prepare(`UPDATE session SET revoked = 1 WHERE token_hash = ?`).run(hash);
  if (hasDatabaseUrl() && row) {
    enqueueMirror("session_event", `revoke:${hash}`, {
      action: "revoke",
      playerId: row.player_id,
      tokenHashHex: hash,
    });
  }
}

export function revokeAllSessions(playerId: string): void {
  db.prepare(`UPDATE session SET revoked = 1 WHERE player_id = ?`).run(playerId);
  if (hasDatabaseUrl()) {
    enqueueMirror("session_event", `revoke-all:${playerId}`, {
      action: "revoke_all",
      playerId,
    });
  }
}

/** Housekeeping: drop expired sessions. Call on a timer from index.ts. */
export function sweepExpiredSessions(): number {
  const r = db.prepare(`DELETE FROM session WHERE expires_at <= datetime('now')`).run();
  return Number(r.changes);
}
