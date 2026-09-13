// Persona API client (server-side only).
//
// Thin wrapper over https://api.withpersona.com/api/v1 used by the
// human-gate flow: the backend creates an inquiry bound to a gate session
// (reference-id = sha256(gateToken)), hands the web app an inquiry id +
// session token, and later reads the inquiry back to record the verified
// status — the client-reported status is never trusted.
//
// Config (env, never client-side):
//   PERSONA_API_KEY      persona_sandbox_* / persona_production_* key
//   PERSONA_TEMPLATE_ID  itmpl_* inquiry template — required: sandbox keys
//                        cannot list templates via the API, so there is no
//                        way to auto-discover it
//   PERSONA_API_URL      default https://api.withpersona.com

import { z } from "zod";

const API_VERSION = "2023-01-05";

const apiUrl = () =>
  (process.env.PERSONA_API_URL || "https://api.withpersona.com").replace(/\/+$/, "");

/** True when the Persona leg of the gate is wired up. */
export function personaConfigured(): boolean {
  return Boolean(process.env.PERSONA_API_KEY && process.env.PERSONA_TEMPLATE_ID);
}

export class PersonaError extends Error {
  constructor(
    message: string,
    public readonly status: number
  ) {
    super(message);
    this.name = "PersonaError";
  }
}

const inquirySchema = z.object({
  data: z.object({
    id: z.string(),
    attributes: z.object({
      status: z.string(),
      "reference-id": z.string().nullable().optional(),
      referenceId: z.string().nullable().optional()
    }).passthrough()
  }),
  meta: z
    .object({
      // Persona sends null (not just omitted) on the initial create call —
      // the real token only shows up after /resume.
      "session-token": z.string().nullable().optional(),
      sessionToken: z.string().nullable().optional()
    })
    .passthrough()
    .optional()
});

export interface PersonaInquiry {
  id: string;
  status: string;
  referenceId: string | null;
}

export interface PersonaSession {
  inquiryId: string;
  sessionToken: string;
}

async function request(path: string, init: RequestInit = {}): Promise<unknown> {
  const key = process.env.PERSONA_API_KEY;
  if (!key) throw new PersonaError("PERSONA_API_KEY is not configured", 503);
  let res: Response;
  try {
    res = await fetch(`${apiUrl()}${path}`, {
      ...init,
      headers: {
        accept: "application/json",
        "content-type": "application/json",
        authorization: `Bearer ${key}`,
        "Persona-Version": API_VERSION,
        ...(init.headers ?? {})
      }
    });
  } catch {
    throw new PersonaError("Persona API unreachable", 502);
  }
  const body = await res.json().catch(() => ({}));
  if (!res.ok) {
    const detail = (body as { errors?: { title?: string }[] }).errors
      ?.map((e) => e.title)
      .join("; ");
    throw new PersonaError(detail || `Persona API error (${res.status})`, res.status);
  }
  return body;
}

function parseInquiry(body: unknown): PersonaInquiry {
  const parsed = inquirySchema.safeParse(body);
  if (!parsed.success) {
    throw new PersonaError("Malformed Persona response", 502);
  }
  const attrs = parsed.data.data.attributes;
  return {
    id: parsed.data.data.id,
    status: attrs.status,
    referenceId: attrs["reference-id"] ?? attrs.referenceId ?? null
  };
}

/** Create an inquiry for a template, tagged with our reference-id. */
export async function createInquiry(referenceId: string): Promise<PersonaInquiry> {
  const templateId = process.env.PERSONA_TEMPLATE_ID;
  if (!templateId) throw new PersonaError("PERSONA_TEMPLATE_ID is not configured", 503);
  const body = await request("/api/v1/inquiries", {
    method: "POST",
    body: JSON.stringify({
      data: {
        attributes: {
          "inquiry-template-id": templateId,
          "reference-id": referenceId
        }
      }
    })
  });
  return parseInquiry(body);
}

/**
 * Resume an inquiry to mint a session token — the embedded client needs
 * `inquiryId` + `sessionToken` to open the flow for a pending inquiry.
 */
export async function resumeInquiry(inquiryId: string): Promise<string> {
  const body = await request(`/api/v1/inquiries/${encodeURIComponent(inquiryId)}/resume`, {
    method: "POST"
  });
  const parsed = inquirySchema.safeParse(body);
  const token =
    parsed.success && (parsed.data.meta?.["session-token"] ?? parsed.data.meta?.sessionToken);
  if (!token) throw new PersonaError("Persona did not return a session token", 502);
  return token;
}

/** Read an inquiry's current status server-side. */
export async function getInquiry(inquiryId: string): Promise<PersonaInquiry> {
  return parseInquiry(await request(`/api/v1/inquiries/${encodeURIComponent(inquiryId)}`));
}
