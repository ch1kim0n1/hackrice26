import { Router } from "express";
import { z } from "zod";
import {
  createGateSession,
  recordGateResult,
  attachPersonaInquiry,
  recordPersonaStatus,
  gateTokenHash
} from "./store";
import { personaConfigured, createInquiry, resumeInquiry, getInquiry, PersonaError } from "./persona";
import { rateLimit } from "../middleware/security";

export const humanGateRouter = Router();

// POST /human-gate/session — issue a single-use gate token (15 min TTL).
// Issued before the game starts so the result post has somewhere to land.
humanGateRouter.post(
  "/session",
  rateLimit({ windowMs: 60_000, max: 10, keyPrefix: "humangate:session" }),
  (_req, res) => {
    res.status(201).json(createGateSession());
  }
);

// POST /human-gate/result { gateToken, score, verdict, flags }
// The web app posts its computed score after the final round. One shot:
// a token accepts exactly one result.
humanGateRouter.post(
  "/result",
  rateLimit({ windowMs: 60_000, max: 20, keyPrefix: "humangate:result" }),
  (req, res) => {
    const { gateToken, score, verdict, flags } = req.body as Record<string, unknown>;
    if (typeof gateToken !== "string" || gateToken.length === 0) {
      return res.status(400).json({ error: { code: "VALIDATION", message: "gateToken is required" } });
    }
    const r = recordGateResult(gateToken, score, verdict, flags ?? []);
    if ("error" in r) {
      const status = r.error === "BAD_RESULT" ? 400 : r.error === "ALREADY_SCORED" ? 409 : 403;
      return res.status(status).json({ error: { code: r.error, message: "Gate result rejected." } });
    }
    res.json({ ok: true });
  }
);

const personaInquiryBody = z.object({ gateToken: z.string().min(1) });
const personaCompleteBody = z.object({
  gateToken: z.string().min(1),
  inquiryId: z.string().min(1)
});

const personaErrorStatus = (err: unknown) =>
  err instanceof PersonaError && err.status >= 400 && err.status < 600 ? err.status : 502;

// POST /human-gate/persona/inquiry { gateToken }
// Creates a Persona inquiry bound to a scored gate session and returns the
// inquiry id + session token the embedded widget needs. reference-id is the
// token's sha256 — the raw gate token never leaves our system.
// 503 PERSONA_NOT_CONFIGURED when PERSONA_API_KEY/PERSONA_TEMPLATE_ID are
// unset: the client skips the Persona leg entirely in that case.
humanGateRouter.post(
  "/persona/inquiry",
  rateLimit({ windowMs: 60_000, max: 10, keyPrefix: "humangate:persona" }),
  async (req, res) => {
    if (!personaConfigured()) {
      return res.status(503).json({ error: { code: "PERSONA_NOT_CONFIGURED", message: "Identity verification is not enabled." } });
    }
    const parsed = personaInquiryBody.safeParse(req.body);
    if (!parsed.success) {
      return res.status(400).json({ error: { code: "VALIDATION", message: "gateToken is required" } });
    }
    const { gateToken } = parsed.data;
    try {
      const inquiry = await createInquiry(gateTokenHash(gateToken));
      const sessionToken = await resumeInquiry(inquiry.id);
      const attached = attachPersonaInquiry(gateToken, inquiry.id);
      if ("error" in attached) {
        return res.status(403).json({ error: { code: attached.error, message: "Gate session missing, expired, or unscored." } });
      }
      res.status(201).json({ inquiryId: inquiry.id, sessionToken });
    } catch (err) {
      const status = personaErrorStatus(err);
      res.status(status).json({ error: { code: "PERSONA_ERROR", message: err instanceof Error ? err.message : "Persona request failed." } });
    }
  }
);

// POST /human-gate/persona/complete { gateToken, inquiryId }
// Called when the widget closes (complete OR cancel). The status recorded is
// whatever Persona reports server-side — never the client's word — and the
// inquiry must be the one bound to this gate session.
humanGateRouter.post(
  "/persona/complete",
  rateLimit({ windowMs: 60_000, max: 20, keyPrefix: "humangate:persona" }),
  async (req, res) => {
    if (!personaConfigured()) {
      return res.status(503).json({ error: { code: "PERSONA_NOT_CONFIGURED", message: "Identity verification is not enabled." } });
    }
    const parsed = personaCompleteBody.safeParse(req.body);
    if (!parsed.success) {
      return res.status(400).json({ error: { code: "VALIDATION", message: "gateToken and inquiryId are required" } });
    }
    const { gateToken, inquiryId } = parsed.data;
    try {
      const inquiry = await getInquiry(inquiryId);
      if (inquiry.referenceId !== gateTokenHash(gateToken)) {
        return res.status(409).json({ error: { code: "INQUIRY_MISMATCH", message: "Inquiry is not bound to this gate session." } });
      }
      const recorded = recordPersonaStatus(gateToken, inquiryId, inquiry.status);
      if ("error" in recorded) {
        const status = recorded.error === "INQUIRY_MISMATCH" ? 409 : 403;
        return res.status(status).json({ error: { code: recorded.error, message: "Gate session or inquiry binding rejected." } });
      }
      res.json({ status: inquiry.status });
    } catch (err) {
      const status = personaErrorStatus(err);
      res.status(status).json({ error: { code: "PERSONA_ERROR", message: err instanceof Error ? err.message : "Persona request failed." } });
    }
  }
);
