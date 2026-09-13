import { describe, it, expect, vi } from "vitest";
import { buildApp } from "../index";

describe("promo codes", () => {
  async function promoModule() {
    vi.resetModules();
    process.env.NUTRIQUEST_DB = ":memory:";
    const { createPromo, deletePromo, redeemPromo } = await import("./promoCodes");
    const { stateFor } = await import("./lootboxState");
    return { createPromo, deletePromo, redeemPromo, stateFor };
  }

  it("grants keys and prevents double redeem", async () => {
    const { createPromo, redeemPromo } = await promoModule();
    createPromo("FREEKEYS", "keys:10");
    const result = redeemPromo("p1", "FREEKEYS");
    expect(result.reward).toBe("keys:10");
    expect(result.keys).toBe(35);
    expect(() => redeemPromo("p1", "FREEKEYS")).toThrow("PROMO_ALREADY_REDEEMED");
    const other = redeemPromo("p2", "FREEKEYS");
    expect(other.keys).toBe(35);
  });

  it("opens a crate without spending keys", async () => {
    const { createPromo, redeemPromo, stateFor } = await promoModule();
    createPromo("FREECRATE", "crate:starter-crate");
    const before = stateFor("p3").keys;
    const result = redeemPromo("p3", "FREECRATE");
    expect(result.reward).toBe("crate:starter-crate");
    expect(result.keys).toBe(before);
    expect(result.drop).toBeDefined();
    expect(result.drop?.crateId).toBe("starter-crate");
  });

  it("respects max uses", async () => {
    const { createPromo, redeemPromo } = await promoModule();
    createPromo("LIMTWO", "keys:1", { usesLimit: 2 });
    redeemPromo("a", "LIMTWO");
    redeemPromo("b", "LIMTWO");
    expect(() => redeemPromo("c", "LIMTWO")).toThrow("PROMO_FULLY_REDEEMED");
  });

  it("respects expiration", async () => {
    const { createPromo, redeemPromo } = await promoModule();
    const expired = new Date(Date.now() - 1000).toISOString();
    createPromo("OLD1", "keys:1", { expiresAt: expired });
    expect(() => redeemPromo("x", "OLD1")).toThrow("PROMO_EXPIRED");
  });

  it("rejects invalid format and unknown codes", async () => {
    const { createPromo, redeemPromo } = await promoModule();
    expect(() => createPromo("lowercase", "keys:1")).toThrow("INVALID_PROMO_CODE_FORMAT");
    expect(() => redeemPromo("x", "NOPE")).toThrow("PROMO_NOT_FOUND");
    expect(() => createPromo("BADR", "gold:1")).toThrow("INVALID_PROMO_REWARD");
  });
});

describe("promo routes", () => {
  async function freshApp() {
    process.env.NUTRIQUEST_DB = ":memory:";
    vi.resetModules();
    const { buildApp } = await import("../index");
    const app = buildApp();
    const server = app.listen(0);
    const port = (server.address() as { port: number }).port;
    return { app, server, port };
  }

  it("admin creates, player redeems via HTTP", async () => {
    process.env.NUTRIQUEST_ADMIN_TOKEN = "admin";
    const { server, port } = await freshApp();
    const base = `http://127.0.0.1:${port}`;
    const headers = { "content-type": "application/json", "x-player-id": "player_http" };
    try {
      const create = await fetch(`${base}/lootbox/promos`, {
        method: "POST",
        headers: { ...headers, "x-admin-token": "admin" },
        body: JSON.stringify({ code: "HTTP10", reward: "keys:10" })
      });
      expect(create.status).toBe(201);

      const redeem = await fetch(`${base}/lootbox/promos/HTTP10/redeem`, {
        method: "POST",
        headers
      });
      expect(redeem.status).toBe(200);
      const body = (await redeem.json()) as { result: { reward: string; keys: number } };
      expect(body.result.reward).toBe("keys:10");
      expect(body.result.keys).toBe(35);

      const again = await fetch(`${base}/lootbox/promos/HTTP10/redeem`, { method: "POST", headers });
      expect(again.status).toBe(409);
    } finally {
      await new Promise<void>((resolve) => server.close(() => resolve()));
    }
  });
});
