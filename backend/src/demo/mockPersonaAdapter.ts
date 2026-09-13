// Temporary local-development fallback for the Human-vs-AI demo.
//
// Used ONLY when the Persona sandbox isn't configured (no PERSONA_API_KEY /
// PERSONA_TEMPLATE_ID) so the demo flow is still clickable before those are
// set up. It is never the preferred path — routes.ts always prefers
// PersonaSandboxAdapter when Persona is configured — and it is disabled
// entirely outside demo development (see routes.ts's NODE_ENV guard).
//
// It hard-codes the one rule the real Persona sandbox naturally enforces:
// an agent session, which never drives a real document/selfie flow, can
// never come out "verified". A human session resolves verified with no
// artificial delay — the point is to unblock local demo wiring, not to
// simulate Persona's UX.

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
