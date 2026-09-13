import type { Migration } from "../migrate";

/**
 * Persona verification outcome on human-gate sessions.
 *
 * After the reflex game posts its verdict, the web app opens Persona's
 * embedded flow against a server-created inquiry bound to the gate session
 * (reference-id = token_hash). When the widget reports back, the inquiry's
 * server-verified status lands here so registration carries both the cheap
 * pre-gate signal and the real verification result.
 *
 * persona_status is whatever Persona reports (approved/completed/declined/
 * pending...) — recorded verbatim for review, never enforced: the gate
 * stays non-punitive.
 */
export const migration: Migration = {
  version: 11,
  name: "human_gate_persona",
  sql: `
    ALTER TABLE human_gate_session ADD COLUMN persona_inquiry_id TEXT;
    ALTER TABLE human_gate_session ADD COLUMN persona_status TEXT;
  `
};
