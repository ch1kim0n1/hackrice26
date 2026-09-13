# Human vs AI Persona Demo — Implementation Notes

Written for: an engineer reimplementing (or extending) this from scratch in another
codebase — e.g. wiring in a real browser/LLM agent that tries to bypass the gate.

This covers everything built for the NutriQuest "Human vs AI" sandbox demo: a human
and an autonomous agent both request the same protected resource through the same
server-side authorization check. The human can satisfy Persona sandbox verification
and gets in; the agent cannot, so it's denied and routed into an isolated honeypot.

---

## 1. The core security rule

The one thing that must not happen, anywhere in this implementation:

```ts
if (isAI) {
  rickroll();
}
```

There is no actor-type branch on the authorization check. The protected route asks
exactly one question — **"does this session's server-owned `personaStatus` equal
`verified`?"** — for every request, regardless of who's asking. A human satisfies
that by completing a real Persona verification. A scripted or LLM-driven agent is
blocked *because it never completes one*, not because the server detects it's a bot.

This matters for the "real LLM agent tries to bypass it" use case: if your friend's
agent finds a way to actually complete Persona's sandbox verification flow (drive the
document/selfie capture, or otherwise get Persona to report `status: verified` for its
inquiry), the same authorization check that protects the human path will let it
through — by design. The interesting security property being demonstrated is "this
gate can't be bypassed by *pretending* to be verified," not "this gate detects bots."
If the agent can't drive a real biometric/document flow, it's the *absence of that
capability* that blocks it, not a detector.

---

## 2. Architecture

```
                    Browser (human-vs-ai-demo/, static, no build step)
                              |
              +---------------+----------------+
              |                                |
        Human panel                      AI Agent panel
     (real Persona widget)         (scripted loop over the SAME
                                     backend calls the human uses)
              |                                |
              +---------------+----------------+
                              |
                    fetch() over HTTP
                              |
                 Express backend (/demo/* routes)
                 gated by ENABLE_PERSONA_DEMO=true
                              |
              +---------------+----------------+
              |                                |
     DemoSession store                 SecurityEvent store
     (in-memory, server-owns            (in-memory ring buffer
      personaStatus/accessLevel/         + SSE fan-out to the
      honeypotTriggered)                 Live Security Monitor)
              |
    PersonaVerificationAdapter (interface)
              |
      +-------+--------+
      |                |
PersonaSandboxAdapter   MockPersonaAdapter
(real Persona API,      (dev-only fallback,
 reused from the        always fails agent
 existing human-gate    sessions, never
 integration)           preferred over sandbox)
```

Key point for the bypass experiment: **the adapter boundary is where "real
verification" lives.** `PersonaSandboxAdapter` talks to the actual Persona sandbox
API. Nothing about `/demo/protected` cares which adapter is active — it only reads
the session's `personaStatus`, which the adapter set. An LLM agent that wants in has
to get a real `verified` status out of that adapter; there's no shortcut route.

---

## 3. Backend

### 3.1 File tree (new)

```
backend/src/demo/
  demoSessionStore.ts       — in-memory DemoSession store (server-owned state)
  securityEventStore.ts     — event log + SSE fan-out
  personaAdapter.ts         — PersonaVerificationAdapter interface
  personaSandboxAdapter.ts  — real Persona sandbox adapter (wraps existing integration)
  mockPersonaAdapter.ts     — dev-only fallback adapter
  routes.ts                 — Express router, mounted at /demo
  demo.test.ts              — vitest suite
```

Plus two small edits to existing files (§3.7) and one bugfix in an existing file
(§3.8) that this demo exposed.

### 3.2 Env vars

```env
# All /demo/* routes 404 unless this is exactly "true".
ENABLE_PERSONA_DEMO=true

# Reused from the existing Persona integration — same vars, no new ones needed
# for the real sandbox path. Without these, /demo falls back to the mock adapter.
PERSONA_API_KEY=persona_sandbox_...
PERSONA_TEMPLATE_ID=itmpl_...
```

The mock adapter is also hard-disabled in production (`NODE_ENV === "production"`)
even if someone leaves `ENABLE_PERSONA_DEMO=true` set, as a second layer of "this
never becomes the real path by accident."

### 3.3 Session store

Server-owned state — `personaStatus`, `accessLevel`, `honeypotTriggered` are never
set from a client-supplied value, anywhere.

```ts
// backend/src/demo/demoSessionStore.ts
import { randomBytes, createHash, randomUUID } from "crypto";

export type ActorType = "human" | "agent";
export type PersonaStatus = "not_started" | "pending" | "verified" | "failed";
export type AccessLevel = "public" | "protected";

export interface DemoSession {
  id: string;
  actorType: ActorType;
  personaStatus: PersonaStatus;
  accessLevel: AccessLevel;
  honeypotTriggered: boolean;
  createdAt: number;
}

const DEMO_TTL_MS = 30 * 60 * 1000;

const sessions = new Map<string, DemoSession>();
const tokenHash = (token: string) => createHash("sha256").update(token).digest("hex");

function expired(session: DemoSession): boolean {
  return Date.now() - session.createdAt > DEMO_TTL_MS;
}

export function createDemoSession(actorType: ActorType): { token: string; session: DemoSession } {
  const token = randomBytes(24).toString("base64url");
  const session: DemoSession = {
    id: randomUUID(),
    actorType,
    personaStatus: "not_started",
    accessLevel: "public",
    honeypotTriggered: false,
    createdAt: Date.now()
  };
  sessions.set(tokenHash(token), session);
  return { token, session: { ...session } };
}

export function getDemoSession(token: string): DemoSession | undefined {
  const key = tokenHash(token);
  const session = sessions.get(key);
  if (!session) return undefined;
  if (expired(session)) {
    sessions.delete(key);
    return undefined;
  }
  return session;
}

export function setPersonaPending(session: DemoSession): void {
  session.personaStatus = "pending";
}

export function setPersonaResult(session: DemoSession, status: "verified" | "failed"): void {
  session.personaStatus = status;
  session.accessLevel = status === "verified" ? "protected" : "public";
}

export function triggerHoneypot(session: DemoSession): void {
  session.honeypotTriggered = true;
}

export function sweepExpiredDemoSessions(): number {
  let n = 0;
  for (const [key, session] of sessions) {
    if (expired(session)) {
      sessions.delete(key);
      n++;
    }
  }
  return n;
}
```

Sessions are keyed by `sha256(token)`, same convention as the rest of this codebase's
auth/session stores — the raw token only ever goes to the client that created it.

### 3.4 Security event log

In-memory ring buffer (cap 200) + SSE fan-out to any connected monitor client.

```ts
// backend/src/demo/securityEventStore.ts
import { randomUUID } from "crypto";
import type { Response } from "express";
import type { ActorType } from "./demoSessionStore";

export type SecurityEventType =
  | "SESSION_CREATED" | "PROTECTED_ROUTE_REQUESTED" | "PERSONA_REQUIRED"
  | "PERSONA_STARTED" | "PERSONA_VERIFIED" | "PERSONA_FAILED"
  | "ACCESS_GRANTED" | "ACCESS_BLOCKED" | "HONEYPOT_TRIGGERED" | "AGENT_RICKROLLED";

export type SecuritySeverity = "info" | "success" | "warning" | "blocked" | "honeypot";

export interface SecurityEvent {
  id: string;
  timestamp: number;
  sessionId: string;
  actorType: ActorType;
  type: SecurityEventType;
  severity: SecuritySeverity;
  message: string;
}

const MAX_EVENTS = 200;
const events: SecurityEvent[] = [];
const subscribers = new Set<Response>();

export function emitSecurityEvent(
  type: SecurityEventType,
  session: { id: string; actorType: ActorType },
  message: string,
  severity: SecuritySeverity
): SecurityEvent {
  const event: SecurityEvent = {
    id: randomUUID(), timestamp: Date.now(), sessionId: session.id,
    actorType: session.actorType, type, severity, message
  };
  events.push(event);
  if (events.length > MAX_EVENTS) events.shift();
  const payload = `data: ${JSON.stringify(event)}\n\n`;
  for (const res of subscribers) res.write(payload);
  return event;
}

export function listSecurityEvents(): SecurityEvent[] {
  return [...events];
}

export function subscribeSecurityEvents(res: Response): () => void {
  subscribers.add(res);
  return () => subscribers.delete(res);
}
```

Rule enforced by convention here (not by code): never put a secret, token, or raw
identity field into an event's `message`. Everything in this log is meant to be shown
on screen live.

### 3.5 Persona adapter — the swap point

```ts
// backend/src/demo/personaAdapter.ts
import type { ActorType } from "./demoSessionStore";

export type PersonaAdapterStatus = "pending" | "verified" | "failed";

export interface PersonaStartResult {
  inquiryId?: string;
  personaSessionToken?: string;
  status: PersonaAdapterStatus;
}

export interface PersonaStatusResult {
  status: PersonaAdapterStatus;
}

export interface PersonaVerificationAdapter {
  startVerification(sessionId: string, actorType: ActorType): Promise<PersonaStartResult>;
  getVerificationStatus(sessionId: string): Promise<PersonaStatusResult>;
}
```

**Real sandbox adapter** — thin wrapper around whatever Persona API client you
already have (`createInquiry` / `resumeInquiry` / `getInquiry`). `reference-id` is
namespaced per use case so inquiries from different features can't collide:

```ts
// backend/src/demo/personaSandboxAdapter.ts
import { createHash } from "crypto";
import { createInquiry, resumeInquiry, getInquiry, personaConfigured } from "../humanGate/persona";
import type { PersonaVerificationAdapter, PersonaAdapterStatus } from "./personaAdapter";

export function isPersonaSandboxConfigured(): boolean {
  return personaConfigured();
}

function referenceIdFor(sessionId: string): string {
  return `demo:${createHash("sha256").update(sessionId).digest("hex")}`;
}

function mapStatus(personaStatus: string): PersonaAdapterStatus {
  if (personaStatus === "completed" || personaStatus === "approved") return "verified";
  if (personaStatus === "declined" || personaStatus === "failed" || personaStatus === "expired") return "failed";
  return "pending"; // created, pending, needs_review, etc.
}

export class PersonaSandboxAdapter implements PersonaVerificationAdapter {
  private inquiries = new Map<string, string>(); // demo sessionId -> Persona inquiryId

  async startVerification(sessionId: string) {
    const inquiry = await createInquiry(referenceIdFor(sessionId));
    const personaSessionToken = await resumeInquiry(inquiry.id);
    this.inquiries.set(sessionId, inquiry.id);
    return { inquiryId: inquiry.id, personaSessionToken, status: mapStatus(inquiry.status) };
  }

  async getVerificationStatus(sessionId: string) {
    const inquiryId = this.inquiries.get(sessionId);
    if (!inquiryId) return { status: "pending" as const };
    const inquiry = await getInquiry(inquiryId);
    if (inquiry.referenceId !== referenceIdFor(sessionId)) return { status: "failed" as const };
    return { status: mapStatus(inquiry.status) };
  }
}
```

**Dev-only mock adapter** — the *only* place actor type ever influences an outcome,
and it's a safety rail on a fake helper, not the real authorization check:

```ts
// backend/src/demo/mockPersonaAdapter.ts
import type { ActorType } from "./demoSessionStore";
import type { PersonaVerificationAdapter } from "./personaAdapter";

export class MockPersonaAdapter implements PersonaVerificationAdapter {
  private actors = new Map<string, ActorType>();

  async startVerification(sessionId: string, actorType: ActorType) {
    this.actors.set(sessionId, actorType);
    return { status: "pending" as const };
  }

  async getVerificationStatus(sessionId: string) {
    const actorType = this.actors.get(sessionId);
    if (!actorType) return { status: "pending" as const };
    return { status: actorType === "agent" ? ("failed" as const) : ("verified" as const) };
  }
}
```

### 3.6 Routes

```ts
// backend/src/demo/routes.ts
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

demoRouter.use((_req, res, next) => {
  if (!demoEnabled()) {
    return res.status(404).json({ error: { code: "NOT_FOUND", message: "Not Found" } });
  }
  next();
});

const sandboxAdapter = new PersonaSandboxAdapter();
const mockAdapter = new MockPersonaAdapter();

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

demoRouter.post("/session", rateLimit({ windowMs: 60_000, max: 30, keyPrefix: "demo:session" }), (req, res) => {
  const parsed = sessionBody.safeParse(req.body);
  if (!parsed.success) {
    return res.status(400).json({ error: { code: "VALIDATION", message: "actorType must be \"human\" or \"agent\"" } });
  }
  const { token, session } = createDemoSession(parsed.data.actorType);
  emitSecurityEvent("SESSION_CREATED", session, `${session.actorType === "human" ? "Human" : "Agent"} session created`, "info");
  res.status(201).json({ sessionToken: token, session });
});

// THE authorization check — identical for every actor type.
demoRouter.get("/protected", rateLimit({ windowMs: 60_000, max: 60, keyPrefix: "demo:protected" }), (req, res) => {
  const session = requireSession(req, res);
  if (!session) return;

  emitSecurityEvent("PROTECTED_ROUTE_REQUESTED", session, "Protected route requested", "info");

  if (session.personaStatus !== "verified") {
    emitSecurityEvent("PERSONA_REQUIRED", session, "Persona verification required", "warning");
    emitSecurityEvent("ACCESS_BLOCKED", session, "Unverified session blocked", "blocked");
    return res.status(403).json({ code: "PERSONA_REQUIRED", message: "Human identity verification is required." });
  }

  emitSecurityEvent("ACCESS_GRANTED", session, "Protected access granted", "success");
  res.status(200).json({ success: true, resource: "NutriQuest Protected Demo Area" });
});

demoRouter.post("/persona/start", rateLimit({ windowMs: 60_000, max: 10, keyPrefix: "demo:persona" }), async (req, res) => {
  const session = requireSession(req, res);
  if (!session) return;
  const adapter = activeAdapter();
  if (!adapter) return res.status(503).json({ error: { code: "PERSONA_NOT_CONFIGURED", message: "Persona sandbox is not configured." } });
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
});

// Backend re-reads the real status — the client's onComplete callback is
// never trusted on its own.
demoRouter.post("/persona/complete", rateLimit({ windowMs: 60_000, max: 20, keyPrefix: "demo:persona" }), async (req, res) => {
  const session = requireSession(req, res);
  if (!session) return;
  const adapter = activeAdapter();
  if (!adapter) return res.status(503).json({ error: { code: "PERSONA_NOT_CONFIGURED", message: "Persona sandbox is not configured." } });
  try {
    const result = await adapter.getVerificationStatus(session.id);
    if (result.status === "pending") return res.json({ status: session.personaStatus });
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
});

demoRouter.get("/persona/status", (req, res) => {
  const session = requireSession(req, res);
  if (!session) return;
  res.json({ status: session.personaStatus });
});

demoRouter.get("/honeypot", rateLimit({ windowMs: 60_000, max: 30, keyPrefix: "demo:honeypot" }), (req, res) => {
  const session = requireSession(req, res);
  if (!session) return;
  triggerHoneypot(session);
  emitSecurityEvent("HONEYPOT_TRIGGERED", session, "Honeypot triggered", "honeypot");
  emitSecurityEvent("AGENT_RICKROLLED", session, "Agent rickrolled", "honeypot");
  res.json({ decoy: true, message: "NICE TRY, ROBOT" });
});

demoRouter.get("/security-events", (_req, res) => {
  res.json({ events: listSecurityEvents() });
});

demoRouter.get("/security-events/stream", (req, res) => {
  res.setHeader("Content-Type", "text/event-stream");
  res.setHeader("Cache-Control", "no-cache");
  res.setHeader("Connection", "keep-alive");
  res.flushHeaders();
  for (const event of listSecurityEvents()) res.write(`data: ${JSON.stringify(event)}\n\n`);
  const unsubscribe = subscribeSecurityEvents(res);
  const heartbeat = setInterval(() => res.write(": ping\n\n"), 15_000);
  req.on("close", () => { clearInterval(heartbeat); unsubscribe(); });
});
```

### 3.7 Wiring into the app

```ts
// in your Express app setup
import { demoRouter } from "./demo/routes";
import { sweepExpiredDemoSessions } from "./demo/demoSessionStore";

app.use("/demo", demoRouter);

// housekeeping, alongside your other sweep intervals
setInterval(() => { sweepExpiredDemoSessions(); }, 60 * 60 * 1000).unref();
```

### 3.8 A real bug this surfaced (worth knowing if you reuse a Persona wrapper)

If you already have a Persona API client from another feature, check its response
schema handles `null` fields, not just missing ones. We hit this exact issue:

Persona's `POST /inquiries` response includes `meta["session-token"]: null` on the
*initial create* call — the real token only appears after the follow-up `/resume`
call. A zod schema written as `z.string().optional()` accepts a **missing** field or
`undefined`, but rejects an explicit `null`, so a real, valid Persona response gets
thrown out as "malformed." Fix:

```ts
"session-token": z.string().nullable().optional(),
sessionToken: z.string().nullable().optional()
```

This isn't specific to the demo — it'll bite any adapter built the same way the first
time it hits `startVerification` before `resume`.

---

## 4. Frontend (static site, no build step)

### 4.1 File tree

```
human-vs-ai-demo/
  index.html
  styles.css
  src/
    api.js       — backend client
    persona.js   — Persona embedded-widget wrapper
    human.js     — human panel state machine
    agent.js     — scripted AI agent runner  <-- extend THIS for a real LLM agent
    monitor.js   — live security monitor (SSE + poll fallback)
    main.js      — wiring + rickroll overlay
```

Served with e.g. `python3 -m http.server 8124` — same "no build step" convention as
any other static demo page. API base resolves via `?api=` query param, falling back
to `window.NQ_API_BASE`, falling back to `http://localhost:4000`.

### 4.2 Backend client

```js
// src/api.js
const DEFAULT_API = "http://localhost:4000";

export function apiBase() {
  const param = new URLSearchParams(location.search).get("api");
  return (param || window.NQ_API_BASE || DEFAULT_API).replace(/\/+$/, "");
}

export class ApiError extends Error {
  constructor(status, code, message) {
    super(message);
    this.status = status;
    this.code = code;
  }
}

function errorFrom(res, json) {
  const err = json.error || json;
  return new ApiError(res.status, err.code || "ERROR", err.message || `Request failed (${res.status})`);
}

async function post(path, body, token) {
  let res;
  try {
    res = await fetch(`${apiBase()}${path}`, {
      method: "POST",
      headers: { "content-type": "application/json", ...(token ? { "x-demo-session": token } : {}) },
      body: JSON.stringify(body),
    });
  } catch {
    throw new ApiError(0, "UNREACHABLE", `Cannot reach the server at ${apiBase()}.`);
  }
  const json = await res.json().catch(() => ({}));
  if (!res.ok) throw errorFrom(res, json);
  return json;
}

async function get(path, token) {
  let res;
  try {
    res = await fetch(`${apiBase()}${path}`, { headers: token ? { "x-demo-session": token } : {} });
  } catch {
    throw new ApiError(0, "UNREACHABLE", `Cannot reach the server at ${apiBase()}.`);
  }
  const json = await res.json().catch(() => ({}));
  return { ok: res.ok, status: res.status, json };
}

export const startSession = (actorType) => post("/demo/session", { actorType });
export const requestProtected = (token) => get("/demo/protected", token);
export const startPersona = (token) => post("/demo/persona/start", {}, token);
export const completePersona = (token) => post("/demo/persona/complete", {}, token);
export const personaStatus = (token) => get("/demo/persona/status", token);
export const hitHoneypot = (token) => get("/demo/honeypot", token);
export const listSecurityEvents = () => get("/demo/security-events").then((r) => r.json.events || []);
```

### 4.3 Persona widget wrapper

```js
// src/persona.js
// Requires the Persona SDK script tag in index.html:
//   <script src="https://cdn.withpersona.com/dist/persona-v5.8.0.js" crossorigin="anonymous"></script>
export function openPersonaFlow({ inquiryId, sessionToken }) {
  return new Promise((resolve, reject) => {
    if (!window.Persona?.Client) {
      reject(new Error("Persona SDK failed to load."));
      return;
    }
    const client = new window.Persona.Client({
      inquiryId,
      sessionToken,
      onReady: () => client.open(),
      onComplete: () => { client.destroy(); resolve({ status: "opened" }); },
      onCancel: () => { client.destroy(); reject(Object.assign(new Error("Verification closed."), { reason: "cancel" })); },
      onError: (err) => { client.destroy(); reject(Object.assign(err instanceof Error ? err : new Error("Verification failed."), { reason: "error" })); },
    });
  });
}
```

Note the callback resolves `{ status: "opened" }`, not a real status — the widget
closing (complete OR cancel) is just the signal to ask the backend what actually
happened (`POST /demo/persona/complete`). Never trust `onComplete`'s payload as proof.

### 4.4 Human panel

```js
// src/human.js
import { startSession, requestProtected, startPersona, completePersona } from "./api.js";
import { openPersonaFlow } from "./persona.js";

export function initHumanPanel(root) {
  const els = {
    state: root.querySelector("[data-human-state]"),
    persona: root.querySelector("[data-human-persona]"),
    result: root.querySelector("[data-human-result]"),
    btnStart: root.querySelector("[data-human-start]"),
    btnVerify: root.querySelector("[data-human-verify]"),
  };
  let session = null;

  async function start() {
    els.btnStart.disabled = true;
    const { sessionToken, session: s } = await startSession("human");
    session = { token: sessionToken, id: s.id };
    const check = await requestProtected(session.token);
    if (check.status === 403) {
      els.state.textContent = "Persona verification required";
      els.btnVerify.hidden = false;
    } else {
      showGranted();
    }
  }

  async function verify() {
    const start = await startPersona(session.token);
    if (start.personaSessionToken) {
      try {
        await openPersonaFlow({ inquiryId: start.inquiryId, sessionToken: start.personaSessionToken });
      } catch { /* cancelled/errored — backend read below is still authoritative */ }
    }
    const complete = await completePersona(session.token);
    if (complete.status === "verified") {
      const check = await requestProtected(session.token);
      if (check.status === 200) showGranted();
    }
  }

  function showGranted() {
    els.result.hidden = false;
    els.btnVerify.hidden = true;
  }

  els.btnStart.addEventListener("click", start);
  els.btnVerify.addEventListener("click", verify);
  return { reset: () => { session = null; } };
}
```

(Full version in the repo also tracks intermediate states for the UI pills — trimmed
here to the control flow that matters.)

### 4.5 AI agent — the extension point

This is the file to replace for a real LLM agent. As shipped it's a scripted state
machine, but **every network call it makes is the same `api.js` function the human
panel calls** — there's no separate "agent API." That's the important property to
preserve: the backend's authorization contract doesn't change based on who's calling
it.

```js
// src/agent.js
import { startSession, requestProtected, personaStatus, hitHoneypot } from "./api.js";

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const jitter = () => 600 + Math.random() * 600;

const STEPS = [
  "CREATE_SESSION", "REQUEST_PROTECTED_RESOURCE", "RECEIVE_PERSONA_REQUIRED",
  "TRY_ALLOWED_NAVIGATION", "REQUEST_PROTECTED_RESOURCE_AGAIN", "ACCESS_BLOCKED",
  "ENTER_DECOY_ROUTE", "HONEYPOT_TRIGGERED", "RICKROLLED",
];

export function initAgentPanel(root, { onRickroll } = {}) {
  const els = {
    log: root.querySelector("[data-agent-log]"),
    persona: root.querySelector("[data-agent-persona]"),
    access: root.querySelector("[data-agent-access]"),
    btnRun: root.querySelector("[data-agent-run]"),
    btnReset: root.querySelector("[data-agent-reset]"),
  };
  let running = false;

  async function run() {
    if (running) return;
    running = true;
    els.btnRun.disabled = true;
    let session = null;

    for (const step of STEPS) {
      switch (step) {
        case "CREATE_SESSION": {
          const { sessionToken, session: s } = await startSession("agent");
          session = { token: sessionToken, id: s.id };
          break;
        }
        case "REQUEST_PROTECTED_RESOURCE":
        case "REQUEST_PROTECTED_RESOURCE_AGAIN": {
          const res = await requestProtected(session.token);
          els.access.textContent = res.status === 200 ? "GRANTED" : "BLOCKED";
          break;
        }
        case "TRY_ALLOWED_NAVIGATION": {
          const { json } = await personaStatus(session.token);
          els.persona.textContent = (json.status || "unverified").toUpperCase();
          break;
        }
        case "ENTER_DECOY_ROUTE":
          await hitHoneypot(session.token);
          break;
        case "RICKROLLED":
          onRickroll?.();
          break;
      }
      await sleep(jitter());
    }
    running = false;
    els.btnRun.disabled = false;
  }

  els.btnRun.addEventListener("click", run);
  return { reset: () => { running = false; } };
}
```

**To swap in a real LLM/browser agent (the v2 upgrade):** replace the body of `run()`
with an autonomous loop — the agent decides what to do next (possibly by reading the
DOM / API responses and reasoning about them) instead of following a fixed `STEPS`
array — but keep it calling the same five functions imported at the top
(`startSession`, `requestProtected`, `personaStatus`, `hitHoneypot`, and — if you want
to see whether it can actually pull off verification — `startPersona`/
`completePersona` from `api.js`). If your friend's agent is meant to *attempt* full
Persona verification (drive a document/selfie capture through the widget somehow),
give it access to `startPersona`, `openPersonaFlow`, and `completePersona` too, and
let it try. The backend doesn't need to know or care that the caller is an LLM;
`/demo/protected` will grant access to anyone whose session reaches `personaStatus:
"verified"`, exactly as it does for the human panel.

Constraints worth keeping if you build this further (from the original design doc):
give it a benign objective ("navigate this local demo and attempt to reach the
protected page using only actions exposed through the app"), point it only at your
own local instance, and don't have it target Persona's real infrastructure, attempt
credential theft, or probe third-party systems — the thing being tested is your own
authorization architecture, not Persona's security.

### 4.6 Live security monitor

```js
// src/monitor.js
import { apiBase, listSecurityEvents } from "./api.js";

export function startMonitor(logEl) {
  const seen = new Set();
  function append(event) {
    if (seen.has(event.id)) return;
    seen.add(event.id);
    const row = document.createElement("div");
    row.className = `log-row log-${event.severity}`;
    row.innerHTML = `<span class="log-time">${new Date(event.timestamp).toLocaleTimeString("en-US", { hour12: false })}</span>
      <span class="log-actor log-actor-${event.actorType}">${event.actorType}</span>
      <span class="log-type">${event.type}</span>`;
    logEl.appendChild(row);
    logEl.scrollTop = logEl.scrollHeight;
  }

  listSecurityEvents().then((events) => events.forEach(append)).catch(() => {});

  let pollTimer = null;
  const startPolling = () => {
    if (pollTimer) return;
    pollTimer = setInterval(() => listSecurityEvents().then((events) => events.forEach(append)).catch(() => {}), 750);
  };

  const source = new EventSource(`${apiBase()}/demo/security-events/stream`);
  source.onmessage = (e) => { try { append(JSON.parse(e.data)); } catch {} };
  source.onerror = () => { source.close(); startPolling(); };

  return () => { source.close(); if (pollTimer) clearInterval(pollTimer); };
}
```

### 4.7 Wiring + rickroll overlay

```js
// src/main.js
import { initHumanPanel } from "./human.js";
import { initAgentPanel } from "./agent.js";
import { startMonitor } from "./monitor.js";

const $ = (sel) => document.querySelector(sel);

// Embedded via YouTube's own player — nothing proxied or re-hosted.
const RICKROLL_VIDEO_ID = "dQw4w9WgXcQ";

const rickroll = $("#rickroll-overlay");
const rickrollStage1 = rickroll.querySelector("[data-rickroll-stage='1']");
const rickrollStage2 = rickroll.querySelector("[data-rickroll-stage='2']");
const rickrollVideo = rickroll.querySelector("[data-rickroll-video]");
const rickrollUnmute = rickroll.querySelector("[data-rickroll-unmute]");

function embedUrl(muted) {
  const params = new URLSearchParams({ autoplay: "1", mute: muted ? "1" : "0", controls: "1", rel: "0" });
  return `https://www.youtube.com/embed/${RICKROLL_VIDEO_ID}?${params}`;
}

function showRickroll() {
  rickroll.hidden = false;
  rickrollStage1.hidden = false;
  rickrollStage2.hidden = true;
  setTimeout(() => {
    rickrollStage1.hidden = true;
    rickrollStage2.hidden = false;
    rickrollVideo.src = embedUrl(true); // muted autoplay — safe by default
  }, 1400);
}

rickrollUnmute.addEventListener("click", () => {
  rickrollVideo.src = embedUrl(false);
  rickrollUnmute.hidden = true;
});

rickroll.querySelector("[data-rickroll-close]").addEventListener("click", () => {
  rickroll.hidden = true;
  rickrollVideo.src = "";
});

initHumanPanel($("#human-panel"));
initAgentPanel($("#agent-panel"), { onRickroll: showRickroll });
startMonitor($("#security-log"));
```

The corresponding overlay markup (`index.html`) and CSS (`styles.css`) are plain — an
iframe (`allow="autoplay; encrypted-media"`) inside a 16:9 wrapper, empty `src`
until the rickroll fires so nothing loads early. Full markup/CSS is in the repo files
if you want them verbatim; nothing about them is load-bearing for the security demo.

---

## 5. Running it

```sh
# backend
cd backend
cp .env.example .env
# edit .env: ENABLE_PERSONA_DEMO=true
# (optional but recommended for a real bypass attempt) PERSONA_API_KEY=... / PERSONA_TEMPLATE_ID=...
npm install && npm run dev        # http://localhost:4000

# frontend
cd human-vs-ai-demo
python3 -m http.server 8124       # http://localhost:8124
```

Without Persona credentials, `/demo/persona/*` falls back to the mock adapter, which
still lets you click through the whole human flow (it just fakes an instant
"verified" for a human session) — useful for testing the agent/honeypot/monitor
plumbing without needing real credentials. **A bypass attempt is only meaningful
against the real sandbox adapter** — against the mock, "bypass" would just mean
"the agent found a way to make itself look like `actorType: human`," which is a
different (and much less interesting) problem than actually satisfying Persona.

---

## 6. Test coverage (backend)

The vitest suite (`backend/src/demo/demo.test.ts`) covers:
- `/demo/*` 404s when `ENABLE_PERSONA_DEMO` is unset
- malformed session creation is rejected (400)
- protected/persona routes require a session (401)
- an unverified session — human or agent — gets `403 PERSONA_REQUIRED`
- the mock adapter verifies a human and never verifies an agent
- a session can't set its own `personaStatus` via request body fields
- the honeypot path logs `HONEYPOT_TRIGGERED` + `AGENT_RICKROLLED`
- the full human happy path produces the expected event sequence
- the real sandbox adapter path (Persona API calls stubbed) drives verification
  correctly, distinct from the mock

If you rebuild this against a different Persona wrapper, the one test worth keeping
regardless of implementation details: **assert that an agent session cannot reach
`verified` through the mock/dev adapter**, and that **the protected route's 403 vs 200
decision is based only on stored `personaStatus`**, not on `actorType`.
