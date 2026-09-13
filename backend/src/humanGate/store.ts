// Human-gate session store.
//
// The persona-challenge web app plays its reflex game client-side, then posts
// the computed score back under an opaque single-use gate token. Registration
// requires a token with a recorded verdict, so an account cannot be created
// without a completed gate run. Tokens hash to sha256 before storage — same
// convention as auth sessions, raw token never touches the DB.

import { randomBytes, createHash } from "crypto";
import { db } from "../db";

const GATE_TTL_MS = 15 * 60 * 1000; // 15 minutes — signup should not take longer

export type GateVerdict = "pass" | "escalate" | "flag";

export interface GateSession {
  score: number;
  verdict: GateVerdict;
  flags: string[];
  personaInquiryId?: string | null;
  personaStatus?: string | null;
}

const tokenHash = (token: string) => createHash("sha256").update(token).digest("hex");

export function createGateSession(): { gateToken: string; expiresAt: string } {
  const token = randomBytes(32).toString("base64url");
  const expiresAt = new Date(Date.now() + GATE_TTL_MS).toISOString();
  db.prepare(
    `INSERT INTO human_gate_session (token_hash, expires_at)
     VALUES (?, ?)`
  ).run(tokenHash(token), expiresAt.replace("T", " ").replace("Z", ""));
  return { gateToken: token, expiresAt };
}

export type GateResultError =
  | "TOKEN_INVALID"   // unknown / expired / consumed
  | "ALREADY_SCORED"  // result already posted for this token
  | "BAD_RESULT";     // malformed score/verdict payload

const VERDICTS: GateVerdict[] = ["pass", "escalate", "flag"];

/** Record the game's verdict against a live gate token. */
export function recordGateResult(
  token: string,
  score: unknown,
  verdict: unknown,
  flags: unknown
): { error: GateResultError } | { ok: true } {
  if (
    typeof score !== "number" || !Number.isFinite(score) || score < 0 || score > 100 ||
    typeof verdict !== "string" || !VERDICTS.includes(verdict as GateVerdict) ||
    !Array.isArray(flags) || flags.some((f) => typeof f !== "string")
  ) {
    return { error: "BAD_RESULT" };
  }
  const r = db.prepare(
    `UPDATE human_gate_session
     SET score = ?, verdict = ?, flags = ?
     WHERE token_hash = ? AND consumed_at IS NULL AND score IS NULL
       AND expires_at > datetime('now')`
  ).run(Math.round(score), verdict, JSON.stringify(flags), tokenHash(token));
  if (r.changes === 0) {
    const row = db.prepare(
      `SELECT score FROM human_gate_session
       WHERE token_hash = ? AND consumed_at IS NULL AND expires_at > datetime('now')`
    ).get(tokenHash(token)) as { score: number | null } | undefined;
    return { error: row ? "ALREADY_SCORED" : "TOKEN_INVALID" };
  }
  return { ok: true };
}

export type GateError = "TOKEN_INVALID" | "NOT_SCORED";

function readGate(token: string) {
  return db.prepare(
    `SELECT score, verdict, flags, persona_inquiry_id, persona_status FROM human_gate_session
     WHERE token_hash = ? AND consumed_at IS NULL AND expires_at > datetime('now')`
  ).get(tokenHash(token)) as {
    score: number | null;
    verdict: GateVerdict | null;
    flags: string | null;
    persona_inquiry_id: string | null;
    persona_status: string | null;
  } | undefined;
}

/** Check a gate token is live and scored without consuming it. */
export function inspectGateToken(
  token: string
): { error: GateError } | { ok: true; session: GateSession } {
  const row = readGate(token);
  if (!row) return { error: "TOKEN_INVALID" };
  if (row.score === null || row.verdict === null) return { error: "NOT_SCORED" };
  return {
    ok: true,
    session: {
      score: row.score,
      verdict: row.verdict,
      flags: row.flags ? (JSON.parse(row.flags) as string[]) : [],
      personaInquiryId: row.persona_inquiry_id,
      personaStatus: row.persona_status
    }
  };
}

/**
 * Consume a scored gate token during registration: binds it to the new
 * account so the verdict is queryable per player, and burns the token.
 * Flagged verdicts are still consumable — the pre-gate is non-punitive,
 * the flag rides on the account for later review.
 */
export function consumeGateToken(
  token: string,
  playerId: string
): { error: GateError } | { ok: true; session: GateSession } {
  const inspected = inspectGateToken(token);
  if ("error" in inspected) return inspected;
  db.prepare(
    `UPDATE human_gate_session SET player_id = ?, consumed_at = datetime('now')
     WHERE token_hash = ?`
  ).run(playerId, tokenHash(token));
  return inspected;
}

/**
 * Bind a server-created Persona inquiry to a scored, live gate session.
 * Only sessions that already posted a result can open an inquiry — bots
 * can't burn Persona calls without completing the game first.
 */
export function attachPersonaInquiry(
  token: string,
  inquiryId: string
): { error: "TOKEN_INVALID" | "NOT_SCORED" } | { ok: true } {
  const inspected = inspectGateToken(token);
  if ("error" in inspected) return inspected;
  db.prepare(
    `UPDATE human_gate_session SET persona_inquiry_id = ?
     WHERE token_hash = ?`
  ).run(inquiryId, tokenHash(token));
  return { ok: true };
}

/**
 * Record the server-verified Persona status for a session's inquiry.
 * Fails if the inquiry isn't the one bound to this token — a client can
 * only ever report against its own session's inquiry.
 */
export function recordPersonaStatus(
  token: string,
  inquiryId: string,
  status: string
): { error: "TOKEN_INVALID" | "INQUIRY_MISMATCH" } | { ok: true } {
  const r = db.prepare(
    `UPDATE human_gate_session SET persona_status = ?
     WHERE token_hash = ? AND persona_inquiry_id = ?
       AND consumed_at IS NULL AND expires_at > datetime('now')`
  ).run(status, tokenHash(token), inquiryId);
  if (r.changes === 0) {
    const row = db.prepare(
      `SELECT persona_inquiry_id FROM human_gate_session
       WHERE token_hash = ? AND consumed_at IS NULL AND expires_at > datetime('now')`
    ).get(tokenHash(token)) as { persona_inquiry_id: string | null } | undefined;
    return { error: row ? "INQUIRY_MISMATCH" : "TOKEN_INVALID" };
  }
  return { ok: true };
}

/** Hash of a gate token — used as the Persona reference-id so the raw
 *  token never leaves our system. */
export function gateTokenHash(token: string): string {
  return tokenHash(token);
}

/** Latest gate verdict for a player, for admin/review surfaces. */
export function latestGateFor(playerId: string): (GateSession & { consumedAt: string }) | null {
  const row = db.prepare(
    `SELECT score, verdict, flags, persona_inquiry_id, persona_status, consumed_at
     FROM human_gate_session
     WHERE player_id = ? ORDER BY consumed_at DESC LIMIT 1`
  ).get(playerId) as {
    score: number; verdict: GateVerdict; flags: string | null;
    persona_inquiry_id: string | null; persona_status: string | null;
    consumed_at: string;
  } | undefined;
  if (!row) return null;
  return {
    score: row.score,
    verdict: row.verdict,
    flags: row.flags ? (JSON.parse(row.flags) as string[]) : [],
    personaInquiryId: row.persona_inquiry_id,
    personaStatus: row.persona_status,
    consumedAt: row.consumed_at
  };
}

/** Housekeeping: drop expired unconsumed tokens. Call alongside sweepExpiredSessions. */
export function sweepExpiredGateSessions(): number {
  const r = db.prepare(
    `DELETE FROM human_gate_session WHERE expires_at <= datetime('now') AND consumed_at IS NULL`
  ).run();
  return Number(r.changes);
}
