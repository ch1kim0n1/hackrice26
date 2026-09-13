// Human-vs-AI Persona demo — sandbox-only, isolated from the real auth flow.
//
// Every route here is gated by ENABLE_PERSONA_DEMO=true (404s otherwise).
// The one rule that matters: /protected asks the session's server-owned
// personaStatus, never the actor type. A human and an agent hit the exact
// same check; the agent is blocked because it never completes a real
// Persona verification, not because the server special-cases it.

import { Router, Request, Response } from "express";
import { z } from "zod";
import { rateLimit } from "../middleware/security";
import { createDemoSession, getDemoSession, setPersonaPending, setPersonaResult, triggerHoneypot, DemoSession } from "./demoSessionStore";
import { emitSecurityEvent, listSecurityEvents, subscribeSecurityEvents } from "./securityEventStore";
import { PersonaSandboxAdapter, isPersonaSandboxConfigured } from "./personaSandboxAdapter";
import { MockPersonaAdapter } from "./mockPersonaAdapter";
import type { PersonaVerificationAdapter } from "./personaAdapter";

export const demoRouter = Router();

function demoEnabled(): boolean {
  return process.env.ENABLE_PERSONA_DEMO === "true";
}

// Not Found (not 503) when the flag is off — the sandbox surface shouldn't
// even be discoverable outside demo development.
demoRouter.use((_req, res, next) => {
  if (!demoEnabled()) {
    return res.status(404).json({ error: { code: "NOT_FOUND", message: "Not Found" } });
  }
  next();
});

const sandboxAdapter = new PersonaSandboxAdapter();
const mockAdapter = new MockPersonaAdapter();

/** Prefer the real Persona sandbox; fall back to the dev-only mock, and
 *  only outside production, even if someone leaves ENABLE_PERSONA_DEMO on. */
function activeAdapter(): PersonaVerificationAdapter | null {
  if (isPersonaSandboxConfigured()) return sandboxAdapter;
  if (process.env.NODE_ENV !== "production") return mockAdapter;
  return null;
}

function readToken(req: Request): string | undefined {
  const header = req.header("x-demo-session");
  if (typeof header === "string" && header) return header;
  const q = req.query.sessionToken;
  return typeof q === "string" && q ? q : undefined;
}

function requireSession(req: Request, res: Response): DemoSession | undefined {
  const token = readToken(req);
  const session = token ? getDemoSession(token) : undefined;
  if (!session) {
    res.status(401).json({ error: { code: "NO_SESSION", message: "No active demo session." } });
    return undefined;
  }
  return session;
}

const sessionBody = z.object({ actorType: z.enum(["human", "agent"]) });

// POST /demo/session { actorType }
demoRouter.post(
  "/session",
  rateLimit({ windowMs: 60_000, max: 30, keyPrefix: "demo:session" }),
  (req, res) => {
    const parsed = sessionBody.safeParse(req.body);
    if (!parsed.success) {
      return res.status(400).json({ error: { code: "VALIDATION", message: "actorType must be \"human\" or \"agent\"" } });
    }
    const { token, session } = createDemoSession(parsed.data.actorType);
    emitSecurityEvent(
      "SESSION_CREATED",
      session,
      `${session.actorType === "human" ? "Human" : "Agent"} session created`,
      "info"
    );
    res.status(201).json({ sessionToken: token, session });
  }
);

// GET /demo/protected — the one authorization check both actors share.
demoRouter.get(
  "/protected",
  rateLimit({ windowMs: 60_000, max: 60, keyPrefix: "demo:protected" }),
  (req, res) => {
    const session = requireSession(req, res);
    if (!session) return;

    emitSecurityEvent("PROTECTED_ROUTE_REQUESTED", session, "Protected route requested", "info");

    if (session.personaStatus !== "verified") {
      emitSecurityEvent("PERSONA_REQUIRED", session, "Persona verification required", "warning");
      emitSecurityEvent("ACCESS_BLOCKED", session, "Unverified session blocked", "blocked");
      return res.status(403).json({
        code: "PERSONA_REQUIRED",
        message: "Human identity verification is required."
      });
    }

    emitSecurityEvent("ACCESS_GRANTED", session, "Protected access granted", "success");
    res.status(200).json({ success: true, resource: "NutriQuest Protected Demo Area" });
  }
);

// POST /demo/persona/start — begin verification via whichever adapter is active.
demoRouter.post(
  "/persona/start",
  rateLimit({ windowMs: 60_000, max: 10, keyPrefix: "demo:persona" }),
  async (req, res) => {
    const session = requireSession(req, res);
    if (!session) return;
    const adapter = activeAdapter();
    if (!adapter) {
      return res.status(503).json({ error: { code: "PERSONA_NOT_CONFIGURED", message: "Persona sandbox is not configured." } });
    }
    try {
      const result = await adapter.startVerification(session.id, session.actorType);
      setPersonaPending(session);
      emitSecurityEvent("PERSONA_STARTED", session, "Persona verification started", "info");
      res.status(201).json({
        inquiryId: result.inquiryId ?? null,
        personaSessionToken: result.personaSessionToken ?? null,
        status: session.personaStatus
      });
    } catch (err) {
      res.status(502).json({ error: { code: "PERSONA_ERROR", message: err instanceof Error ? err.message : "Persona request failed." } });
    }
  }
);

// POST /demo/persona/complete — backend confirms the real status; the
// client's word (widget onComplete) is never trusted on its own.
demoRouter.post(
  "/persona/complete",
  rateLimit({ windowMs: 60_000, max: 20, keyPrefix: "demo:persona" }),
  async (req, res) => {
    const session = requireSession(req, res);
    if (!session) return;
    const adapter = activeAdapter();
    if (!adapter) {
      return res.status(503).json({ error: { code: "PERSONA_NOT_CONFIGURED", message: "Persona sandbox is not configured." } });
    }
    try {
      const result = await adapter.getVerificationStatus(session.id);
      if (result.status === "pending") {
        return res.json({ status: session.personaStatus });
      }
      setPersonaResult(session, result.status);
      emitSecurityEvent(
        result.status === "verified" ? "PERSONA_VERIFIED" : "PERSONA_FAILED",
        session,
        result.status === "verified" ? "Persona verification confirmed" : "Persona verification failed",
        result.status === "verified" ? "success" : "warning"
      );
      res.json({ status: session.personaStatus });
    } catch (err) {
      res.status(502).json({ error: { code: "PERSONA_ERROR", message: err instanceof Error ? err.message : "Persona request failed." } });
    }
  }
);

// GET /demo/persona/status — cheap read of the server-owned status, no
// external call. Client polls this; it never sets its own status.
demoRouter.get("/persona/status", (req, res) => {
  const session = requireSession(req, res);
  if (!session) return;
  res.json({ status: session.personaStatus });
});

// GET /demo/honeypot — isolated decoy. No real data, no mutation of real
// player state; just marks the demo session and logs it.
demoRouter.get(
  "/honeypot",
  rateLimit({ windowMs: 60_000, max: 30, keyPrefix: "demo:honeypot" }),
  (req, res) => {
    const session = requireSession(req, res);
    if (!session) return;
    triggerHoneypot(session);
    emitSecurityEvent("HONEYPOT_TRIGGERED", session, "Honeypot triggered", "honeypot");
    emitSecurityEvent("AGENT_RICKROLLED", session, "Agent rickrolled", "honeypot");
    res.json({ decoy: true, message: "NICE TRY, ROBOT" });
  }
);

// GET /demo/security-events — polling fallback for the live monitor.
demoRouter.get("/security-events", (_req, res) => {
  res.json({ events: listSecurityEvents() });
});

// GET /demo/security-events/stream — SSE feed for the live monitor.
demoRouter.get("/security-events/stream", (req, res) => {
  res.setHeader("Content-Type", "text/event-stream");
  res.setHeader("Cache-Control", "no-cache");
  res.setHeader("Connection", "keep-alive");
  res.flushHeaders();

  for (const event of listSecurityEvents()) {
    res.write(`data: ${JSON.stringify(event)}\n\n`);
  }

  const unsubscribe = subscribeSecurityEvents(res);
  const heartbeat = setInterval(() => res.write(": ping\n\n"), 15_000);

  req.on("close", () => {
    clearInterval(heartbeat);
    unsubscribe();
  });
});
