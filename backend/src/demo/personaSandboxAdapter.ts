// Persona sandbox-backed adapter for the Human-vs-AI demo.
//
// Reuses the exact Persona integration already wired for human-gate signup
// (backend/src/humanGate/persona.ts) rather than re-implementing API calls.
// reference-id is namespaced ("demo:...") so demo inquiries can never be
// confused with a real signup's human-gate inquiry.

import { createHash } from "crypto";
import { createInquiry, resumeInquiry, getInquiry, personaConfigured } from "../humanGate/persona";
import type { PersonaVerificationAdapter, PersonaAdapterStatus } from "./personaAdapter";

export function isPersonaSandboxConfigured(): boolean {
  return personaConfigured();
}

function referenceIdFor(sessionId: string): string {
  return `demo:${createHash("sha256").update(sessionId).digest("hex")}`;
}

/** Map Persona's inquiry status vocabulary onto our tri-state. */
function mapStatus(personaStatus: string): PersonaAdapterStatus {
  if (personaStatus === "completed" || personaStatus === "approved") return "verified";
  if (personaStatus === "declined" || personaStatus === "failed" || personaStatus === "expired") return "failed";
  return "pending"; // created, pending, needs_review, etc.
}

export class PersonaSandboxAdapter implements PersonaVerificationAdapter {
  // Demo sessionId -> Persona inquiryId. In-memory only, matches the rest of
  // the demo's sandbox-only, non-persistent state.
  private inquiries = new Map<string, string>();

  async startVerification(sessionId: string) {
    const inquiry = await createInquiry(referenceIdFor(sessionId));
    const personaSessionToken = await resumeInquiry(inquiry.id);
    this.inquiries.set(sessionId, inquiry.id);
    return {
      inquiryId: inquiry.id,
      personaSessionToken,
      status: mapStatus(inquiry.status)
    };
  }

  async getVerificationStatus(sessionId: string) {
    const inquiryId = this.inquiries.get(sessionId);
    if (!inquiryId) return { status: "pending" as const };
    const inquiry = await getInquiry(inquiryId);
    // Guard against a stale/forged inquiry id landing on the wrong session.
    if (inquiry.referenceId !== referenceIdFor(sessionId)) {
      return { status: "failed" as const };
    }
    return { status: mapStatus(inquiry.status) };
  }
}
