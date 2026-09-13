import { describe, it, expect, beforeEach, afterEach, vi } from "vitest";
import express from "express";
import { requirePlayerId } from "./player";
import { rateLimitByPlayer } from "./security";

async function freshBuildApp() {
  process.env.NUTRIQUEST_DB = ":memory:";
  vi.resetModules();
  const { buildApp } = await import("../index");
  return buildApp;
}

describe("rate limiting", () => {
  it("blocks requests that exceed the per-player limit and allows the next after reset", async () => {
    const app = express();
    app.use(express.json());
    app.use(requirePlayerId);
    app.post(
      "/ping",
      rateLimitByPlayer({ windowMs: 200, max: 2, keyPrefix: "test" }),
      (_req, res) => res.json({ ok: true })
    );

    const server = app.listen(0);
    const port = (server.address() as { port: number }).port;
    const headers = { "content-type": "application/json", "x-player-id": "player_rate" };

    try {
      const call = async () =>
        fetch(`http://127.0.0.1:${port}/ping`, { method: "POST", headers });

      const first = await call();
      expect(first.status).toBe(200);
      const second = await call();
      expect(second.status).toBe(200);

      const third = await call();
      expect(third.status).toBe(429);
      const body = (await third.json()) as { error: { code: string } };
      expect(body.error.code).toBe("RATE_LIMITED");

      // Wait for the 200ms window to expire.
      await new Promise((resolve) => setTimeout(resolve, 250));
      const afterReset = await call();
      expect(afterReset.status).toBe(200);
    } finally {
      await new Promise<void>((resolve) => server.close(() => resolve()));
    }
  });
});

describe("admin token guard", () => {
  const player = "player_admin";
  const headers: Record<string, string> = { "content-type": "application/json", "x-player-id": player };

  beforeEach(() => {
    delete process.env.NUTRIQUEST_ADMIN_TOKEN;
  });

  afterEach(() => {
    delete process.env.NUTRIQUEST_ADMIN_TOKEN;
  });

  async function adminCall(token?: string) {
    const buildApp = await freshBuildApp();
    const app = buildApp();
    const server = app.listen(0);
    const port = (server.address() as { port: number }).port;
    const reqHeaders = { ...headers };
    if (token) reqHeaders["x-admin-token"] = token;
    try {
      return await fetch(`http://127.0.0.1:${port}/lootbox/promos`, {
        method: "POST",
        headers: reqHeaders,
        body: JSON.stringify({ code: `SEC${Math.random().toString(36).slice(2, 8).toUpperCase()}`, reward: "coins:10" })
      });
    } finally {
      await new Promise<void>((resolve) => server.close(() => resolve()));
    }
  }

  it("rejects admin routes when no admin token is configured", async () => {
    const res = await adminCall();
    expect(res.status).toBe(503);
    expect(((await res.json()) as { error: { code: string } }).error.code).toBe("ADMIN_ROUTES_DISABLED");
  });

  it("rejects admin routes without or with a wrong token", async () => {
    process.env.NUTRIQUEST_ADMIN_TOKEN = "secret";
    const missing = await adminCall();
    expect(missing.status).toBe(403);
    expect(((await missing.json()) as { error: { code: string } }).error.code).toBe("ADMIN_TOKEN_REQUIRED");

    const wrong = await adminCall("wrong");
    expect(wrong.status).toBe(403);
    expect(((await wrong.json()) as { error: { code: string } }).error.code).toBe("ADMIN_TOKEN_INVALID");
  });

  it("allows admin routes with the correct token", async () => {
    process.env.NUTRIQUEST_ADMIN_TOKEN = "secret";
    const res = await adminCall("secret");
    expect(res.status).toBe(201);
    const body = (await res.json()) as { promo: { reward: string } };
    expect(body.promo.reward).toBe("coins:10");
  });
});
