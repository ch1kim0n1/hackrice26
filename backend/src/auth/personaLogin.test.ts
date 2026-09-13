import { describe, it, expect, beforeAll, afterAll, beforeEach, afterEach, vi } from "vitest";
import { buildApp } from "../index";
import { listSecurityEvents, resetSecurityEvents } from "../demo/securityEventStore";
import { resetLoginChallenges, RICKROLL_URL } from "./personaLogin";
import type { Server } from "http";

// ============================================================================
// Persona-backed login: the password alone never issues a session while
// Persona is configured, the verified status comes from Persona server-side,
// and the skip-verification honeypot rickrolls whoever goes looking for it.
// ============================================================================

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
const PASSWORD = "hunter2!!";
const INQUIRY_ID = "inq_login_123";

/** Register an account through the real gate (registration never calls Persona). */
async function registeredUser(): Promise<string> {
  const session = await post("/human-gate/session", {});
  const { gateToken } = (await session.json()) as { gateToken: string };
  await post("/human-gate/result", { gateToken, score: 12, verdict: "pass", flags: [] });
  const username = uniq("login");
  const res = await post("/auth/register", { username, password: PASSWORD, gateToken });
  expect(res.status).toBe(201);
  return username;
}

/**
 * Stub Persona only. The inquiry echoes back the reference-id the server
 * created it with, the way the real API does, and reports `status`.
 */
let realFetch: typeof fetch;
function stubPersona(status: string, inquiryId = INQUIRY_ID) {
  let referenceId = "";
  vi.stubGlobal("fetch", async (input: RequestInfo | URL, init?: RequestInit) => {
    const url = typeof input === "string" ? input : input instanceof URL ? input.href : input.url;
    if (!url.includes("withpersona.com")) return realFetch(input, init);
    let body: unknown;
    if (url.endsWith("/inquiries") && init?.method === "POST") {
      referenceId = (JSON.parse(String(init.body)) as { data: { attributes: { "reference-id": string } } })
        .data.attributes["reference-id"];
      body = { data: { id: inquiryId, attributes: { status: "created", "reference-id": referenceId } } };
    } else if (url.endsWith("/resume")) {
      body = { data: { id: inquiryId, attributes: { status: "pending" } }, meta: { "session-token": "sess_tok" } };
    } else {
      body = { data: { id: inquiryId, attributes: { status, "reference-id": referenceId } } };
    }
    return new Response(JSON.stringify(body), { status: 200, headers: { "content-type": "application/json" } });
  });
}

interface Challenge {
  personaRequired: boolean;
  loginToken: string;
  inquiryId: string;
  sessionToken: string;
  token?: string;
}

beforeEach(() => {
  realFetch = globalThis.fetch;
  resetLoginChallenges();
  resetSecurityEvents();
});

afterEach(() => {
  vi.unstubAllGlobals();
  process.env.PERSONA_API_KEY = "";
  process.env.PERSONA_TEMPLATE_ID = "";
});

describe("login without Persona configured", () => {
  it("issues the session straight from the password", async () => {
    const username = await registeredUser();
    process.env.PERSONA_API_KEY = "";
    const res = await post("/auth/login", { username, password: PASSWORD });
    expect(res.status).toBe(200);
    expect(((await res.json()) as { token: string }).token).toBeTruthy();
  });
});

describe("login with Persona configured", () => {
  beforeEach(() => {
    process.env.PERSONA_API_KEY = "persona_sandbox_test";
    process.env.PERSONA_TEMPLATE_ID = "itmpl_test";
  });

  it("holds the session back until Persona reports a verified human", async () => {
    const username = await registeredUser();
    stubPersona("approved");

    const start = await post("/auth/login", { username, password: PASSWORD });
    expect(start.status).toBe(202);
    const challenge = (await start.json()) as Challenge;
    expect(challenge.personaRequired).toBe(true);
    expect(challenge.inquiryId).toBe(INQUIRY_ID);
    expect(challenge.sessionToken).toBe("sess_tok");
    expect(challenge.token).toBeUndefined();

    const done = await post("/auth/login/persona/complete", {
      loginToken: challenge.loginToken,
      inquiryId: challenge.inquiryId
    });
    expect(done.status).toBe(200);
    const { token, personaStatus } = (await done.json()) as { token: string; personaStatus: string };
    expect(personaStatus).toBe("approved");

    const me = await realFetch(`${base}/auth/me`, { headers: { authorization: `Bearer ${token}` } });
    expect(me.status).toBe(200);
  });

  it("refuses a declined check and burns the challenge", async () => {
    const username = await registeredUser();
    stubPersona("declined");

    const challenge = (await (await post("/auth/login", { username, password: PASSWORD })).json()) as Challenge;
    const body = { loginToken: challenge.loginToken, inquiryId: challenge.inquiryId };

    const declined = await post("/auth/login/persona/complete", body);
    expect(declined.status).toBe(403);
    expect(((await declined.json()) as { error: { code: string } }).error.code).toBe("PERSONA_NOT_VERIFIED");

    const retry = await post("/auth/login/persona/complete", body);
    expect(retry.status).toBe(403);
    expect(((await retry.json()) as { error: { code: string } }).error.code).toBe("LOGIN_EXPIRED");
  });

  it("rejects an inquiry that was not opened for this login", async () => {
    const username = await registeredUser();
    stubPersona("approved");
    const challenge = (await (await post("/auth/login", { username, password: PASSWORD })).json()) as Challenge;

    const res = await post("/auth/login/persona/complete", { loginToken: challenge.loginToken, inquiryId: "inq_other" });
    expect(res.status).toBe(409);
  });

  it("rejects a forged login token", async () => {
    stubPersona("approved");
    const res = await post("/auth/login/persona/complete", { loginToken: "forged", inquiryId: INQUIRY_ID });
    expect(res.status).toBe(403);
  });

  it("still gives the generic 401 for a wrong password", async () => {
    const username = await registeredUser();
    stubPersona("approved");
    const res = await post("/auth/login", { username, password: "wrong-password" });
    expect(res.status).toBe(401);
  });
});

describe("skip-verification honeypot", () => {
  it("redirects a followed link to the rickroll and logs it", async () => {
    const res = await fetch(`${base}/auth/login/skip-verification`, { redirect: "manual" });
    expect(res.status).toBe(302);
    expect(res.headers.get("location")).toBe(RICKROLL_URL);
    const types = listSecurityEvents().map((e) => e.type);
    expect(types).toEqual(["HONEYPOT_TRIGGERED", "AGENT_RICKROLLED"]);
  });

  it("answers an API bypass attempt with the rickroll and never a session", async () => {
    const res = await post("/auth/login/skip-verification", { trap: "field" });
    expect(res.status).toBe(403);
    const body = (await res.json()) as { redirect: string; token?: string };
    expect(body.redirect).toBe(RICKROLL_URL);
    expect(body.token).toBeUndefined();
    expect(listSecurityEvents()[0].message).toContain("hidden field");
  });
});
