import { describe, it, expect, beforeAll, afterAll, beforeEach, afterEach, vi } from "vitest";
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

const post = (path: string, body: unknown, token?: string) =>
  fetch(`${base}${path}`, {
    method: "POST",
    headers: {
      "content-type": "application/json",
      ...(token ? { "x-demo-session": token } : {})
    },
    body: JSON.stringify(body)
  });

const get = (path: string, token?: string) =>
  fetch(`${base}${path}`, {
    headers: token ? { "x-demo-session": token } : {}
  });

async function createSession(actorType: "human" | "agent") {
  const res = await post("/demo/session", { actorType });
  expect(res.status).toBe(201);
  return (await res.json()) as { sessionToken: string; session: { id: string; personaStatus: string } };
}

describe("demo disabled by default", () => {
  beforeEach(() => {
    delete process.env.ENABLE_PERSONA_DEMO;
  });

  it("404s every /demo route", async () => {
    expect((await post("/demo/session", { actorType: "human" })).status).toBe(404);
    expect((await get("/demo/security-events")).status).toBe(404);
  });
});

describe("demo enabled (mock Persona adapter, no sandbox creds)", () => {
  beforeEach(() => {
    process.env.ENABLE_PERSONA_DEMO = "true";
    delete process.env.PERSONA_API_KEY;
    delete process.env.PERSONA_TEMPLATE_ID;
  });

  afterEach(() => {
    delete process.env.ENABLE_PERSONA_DEMO;
  });

  it("rejects a malformed session request", async () => {
    expect((await post("/demo/session", { actorType: "robot" })).status).toBe(400);
    expect((await post("/demo/session", {})).status).toBe(400);
  });

  it("issues distinct sessions for human and agent", async () => {
    const human = await createSession("human");
    const agent = await createSession("agent");
    expect(human.sessionToken).not.toBe(agent.sessionToken);
    expect(human.session.id).not.toBe(agent.session.id);
    expect(human.session.personaStatus).toBe("not_started");
  });

  it("rejects protected/persona routes without a session token", async () => {
    expect((await get("/demo/protected")).status).toBe(401);
    expect((await post("/demo/persona/start", {})).status).toBe(401);
  });

  it("blocks an unverified session — human or agent alike — behind PERSONA_REQUIRED", async () => {
    const { sessionToken: humanToken } = await createSession("human");
    const { sessionToken: agentToken } = await createSession("agent");

    for (const token of [humanToken, agentToken]) {
      const res = await get("/demo/protected", token);
      expect(res.status).toBe(403);
      const body = (await res.json()) as { code: string };
      expect(body.code).toBe("PERSONA_REQUIRED");
    }
  });

  it("verifies a human through the mock adapter and grants protected access", async () => {
    const { sessionToken } = await createSession("human");

    const start = await post("/demo/persona/start", {}, sessionToken);
    expect(start.status).toBe(201);

    const complete = await post("/demo/persona/complete", {}, sessionToken);
    expect(complete.status).toBe(200);
    expect(((await complete.json()) as { status: string }).status).toBe("verified");

    const protectedRes = await get("/demo/protected", sessionToken);
    expect(protectedRes.status).toBe(200);
    const body = (await protectedRes.json()) as { success: boolean };
    expect(body.success).toBe(true);
  });

  it("never verifies an agent — the mock adapter fails it, and access stays blocked", async () => {
    const { sessionToken } = await createSession("agent");

    await post("/demo/persona/start", {}, sessionToken);
    const complete = await post("/demo/persona/complete", {}, sessionToken);
    expect(((await complete.json()) as { status: string }).status).toBe("failed");

    const protectedRes = await get("/demo/protected", sessionToken);
    expect(protectedRes.status).toBe(403);
  });

  it("cannot set its own persona status via the protected/persona routes", async () => {
    const { sessionToken } = await createSession("agent");
    await post("/demo/persona/start", {}, sessionToken);
    // No client-controlled "verified" field exists on any request body —
    // confirm the server ignores an attempt to smuggle one in, and derives
    // the status from the adapter (which fails every agent) regardless.
    const res = await post("/demo/persona/complete", { status: "verified", personaStatus: "verified" }, sessionToken);
    expect(((await res.json()) as { status: string }).status).toBe("failed");
  });

  it("routes an agent through the honeypot and logs the rickroll", async () => {
    const { sessionToken, session } = await createSession("agent");
    const res = await get("/demo/honeypot", sessionToken);
    expect(res.status).toBe(200);

    const events = (await (await get("/demo/security-events")).json()) as {
      events: { sessionId: string; type: string }[];
    };
    const forThisSession = events.events.filter((e) => e.sessionId === session.id);
    expect(forThisSession.some((e) => e.type === "HONEYPOT_TRIGGERED")).toBe(true);
    expect(forThisSession.some((e) => e.type === "AGENT_RICKROLLED")).toBe(true);
  });

  it("records the full human happy-path in the security event log", async () => {
    const { sessionToken, session } = await createSession("human");
    await get("/demo/protected", sessionToken);
    await post("/demo/persona/start", {}, sessionToken);
    await post("/demo/persona/complete", {}, sessionToken);
    await get("/demo/protected", sessionToken);

    const events = (await (await get("/demo/security-events")).json()) as {
      events: { sessionId: string; type: string }[];
    };
    const types = events.events.filter((e) => e.sessionId === session.id).map((e) => e.type);
    expect(types).toEqual(
      expect.arrayContaining([
        "SESSION_CREATED",
        "PROTECTED_ROUTE_REQUESTED",
        "PERSONA_REQUIRED",
        "ACCESS_BLOCKED",
        "PERSONA_STARTED",
        "PERSONA_VERIFIED",
        "ACCESS_GRANTED"
      ])
    );
  });
});

describe("demo enabled with Persona sandbox configured", () => {
  let realFetch: typeof fetch;

  beforeEach(() => {
    process.env.ENABLE_PERSONA_DEMO = "true";
    process.env.PERSONA_API_KEY = "persona_sandbox_test";
    process.env.PERSONA_TEMPLATE_ID = "itmpl_test";
    realFetch = globalThis.fetch;
  });

  afterEach(() => {
    vi.unstubAllGlobals();
    delete process.env.ENABLE_PERSONA_DEMO;
    delete process.env.PERSONA_API_KEY;
    delete process.env.PERSONA_TEMPLATE_ID;
  });

  function stubPersona(handler: (url: string) => unknown) {
    vi.stubGlobal("fetch", async (input: RequestInfo | URL, init?: RequestInit) => {
      const url = typeof input === "string" ? input : input instanceof URL ? input.href : input.url;
      if (url.includes("withpersona.com")) {
        return new Response(JSON.stringify(handler(url)), { status: 200, headers: { "content-type": "application/json" } });
      }
      return realFetch(input, init);
    });
  }

  it("drives verification through the real sandbox adapter, not the mock", async () => {
    const { sessionToken, session } = await createSession("human");
    stubPersona((url) => {
      if (url.endsWith("/resume")) {
        return { data: { id: "inq_demo_1", attributes: { status: "pending" } }, meta: { "session-token": "sess_tok" } };
      }
      if (url.endsWith("/inquiries")) {
        return { data: { id: "inq_demo_1", attributes: { status: "created" } } };
      }
      // GET .../inquiries/inq_demo_1 — reference-id must match the demo's namespaced hash.
      return {
        data: {
          id: "inq_demo_1",
          attributes: { status: "approved", "reference-id": `demo:${require("crypto").createHash("sha256").update(session.id).digest("hex")}` }
        }
      };
    });

    const start = await post("/demo/persona/start", {}, sessionToken);
    expect(start.status).toBe(201);
    const startBody = (await start.json()) as { inquiryId: string; personaSessionToken: string };
    expect(startBody.inquiryId).toBe("inq_demo_1");
    expect(startBody.personaSessionToken).toBe("sess_tok");

    const complete = await post("/demo/persona/complete", {}, sessionToken);
    expect(((await complete.json()) as { status: string }).status).toBe("verified");

    expect((await get("/demo/protected", sessionToken)).status).toBe(200);
  });
});
