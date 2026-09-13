import { describe, it, expect, beforeEach, afterEach, vi } from "vitest";
import express from "express";
import { buildApp } from "../index";

async function freshApp() {
  process.env.NUTRIQUEST_DB = ":memory:";
  // A developer's local .env may configure Persona, which turns login into a
  // two-step challenge (covered in personaLogin.test.ts). These tests pin the
  // plain password flow.
  process.env.PERSONA_API_KEY = "";
  process.env.PERSONA_TEMPLATE_ID = "";
  vi.resetModules();
  const { buildApp } = await import("../index");
  const app = buildApp();
  const server = app.listen(0);
  const port = (server.address() as { port: number }).port;
  return { app, server, port };
}

describe("auth accounts", () => {
  it("registers, logs in, and protects a route with a bearer token", async () => {
    const { server, port } = await freshApp();
    const base = `http://127.0.0.1:${port}`;
    try {
      // Registration requires a completed human-gate token.
      const gate = await fetch(`${base}/human-gate/session`, { method: "POST" });
      const { gateToken } = (await gate.json()) as { gateToken: string };
      await fetch(`${base}/human-gate/result`, {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ gateToken, score: 10, verdict: "pass", flags: [] })
      });

      const username = `tr_${Date.now().toString(36)}`;
      const register = await fetch(`${base}/auth/register`, {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ username, password: "hunter2!!", gateToken })
      });
      expect(register.status).toBe(201);
      const { token, playerId } = (await register.json()) as { token: string; playerId: string };
      expect(token).toBeTruthy();
      expect(playerId).toBeTruthy();

      const me = await fetch(`${base}/auth/me`, {
        headers: { authorization: `Bearer ${token}` }
      });
      expect(me.status).toBe(200);
      expect(((await me.json()) as { playerId: string }).playerId).toBe(playerId);

      const login = await fetch(`${base}/auth/login`, {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ username, password: "hunter2!!" })
      });
      expect(login.status).toBe(200);

      const bad = await fetch(`${base}/auth/me`, {
        headers: { authorization: "Bearer bad-token" }
      });
      expect(bad.status).toBe(401);
    } finally {
      await new Promise<void>((resolve) => server.close(() => resolve()));
    }
  });
});
