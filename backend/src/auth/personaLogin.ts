// Persona-backed login.
//
// The password proves which account; Persona proves a human is holding it.
// When Persona is configured, POST /auth/login issues no session. It returns
// a short-lived login challenge bound to a fresh Persona inquiry
// (reference-id = sha256(loginToken), the raw token never leaves our system),
// and a session exists only after the server reads that inquiry back from
// Persona as completed or approved.
//
// Challenges live in memory: they last minutes, a restart only costs an
// in-flight login a retry, and nothing about them needs to reach TigerData.
//
// The honeypot half records agents that go looking for a way around the
// check. It feeds the Human-vs-AI demo's live security monitor.

import { randomBytes, createHash, randomUUID } from "crypto";
import { emitSecurityEvent } from "../demo/securityEventStore";

const CHALLENGE_TTL_MS = 10 * 60 * 1000;

/** Where every honeypot sends its visitor. */
export const RICKROLL_URL = "https://www.youtube.com/watch?v=dQw4w9WgXcQ";

/** Persona inquiry statuses that count as a verified human. */
export const VERIFIED_PERSONA_STATUSES: ReadonlySet<string> = new Set(["completed", "approved"]);

interface LoginChallenge {
  playerId: string;
  inquiryId: string;
  expiresAt: number;
}

const challenges = new Map<string, LoginChallenge>();

const hash = (token: string) => createHash("sha256").update(token).digest("hex");

function sweep(now = Date.now()): void {
  for (const [key, challenge] of challenges) {
    if (challenge.expiresAt <= now) challenges.delete(key);
  }
}

/** A new opaque login token; its hash becomes the Persona reference-id. */
export function newLoginToken(): string {
  return randomBytes(32).toString("base64url");
}

export function loginTokenHash(token: string): string {
  return hash(token);
}

/** Bind a login token to the account and the inquiry opened for it. */
export function storeLoginChallenge(token: string, playerId: string, inquiryId: string): void {
  sweep();
  challenges.set(hash(token), { playerId, inquiryId, expiresAt: Date.now() + CHALLENGE_TTL_MS });
}

/** The live challenge for a token, without consuming it. */
export function peekLoginChallenge(token: string): LoginChallenge | null {
  const challenge = challenges.get(hash(token));
  if (!challenge) return null;
  if (challenge.expiresAt <= Date.now()) {
    challenges.delete(hash(token));
    return null;
  }
  return challenge;
}

/** Burn a challenge. Single use whether or not Persona verified the human. */
export function consumeLoginChallenge(token: string): void {
  challenges.delete(hash(token));
}

export type HoneypotTrap = "field" | "link" | "api" | "webdriver";

const TRAP_MESSAGE: Record<HoneypotTrap, string> = {
  field: "Login honeypot: hidden field filled",
  link: "Login honeypot: skip-verification link followed",
  api: "Login honeypot: bypass endpoint called",
  webdriver: "Login honeypot: automated browser submitted login"
};

/** Log a honeypot hit to the live security monitor. */
export function recordLoginHoneypot(trap: HoneypotTrap): void {
  const session = { id: `login-${randomUUID().slice(0, 8)}`, actorType: "agent" as const };
  emitSecurityEvent("HONEYPOT_TRIGGERED", session, TRAP_MESSAGE[trap], "honeypot");
  emitSecurityEvent("AGENT_RICKROLLED", session, "Agent rickrolled", "honeypot");
}

/** Test-only: forget every in-flight login challenge. */
export function resetLoginChallenges(): void {
  challenges.clear();
}
