import { describe, it, expect, beforeAll, afterAll } from "vitest";
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

// Usernames must not collide across runs — the suite shares the on-disk
// dev DB, so a previous run's account row persists.
const uniq = (s: string) => `${s}_${Date.now().toString(36)}${Math.floor(Math.random() * 1e4)}`;

/** Full happy-path gate run; returns a scored, unconsumed gate token. */
async function scoredGate(verdict = "pass", score = 12) {
  const session = await post("/human-gate/session", {});
  expect(session.status).toBe(201);
  const { gateToken } = (await session.json()) as { gateToken: string };
  const result = await post("/human-gate/result", {
    gateToken, score, verdict, flags: []
  });
  expect(result.status).toBe(200);
  return gateToken;
}

describe("human-gate sessions", () => {
  it("issues a token and accepts one result", async () => {
    const session = await post("/human-gate/session", {});
    expect(session.status).toBe(201);
    const { gateToken, expiresAt } = (await session.json()) as { gateToken: string; expiresAt: string };
    expect(gateToken.length).toBeGreaterThan(20);
    expect(Date.parse(expiresAt)).toBeGreaterThan(Date.now());

    const result = await post("/human-gate/result", {
      gateToken, score: 55, verdict: "flag", flags: ["inhuman-speed"]
    });
    expect(result.status).toBe(200);

    // second result rejected
    const again = await post("/human-gate/result", {
      gateToken, score: 0, verdict: "pass", flags: []
    });
    expect(again.status).toBe(409);
  });

  it("rejects results for unknown or malformed tokens", async () => {
    expect((await post("/human-gate/result", { gateToken: "nope", score: 0, verdict: "pass", flags: [] })).status).toBe(403);
    expect((await post("/human-gate/result", { score: 0, verdict: "pass" })).status).toBe(400);
  });

  it("rejects malformed scores and verdicts", async () => {
    const { gateToken } = (await (await post("/human-gate/session", {})).json()) as { gateToken: string };
    for (const body of [
      { gateToken, score: -5, verdict: "pass", flags: [] },
      { gateToken, score: 120, verdict: "pass", flags: [] },
      { gateToken, score: "fast", verdict: "pass", flags: [] },
      { gateToken, score: 10, verdict: "superhuman", flags: [] },
      { gateToken, score: 10, verdict: "pass", flags: "inhuman-speed" }
    ]) {
      expect((await post("/human-gate/result", body)).status).toBe(400);
    }
  });
});

describe("registration requires the gate", () => {
  it("rejects register without a gateToken", async () => {
    const res = await post("/auth/register", { username: uniq("nogate"), password: "hunter2!!" });
    expect(res.status).toBe(403);
    expect(((await res.json()) as { error: { code: string } }).error.code).toBe("HUMAN_GATE_REQUIRED");
  });

  it("rejects register with an unscored or bogus token", async () => {
    const { gateToken } = (await (await post("/human-gate/session", {})).json()) as { gateToken: string };
    const unscored = await post("/auth/register", { username: uniq("early"), password: "hunter2!!", gateToken });
    expect(unscored.status).toBe(403);
    const bogus = await post("/auth/register", { username: uniq("bogus"), password: "hunter2!!", gateToken: "forged" });
    expect(bogus.status).toBe(403);
  });

  it("registers with a scored token, and the token cannot be reused", async () => {
    const gateToken = await scoredGate();
    const res = await post("/auth/register", {
      username: uniq("gated"), password: "hunter2!!", displayName: "Gated One", gateToken
    });
    expect(res.status).toBe(201);
    const body = (await res.json()) as { token: string; playerId: string; humanGate: { score: number; verdict: string } };
    expect(body.token).toBeTruthy();
    expect(body.humanGate.verdict).toBe("pass");

    // token burned — second account with same gate fails
    const reuse = await post("/auth/register", { username: uniq("reuse"), password: "hunter2!!", gateToken });
    expect(reuse.status).toBe(403);
  });

  it("a flagged verdict still registers (non-punitive) but stays recorded", async () => {
    const gateToken = await scoredGate("flag", 88);
    const res = await post("/auth/register", { username: uniq("flagged"), password: "hunter2!!", gateToken });
    expect(res.status).toBe(201);
    const { humanGate } = (await res.json()) as { humanGate: { verdict: string; score: number } };
    expect(humanGate.verdict).toBe("flag");
    expect(humanGate.score).toBe(88);
  });
});
