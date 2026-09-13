import { Router } from "express";
import { z } from "zod";
import {
  createAccount, login, usernameTaken, validateCredentials,
  createSession, revokeSession, accountFor, Account
} from "./store";
import { PlayerRequest, extractBearerToken, optionalPlayerId } from "../middleware/player";
import { rateLimit } from "../middleware/security";
import { inspectGateToken, consumeGateToken } from "../humanGate/store";
import { personaConfigured, createInquiry, resumeInquiry, getInquiry, PersonaError } from "../humanGate/persona";
import {
  RICKROLL_URL, VERIFIED_PERSONA_STATUSES, newLoginToken, loginTokenHash,
  storeLoginChallenge, peekLoginChallenge, consumeLoginChallenge, recordLoginHoneypot
} from "./personaLogin";

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

const personaErrorStatus = (err: unknown) =>
  err instanceof PersonaError && err.status >= 400 && err.status < 600 ? err.status : 502;

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
// Without Persona configured this returns the session directly. With it,
// the password alone is not enough: 202 { personaRequired, loginToken,
// inquiryId, sessionToken } opens the Persona widget, and the session is
// only issued by /login/persona/complete.
authRouter.post("/login", rateLimit({ windowMs: 60_000, max: 10, keyPrefix: "auth:login" }), async (req, res) => {
  const { username, password } = req.body as Record<string, unknown>;
  const invalid = validateCredentials(username, password);
  if (invalid) return res.status(400).json({ error: { code: "VALIDATION", message: invalid } });
  const account = login(username as string, password as string);
  if (!account) {
    return res.status(401).json({ error: { code: "AUTH_FAILED", message: "Invalid username or password." } });
  }
  if (!personaConfigured()) {
    return res.json(accountPayload(account, createSession(account.player_id)));
  }
  const loginToken = newLoginToken();
  try {
    const inquiry = await createInquiry(loginTokenHash(loginToken));
    const sessionToken = await resumeInquiry(inquiry.id);
    storeLoginChallenge(loginToken, account.player_id, inquiry.id);
    res.status(202).json({ personaRequired: true, loginToken, inquiryId: inquiry.id, sessionToken });
  } catch (err) {
    res.status(personaErrorStatus(err)).json({
      error: { code: "PERSONA_ERROR", message: err instanceof Error ? err.message : "Persona request failed." }
    });
  }
});

const personaLoginBody = z.object({
  loginToken: z.string().min(1),
  inquiryId: z.string().min(1)
});

// POST /auth/login/persona/complete { loginToken, inquiryId }
// Called when the widget closes. The status is read from Persona server-side,
// never taken from the client, and the inquiry must be the one opened for
// this login. The challenge is single use: a declined or abandoned check
// means logging in again.
authRouter.post(
  "/login/persona/complete",
  rateLimit({ windowMs: 60_000, max: 20, keyPrefix: "auth:persona" }),
  async (req, res) => {
    if (!personaConfigured()) {
      return res.status(503).json({ error: { code: "PERSONA_NOT_CONFIGURED", message: "Identity verification is not enabled." } });
    }
    const parsed = personaLoginBody.safeParse(req.body);
    if (!parsed.success) {
      return res.status(400).json({ error: { code: "VALIDATION", message: "loginToken and inquiryId are required" } });
    }
    const { loginToken, inquiryId } = parsed.data;
    const challenge = peekLoginChallenge(loginToken);
    if (!challenge) {
      return res.status(403).json({ error: { code: "LOGIN_EXPIRED", message: "Login expired. Please log in again." } });
    }
    if (challenge.inquiryId !== inquiryId) {
      return res.status(409).json({ error: { code: "INQUIRY_MISMATCH", message: "Inquiry is not bound to this login." } });
    }
    try {
      const inquiry = await getInquiry(inquiryId);
      if (inquiry.referenceId !== loginTokenHash(loginToken)) {
        return res.status(409).json({ error: { code: "INQUIRY_MISMATCH", message: "Inquiry is not bound to this login." } });
      }
      consumeLoginChallenge(loginToken);
      if (!VERIFIED_PERSONA_STATUSES.has(inquiry.status)) {
        return res.status(403).json({
          error: { code: "PERSONA_NOT_VERIFIED", message: "Identity check wasn't completed. Please log in again." },
          personaStatus: inquiry.status
        });
      }
      const account = accountFor(challenge.playerId);
      if (!account) {
        return res.status(401).json({ error: { code: "AUTH_FAILED", message: "Invalid username or password." } });
      }
      res.json({ ...accountPayload(account, createSession(account.player_id)), personaStatus: inquiry.status });
    } catch (err) {
      res.status(personaErrorStatus(err)).json({
        error: { code: "PERSONA_ERROR", message: err instanceof Error ? err.message : "Persona request failed." }
      });
    }
  }
);

// Honeypot: /auth/login/skip-verification does not skip anything. It is
// only advertised where an automated agent looks for a way around Persona
// (a hidden link, a hidden field, a comment in the page source), so a hit
// is logged to the security monitor and the visitor is rickrolled.
authRouter.get(
  "/login/skip-verification",
  rateLimit({ windowMs: 60_000, max: 30, keyPrefix: "auth:honeypot" }),
  (_req, res) => {
    recordLoginHoneypot("api");
    res.redirect(302, RICKROLL_URL);
  }
);

const honeypotBody = z.object({ trap: z.enum(["field", "link", "api", "webdriver"]).optional() });

authRouter.post(
  "/login/skip-verification",
  rateLimit({ windowMs: 60_000, max: 30, keyPrefix: "auth:honeypot" }),
  (req, res) => {
    const parsed = honeypotBody.safeParse(req.body ?? {});
    recordLoginHoneypot(parsed.success ? parsed.data.trap ?? "api" : "api");
    res.status(403).json({ error: { code: "NICE_TRY", message: "Nice try, robot." }, redirect: RICKROLL_URL });
  }
);

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
