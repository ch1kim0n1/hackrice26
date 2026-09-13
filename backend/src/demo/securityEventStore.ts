// Live security event log for the Human-vs-AI demo.
//
// In-memory, capped ring buffer + SSE fan-out. Never put secrets, tokens, or
// raw identity data in a message here — this feed is meant to be shown on
// screen during the demo.

import { randomUUID } from "crypto";
import type { Response } from "express";
import type { ActorType } from "./demoSessionStore";

export type SecurityEventType =
  | "SESSION_CREATED"
  | "PROTECTED_ROUTE_REQUESTED"
  | "PERSONA_REQUIRED"
  | "PERSONA_STARTED"
  | "PERSONA_VERIFIED"
  | "PERSONA_FAILED"
  | "ACCESS_GRANTED"
  | "ACCESS_BLOCKED"
  | "HONEYPOT_TRIGGERED"
  | "AGENT_RICKROLLED";

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
    id: randomUUID(),
    timestamp: Date.now(),
    sessionId: session.id,
    actorType: session.actorType,
    type,
    severity,
    message
  };
  events.push(event);
  if (events.length > MAX_EVENTS) events.shift();

  const payload = `data: ${JSON.stringify(event)}\n\n`;
  for (const res of subscribers) {
    res.write(payload);
  }
  return event;
}

export function listSecurityEvents(): SecurityEvent[] {
  return [...events];
}

/** Register an SSE client; returns an unsubscribe function. */
export function subscribeSecurityEvents(res: Response): () => void {
  subscribers.add(res);
  return () => subscribers.delete(res);
}

/** Test-only: clear the log so suites don't leak events across files. */
export function resetSecurityEvents(): void {
  events.length = 0;
}
