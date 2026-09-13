// Human-vs-AI demo session store.
//
// Sandbox-only, in-memory (see docs — this demo is intentionally isolated
// from the real per-player SQLite/TigerData stores). The server owns
// personaStatus/accessLevel/honeypotTriggered; nothing here is ever set from
// a client-supplied value.
//
// Sessions are keyed by sha256(token) the same way human-gate tokens are —
// the raw token is only ever handed to the client that created it.

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

const DEMO_TTL_MS = 30 * 60 * 1000; // demo sessions are short-lived by design

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

/** Look up a session by its raw token. Returns the live (mutable) record. */
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

/** Housekeeping: drop expired demo sessions. */
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

/** Test-only: drop every session so suites don't leak state across files. */
export function resetDemoSessions(): void {
  sessions.clear();
}
