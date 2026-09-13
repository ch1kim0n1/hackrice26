import { Router } from "express";
import {
  createAccount, login, usernameTaken, validateCredentials,
  createSession, revokeSession, accountFor, Account
} from "./store";
import { PlayerRequest, extractBearerToken, optionalPlayerId } from "../middleware/player";
import { rateLimit } from "../middleware/security";
import { inspectGateToken, consumeGateToken } from "../humanGate/store";

export const authRouter = Router();

// Resolve bearer tokens on auth routes that need identity (me, logout).
// Optional so register/login do not require a token.
authRouter.use(optionalPlayerId);

const accountPayload = (account: Account, token: string) => ({
  playerId: account.player_id,
  token,
  account: {
    username: account.username,
    displayName: account.display_name,
    createdAt: account.created_at
  }
});

// POST /auth/register { username, password, displayName?, gateToken }
// Creates account + session. 409 on taken username.
// gateToken is required: a completed human-gate run (POST /human-gate/session
// then /result) must back every new account. The token is single-use and
// binds its verdict to the account; a "flag" verdict still registers —
// the gate is non-punitive, the flag stays queryable for review.
authRouter.post("/register", rateLimit({ windowMs: 60_000, max: 10, keyPrefix: "auth:register" }), (req, res) => {
  const { username, password, displayName, gateToken } = req.body as Record<string, unknown>;
  const invalid = validateCredentials(username, password);
  if (invalid) return res.status(400).json({ error: { code: "VALIDATION", message: invalid } });
  if (displayName !== undefined && (typeof displayName !== "string" || displayName.trim().length < 2 || displayName.length > 32)) {
    return res.status(400).json({ error: { code: "VALIDATION", message: "displayName must be 2-32 characters" } });
  }
  if (typeof gateToken !== "string" || gateToken.length === 0) {
    return res.status(403).json({ error: { code: "HUMAN_GATE_REQUIRED", message: "Complete the human check first." } });
  }
  const gate = inspectGateToken(gateToken);
  if ("error" in gate) {
    return res.status(403).json({ error: { code: gate.error, message: "Human check missing or expired." } });
  }
  if (usernameTaken(username as string)) {
    return res.status(409).json({ error: { code: "USERNAME_TAKEN", message: "That username is taken." } });
  }
  const account = createAccount(username as string, password as string, displayName?.toString().trim() || undefined);
  consumeGateToken(gateToken, account.player_id);
  res.status(201).json({
    ...accountPayload(account, createSession(account.player_id)),
    humanGate: {
      score: gate.session.score,
      verdict: gate.session.verdict,
      personaStatus: gate.session.personaStatus ?? null
    }
  });
});

// POST /auth/login { username, password }
// Generic 401 — never reveal whether the username exists.
authRouter.post("/login", rateLimit({ windowMs: 60_000, max: 10, keyPrefix: "auth:login" }), (req, res) => {
  const { username, password } = req.body as Record<string, unknown>;
  const invalid = validateCredentials(username, password);
  if (invalid) return res.status(400).json({ error: { code: "VALIDATION", message: invalid } });
  const account = login(username as string, password as string);
  if (!account) {
    return res.status(401).json({ error: { code: "AUTH_FAILED", message: "Invalid username or password." } });
  }
  res.json(accountPayload(account, createSession(account.player_id)));
});

// POST /auth/logout — revokes the presented bearer token.
authRouter.post("/logout", (req: PlayerRequest, res) => {
  const token = extractBearerToken(req);
  if (token) revokeSession(token);
  res.json({ ok: true });
});

// GET /auth/me — current account for a bearer token. 401 if invalid.
authRouter.get("/me", (req: PlayerRequest, res) => {
  if (!req.playerId) {
    return res.status(401).json({ error: { code: "AUTH_REQUIRED", message: "Send Authorization: Bearer <token>." } });
  }
  const account = accountFor(req.playerId);
  if (!account) return res.status(401).json({ error: { code: "AUTH_REQUIRED", message: "Session expired." } });
  res.json({ playerId: account.player_id, account: { username: account.username, displayName: account.display_name, createdAt: account.created_at } });
});
