import { describe, it, expect, vi } from "vitest";

describe("promo codes", () => {
  async function promoModule() {
    vi.resetModules();
    process.env.NUTRIQUEST_DB = ":memory:";
    const { createPromo, deletePromo, redeemPromo } = await import("./promoCodes");
    const { coinBalance } = await import("./coins");
    const { pendingCases } = await import("./lootboxState");
    return { createPromo, deletePromo, redeemPromo, coinBalance, pendingCases };
  }

  it("grants coins and prevents double redeem", async () => {
    const { createPromo, redeemPromo, coinBalance } = await promoModule();
    createPromo("FREECOINS", "coins:500");
    const result = redeemPromo("p1", "FREECOINS");
    expect(result.reward).toBe("coins:500");
    expect(result.coinBalance).toBe(500);
    expect(() => redeemPromo("p1", "FREECOINS")).toThrow("PROMO_ALREADY_REDEEMED");
    const other = redeemPromo("p2", "FREECOINS");
    expect(other.coinBalance).toBe(500);
    expect(coinBalance("p2")).toBe(500);
  });

  it("grants a fixed-rarity Case the player opens through the normal path", async () => {
    const { createPromo, redeemPromo, pendingCases } = await promoModule();
    createPromo("FREECASE", "case:epic");
    const result = redeemPromo("p3", "FREECASE");
    expect(result.reward).toBe("case:epic");
    expect(result.case?.rarity).toBe("epic");
    // The case sits in the pending list — the mint happens at case open.
    expect(pendingCases("p3").map((c) => c.caseId)).toContain(result.case!.caseId);
  });

  it("respects max uses", async () => {
    const { createPromo, redeemPromo } = await promoModule();
    createPromo("LIMTWO", "coins:10", { usesLimit: 2 });
    redeemPromo("a", "LIMTWO");
    redeemPromo("b", "LIMTWO");
    expect(() => redeemPromo("c", "LIMTWO")).toThrow("PROMO_FULLY_REDEEMED");
  });

  it("respects expiration", async () => {
    const { createPromo, redeemPromo } = await promoModule();
    const expired = new Date(Date.now() - 1000).toISOString();
    createPromo("OLD1", "coins:10", { expiresAt: expired });
    expect(() => redeemPromo("x", "OLD1")).toThrow("PROMO_EXPIRED");
  });

  it("rejects invalid format, unknown codes and impossible rewards", async () => {
    const { createPromo, redeemPromo } = await promoModule();
    expect(() => createPromo("lowercase", "coins:10")).toThrow("INVALID_PROMO_CODE_FORMAT");
    expect(() => redeemPromo("x", "NOPE")).toThrow("PROMO_NOT_FOUND");
    expect(() => createPromo("BADR", "keys:10")).toThrow("INVALID_PROMO_REWARD");
    expect(() => createPromo("BADR2", "case:imaginary")).toThrow("INVALID_PROMO_REWARD");
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
        body: JSON.stringify({ code: "HTTP10", reward: "coins:100" })
      });
      expect(create.status).toBe(201);

      const redeem = await fetch(`${base}/lootbox/promos/HTTP10/redeem`, {
        method: "POST",
        headers
      });
      expect(redeem.status).toBe(200);
      const body = (await redeem.json()) as { result: { reward: string; coinBalance: number } };
      expect(body.result.reward).toBe("coins:100");
      expect(body.result.coinBalance).toBe(100);

      const again = await fetch(`${base}/lootbox/promos/HTTP10/redeem`, { method: "POST", headers });
      expect(again.status).toBe(409);
    } finally {
      await new Promise<void>((resolve) => server.close(() => resolve()));
    }
  });
});
