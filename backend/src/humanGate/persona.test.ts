import { describe, it, expect, beforeAll, afterAll, beforeEach, afterEach, vi } from "vitest";
import { createHash } from "crypto";
import { buildApp } from "../index";
import type { Server } from "http";

let server: Server;
let base: string;

beforeAll(async () => {
  const app = buildApp();
  await new Promise<void>((resolve) => {
    server = app.listen(0, () => resolve());
  });
  base = `http://127.0.0.1:${(server.address() as { port: number }).port}`;
});

afterAll(async () => {
  await new Promise<void>((resolve) => server.close(() => resolve()));
});

const post = (path: string, body: unknown) =>
  fetch(`${base}${path}`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify(body)
  });

const uniq = (s: string) => `${s}_${Date.now().toString(36)}${Math.floor(Math.random() * 1e4)}`;
const sha256 = (s: string) => createHash("sha256").update(s).digest("hex");

/** Scored, unconsumed gate token. */
async function scoredGate() {
  const session = await post("/human-gate/session", {});
  const { gateToken } = (await session.json()) as { gateToken: string };
  await post("/human-gate/result", { gateToken, score: 12, verdict: "pass", flags: [] });
  return gateToken;
}

/** Stub only Persona API calls; real fetch still serves the test server. */
let realFetch: typeof fetch;
function stubPersona(handler: (url: string, init?: RequestInit) => unknown) {
  vi.stubGlobal("fetch", async (input: RequestInfo | URL, init?: RequestInit) => {
    const url = typeof input === "string" ? input : input instanceof URL ? input.href : input.url;
    if (url.includes("withpersona.com")) {
      const body = handler(url, init);
      return new Response(JSON.stringify(body), { status: 200, headers: { "content-type": "application/json" } });
    }
    return realFetch(input, init);
  });
}

const INQUIRY_ID = "inq_test_123";

beforeEach(() => {
  realFetch = globalThis.fetch;
});

afterEach(() => {
  vi.unstubAllGlobals();
  delete process.env.PERSONA_API_KEY;
  delete process.env.PERSONA_TEMPLATE_ID;
});

describe("persona leg disabled", () => {
  // A developer's local .env may configure Persona; this leg must behave as
  // unconfigured regardless.
  beforeEach(() => {
    delete process.env.PERSONA_API_KEY;
    delete process.env.PERSONA_TEMPLATE_ID;
  });

  it("returns 503 PERSONA_NOT_CONFIGURED without env config", async () => {
    const gateToken = await scoredGate();
    const res = await post("/human-gate/persona/inquiry", { gateToken });
    expect(res.status).toBe(503);
    expect(((await res.json()) as { error: { code: string } }).error.code).toBe("PERSONA_NOT_CONFIGURED");
  });

  it("still registers — the leg is optional", async () => {
    const gateToken = await scoredGate();
    const res = await post("/auth/register", { username: uniq("nopersona"), password: "hunter2!!", gateToken });
    expect(res.status).toBe(201);
    const body = (await res.json()) as { humanGate: { personaStatus: string | null } };
    expect(body.humanGate.personaStatus).toBeNull();
  });
});

describe("persona leg enabled", () => {
  beforeEach(() => {
    process.env.PERSONA_API_KEY = "persona_sandbox_test";
    process.env.PERSONA_TEMPLATE_ID = "itmpl_test";
  });

  it("creates an inquiry bound to the gate session and returns a session token", async () => {
    const gateToken = await scoredGate();
    const calls: string[] = [];
    stubPersona((url) => {
      calls.push(url);
      if (url.endsWith("/resume")) {
        return { data: { id: INQUIRY_ID, attributes: { status: "pending" } }, meta: { "session-token": "sess_tok" } };
      }
      return { data: { id: INQUIRY_ID, attributes: { status: "created", "reference-id": sha256(gateToken) } } };
    });

    const res = await post("/human-gate/persona/inquiry", { gateToken });
    expect(res.status).toBe(201);
    const body = (await res.json()) as { inquiryId: string; sessionToken: string };
    expect(body.inquiryId).toBe(INQUIRY_ID);
    expect(body.sessionToken).toBe("sess_tok");
    expect(calls.some((u) => u.endsWith("/inquiries"))).toBe(true);
    expect(calls.some((u) => u.endsWith(`/${INQUIRY_ID}/resume`))).toBe(true);
  });

  it("rejects inquiry creation for unscored or bogus tokens", async () => {
    const { gateToken } = (await (await post("/human-gate/session", {})).json()) as { gateToken: string };
    stubPersona(() => ({ data: { id: INQUIRY_ID, attributes: { status: "created" } }, meta: { "session-token": "s" } }));
    expect((await post("/human-gate/persona/inquiry", { gateToken })).status).toBe(403);
    expect((await post("/human-gate/persona/inquiry", { gateToken: "forged" })).status).toBe(403);
    expect((await post("/human-gate/persona/inquiry", {})).status).toBe(400);
  });

  it("records the server-verified status and carries it onto the account", async () => {
    const gateToken = await scoredGate();
    stubPersona((url) => {
      if (url.endsWith("/resume")) {
        return { data: { id: INQUIRY_ID, attributes: { status: "pending" } }, meta: { "session-token": "s" } };
      }
      return { data: { id: INQUIRY_ID, attributes: { status: "approved", "reference-id": sha256(gateToken) } } };
    });

    expect((await post("/human-gate/persona/inquiry", { gateToken })).status).toBe(201);
    const complete = await post("/human-gate/persona/complete", { gateToken, inquiryId: INQUIRY_ID });
    expect(complete.status).toBe(200);
    expect(((await complete.json()) as { status: string }).status).toBe("approved");

    const res = await post("/auth/register", { username: uniq("verified"), password: "hunter2!!", gateToken });
    expect(res.status).toBe(201);
    const body = (await res.json()) as { humanGate: { personaStatus: string } };
    expect(body.humanGate.personaStatus).toBe("approved");
  });

  it("rejects completing an inquiry bound to a different session", async () => {
    const gateToken = await scoredGate();
    stubPersona((url) => {
      if (url.endsWith("/resume")) {
        return { data: { id: INQUIRY_ID, attributes: { status: "pending" } }, meta: { "session-token": "s" } };
      }
      // Persona reports a different reference-id — not this session's inquiry
      return { data: { id: "inq_other", attributes: { status: "approved", "reference-id": sha256("other") } } };
    });
    expect((await post("/human-gate/persona/inquiry", { gateToken })).status).toBe(201);
    const complete = await post("/human-gate/persona/complete", { gateToken, inquiryId: "inq_other" });
    expect(complete.status).toBe(409);
  });
});
