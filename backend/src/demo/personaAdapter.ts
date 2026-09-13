// Persona verification adapter abstraction for the Human-vs-AI demo.
//
// The protected route only ever asks "what does the adapter say", never
// "is this actor human" — swapping PersonaSandboxAdapter for MockPersonaAdapter
// (or a future real-Persona-prod adapter) changes nothing about the
// authorization gate itself.

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
