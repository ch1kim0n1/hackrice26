import { Request, Response, NextFunction } from "express";
import { resolveSession } from "../auth/store";

/**
 * Player identity for the backend.
 *
 * The client can authenticate in one of two ways:
 *   1. `Authorization: Bearer <session-token>` — resolves to an account's
 *      player_id via the session table (issue #? auth).
 *   2. `X-Player-Id` header — the original hackathon header, still accepted
 *      for pre-auth/headless clients and tests.
 *
 * Bearer tokens take precedence. If a token is supplied but invalid, the
 * request is rejected with 401 (AUTH_REQUIRED) rather than falling back to
 * the header, so a stolen/mistyped token cannot silently downgrade identity.
 *
 * The header path is unauthenticated: any syntactically valid id resolves to
 * that player's full state. It exists for pre-auth/headless clients and tests.
 * Set NUTRIQUEST_REQUIRE_AUTH=1 to refuse it — required for any deployment
 * that faces untrusted traffic.
 */

export const PLAYER_ID_HEADER = "x-player-id";
const REQUIRE_AUTH = process.env.NUTRIQUEST_REQUIRE_AUTH === "1";
const PLAYER_ID_PATTERN = /^[A-Za-z0-9_-]{6,64}$/;

export interface PlayerRequest extends Request {
  playerId?: string;
}

export function extractBearerToken(req: Request): string | undefined {
  const auth = req.headers.authorization;
  if (typeof auth !== "string" || !auth.startsWith("Bearer ")) return undefined;
  const token = auth.slice(7).trim();
  return token.length > 0 ? token : undefined;
}

function rejectPlayerId(res: Response, message: string, code = "PLAYER_ID_INVALID"): void {
  res.status(400).json({
    error: { code, message }
  });
}

export function requirePlayerId(req: PlayerRequest, res: Response, next: NextFunction): void {
  const token = extractBearerToken(req);

  if (token) {
    const playerId = resolveSession(token);
    if (!playerId) {
      res.status(401).json({
        error: { code: "AUTH_REQUIRED", message: "Invalid or expired session token." }
      });
      return;
    }
    req.playerId = playerId;
    next();
    return;
  }

  const raw = req.headers[PLAYER_ID_HEADER];

  if (raw === undefined || REQUIRE_AUTH) {
    res.status(REQUIRE_AUTH ? 401 : 400).json({
      error: {
        code: REQUIRE_AUTH ? "AUTH_REQUIRED" : "PLAYER_ID_REQUIRED",
        message: REQUIRE_AUTH
          ? "Authorization bearer token required."
          : `Missing ${PLAYER_ID_HEADER} header or Authorization bearer token.`
      }
    });
    return;
  }

  const id = Array.isArray(raw) ? raw[0] : raw;
  if (!PLAYER_ID_PATTERN.test(id)) {
    rejectPlayerId(res, `${PLAYER_ID_HEADER} must be 6-64 characters of [A-Za-z0-9_-].`);
    return;
  }

  req.playerId = id;
  next();
}

/** Same check for optional-player routes: header absent -> null, malformed -> 400. */
export function optionalPlayerId(req: PlayerRequest, res: Response, next: NextFunction): void {
  const token = extractBearerToken(req);
  if (token) {
    const playerId = resolveSession(token);
    if (playerId) {
      req.playerId = playerId;
    }
    next();
    return;
  }

  const raw = req.headers[PLAYER_ID_HEADER];
  if (raw === undefined || REQUIRE_AUTH) {
    next();
    return;
  }
  const id = Array.isArray(raw) ? raw[0] : raw;
  if (!PLAYER_ID_PATTERN.test(id)) {
    rejectPlayerId(res, `${PLAYER_ID_HEADER} must be 6-64 characters of [A-Za-z0-9_-].`);
    return;
  }
  req.playerId = id;
  next();
}
