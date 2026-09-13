// E2E for the signup gate. The backend is mocked at the network layer
// (page.route) and the Persona SDK at the window global — what's under test
// is our flow: game → gate result → Persona widget → register → done.

import { test, expect } from "@playwright/test";

const GATE_TOKEN = "test-gate-token-abc123";

/** Intercept every backend call; personaMode: "on" | "off". */
async function mockBackend(page, { personaMode = "on", requests = [] } = {}) {
  const json = (body, status = 200) => ({
    status,
    contentType: "application/json",
    body: JSON.stringify(body),
  });
  await page.route("**/human-gate/session", (route) =>
    route.fulfill(json({ gateToken: GATE_TOKEN, expiresAt: new Date(Date.now() + 9e5).toISOString() }, 201)));
  await page.route("**/human-gate/result", (route) => {
    requests.push({ path: "/result", body: route.request().postDataJSON() });
    return route.fulfill(json({ ok: true }));
  });
  await page.route("**/human-gate/persona/inquiry", (route) => {
    requests.push({ path: "/persona/inquiry", body: route.request().postDataJSON() });
    return route.fulfill(
      personaMode === "on"
        ? json({ inquiryId: "inq_e2e_1", sessionToken: "sess_tok" }, 201)
        : json({ error: { code: "PERSONA_NOT_CONFIGURED", message: "off" } }, 503));
  });
  await page.route("**/human-gate/persona/complete", (route) => {
    requests.push({ path: "/persona/complete", body: route.request().postDataJSON() });
    return route.fulfill(json({ status: "approved" }));
  });
  await page.route("**/auth/register", (route) => {
    requests.push({ path: "/auth/register", body: route.request().postDataJSON() });
    return route.fulfill(json({ playerId: "p_e2e", token: "sess", account: { username: "e2e_user" } }, 201));
  });
}

/** Stub window.Persona before app scripts run. behavior: complete | cancel | error
 *  The CDN <script> in index.html must be blocked or it overwrites the stub. */
async function fakePersonaSdk(page, behavior = "complete") {
  await page.route("**/cdn.withpersona.com/**", (route) => route.abort());
  await page.addInitScript((b) => {
    window.__personaCalls = [];
    window.Persona = {
      Client: class {
        constructor(opts) {
          this.opts = opts;
          window.__personaCalls.push({ inquiryId: opts.inquiryId, sessionToken: opts.sessionToken });
          setTimeout(() => opts.onReady?.(), 0);
        }
        open() {
          setTimeout(() => {
            if (b === "complete") this.opts.onComplete?.({ inquiryId: this.opts.inquiryId, status: "completed" });
            else if (b === "cancel") this.opts.onCancel?.({ inquiryId: this.opts.inquiryId });
            else this.opts.onError?.(new Error("sdk boom"));
          }, 20);
        }
        destroy() {}
      },
    };
  }, behavior);
}

/** Play whatever round is on screen until the game screen is left. */
async function playGame(page) {
  const game = page.locator("#screen-game");
  for (let i = 0; i < 300; i++) {
    if (!(await game.isVisible())) return;
    const instruction = (await page.locator("#hud-instruction").innerText()).toLowerCase();
    const orbs = page.locator('.orb[aria-label="target"]');
    const n = await orbs.count();
    if (instruction.includes("in order")) {
      // click the lowest visible sequence number
      let best = null;
      for (let j = 0; j < n; j++) {
        const seq = Number(await orbs.nth(j).locator(".orb-num").innerText());
        if (!best || seq < best.seq) best = { seq, orb: orbs.nth(j) };
      }
      if (best) await best.orb.dispatchEvent("pointerdown");
    } else if (instruction.includes("only the")) {
      const color = instruction.match(/only the (\w+)/)?.[1];
      const match = page.locator(`.orb-${color}[aria-label="target"]`);
      for (let j = 0; j < (await match.count()); j++) {
        await match.nth(j).dispatchEvent("pointerdown");
      }
    } else {
      for (let j = 0; j < n; j++) await orbs.nth(j).dispatchEvent("pointerdown");
    }
    await page.waitForTimeout(90);
  }
}

async function runSignupToGame(page) {
  await page.goto("/");
  await page.fill('#signup-form input[name="username"]', "e2e_user");
  await page.fill('#signup-form input[name="password"]', "hunter2!!");
  await page.click("#btn-signup");
  await expect(page.locator("#screen-intro")).toBeVisible();
  await page.click("#btn-start");
  await playGame(page);
  // stats breakdown sits between result and done
  await page.locator("#btn-stats-continue").click({ timeout: 15_000 });
}

test("happy path: game → persona widget → register → done", async ({ page }) => {
  const requests = [];
  await mockBackend(page, { requests });
  await fakePersonaSdk(page, "complete");
  await runSignupToGame(page);

  await expect(page.locator("#screen-done")).toBeVisible({ timeout: 15_000 });

  const paths = requests.map((r) => r.path);
  expect(paths).toEqual([
    "/result",
    "/persona/inquiry",
    "/persona/complete",
    "/auth/register",
  ]);
  expect(requests.at(-1).body.gateToken).toBe(GATE_TOKEN);

  const calls = await page.evaluate(() => window.__personaCalls);
  expect(calls).toEqual([{ inquiryId: "inq_e2e_1", sessionToken: "sess_tok" }]);
});

test("persona unconfigured: widget skipped, account still registers", async ({ page }) => {
  const requests = [];
  await mockBackend(page, { personaMode: "off", requests });
  await fakePersonaSdk(page, "complete");
  await runSignupToGame(page);

  await expect(page.locator("#screen-done")).toBeVisible({ timeout: 15_000 });
  const paths = requests.map((r) => r.path);
  expect(paths).toEqual(["/result", "/persona/inquiry", "/auth/register"]);
  expect(await page.evaluate(() => window.__personaCalls)).toEqual([]);
});

test("persona cancelled: status still recorded, account still registers", async ({ page }) => {
  const requests = [];
  await mockBackend(page, { requests });
  await fakePersonaSdk(page, "cancel");
  await runSignupToGame(page);

  await expect(page.locator("#screen-done")).toBeVisible({ timeout: 15_000 });
  expect(requests.map((r) => r.path)).toContain("/persona/complete");
  expect(requests.at(-1).path).toBe("/auth/register");
});
