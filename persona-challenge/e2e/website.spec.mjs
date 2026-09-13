import { test, expect } from "@playwright/test";

const password = "test-password-123";
const username = () => `web_${Date.now().toString(36)}`;

async function account(request, name) {
  const gate = await request.post("/human-gate/session", { data: {} });
  const { gateToken } = await gate.json();
  await request.post("/human-gate/result", {
    data: { gateToken, score: 75, verdict: "pass", flags: [] },
  });
  const response = await request.post("/auth/register", {
    data: { username: name, password, gateToken },
  });
  expect(response.status()).toBe(201);
}

test.beforeEach(async ({ page }) => {
  // Local auth tests never open an external identity widget.
  await page.route("**/cdn.withpersona.com/**", route => route.abort());
});

test("login errors, success, automatic restore and logout revocation", async ({ page, request }) => {
  const name = username();
  await account(request, name);
  await page.goto("/login/?api=https://example.invalid");
  const form = page.locator("#login-form");
  await form.getByLabel("Username").fill(name);
  await form.getByLabel("Password").fill("wrong-password");
  await form.getByRole("button", { name: "Log in", exact: true }).click();
  await expect(page.getByRole("alert")).toHaveText("Invalid username or password.");
  await form.getByLabel("Password").fill(password);
  await form.getByRole("button", { name: "Log in", exact: true }).click();
  await expect(page).toHaveURL("/");
  const token = await page.evaluate(() => localStorage.getItem("nutriquest.session"));
  expect(token).toBeTruthy();
  await page.goto("/signup/");
  await expect(page).toHaveURL("/");
  await page.getByRole("button", { name: "Menu", exact: true }).click();
  await page.getByRole("link", { name: `Log out ${name}`, exact: true }).click();
  await expect(page.locator("#account-link")).toHaveText("Log in");
  expect(await page.evaluate(() => localStorage.getItem("nutriquest.session"))).toBeNull();
  expect((await request.get("/auth/me", { headers: { Authorization: `Bearer ${token}` } })).status()).toBe(401);
});

test("expired session stays on login and a network error allows retry", async ({ page }) => {
  await page.addInitScript(() => localStorage.setItem("nutriquest.session", "expired-token"));
  await page.goto("/login/");
  await expect(page.getByRole("button", { name: "Log in", exact: true })).toBeEnabled();
  expect(await page.evaluate(() => localStorage.getItem("nutriquest.session"))).toBeNull();
  await page.route("**/auth/login", route => route.abort());
  const form = page.locator("#login-form");
  await form.getByLabel("Username").fill("test_user");
  await form.getByLabel("Password").fill(password);
  await form.getByRole("button", { name: "Log in", exact: true }).click();
  await expect(page.getByRole("alert")).toContainText("Cannot reach the server");
  await expect(form.getByRole("button", { name: "Log in", exact: true })).toBeEnabled();
});

test("signup completes the human check and signs in automatically", async ({ page, request }) => {
  const name = username();
  await page.goto("/signup/");
  const form = page.locator("#signup-form");
  await form.getByLabel("Display name").fill("Food Explorer");
  await form.getByLabel("Username").fill(name);
  await form.getByLabel("Password").fill(password);
  await form.getByRole("button", { name: "Continue", exact: true }).click();
  await page.getByRole("button", { name: "Start", exact: true }).click();
  // The existing gate is non-punitive: a no-tap run finishes with a flag.
  // Exercise that real flow without replacing the registration endpoint.
  await expect(page).toHaveURL("/", { timeout: 50_000 });
  const token = await page.evaluate(() => localStorage.getItem("nutriquest.session"));
  const me = await request.get("/auth/me", { headers: { Authorization: `Bearer ${token}` } });
  expect((await me.json()).account.username).toBe(name);
  await expect(page.locator("#account-link")).toHaveText("Log out");
});

test("account pages fit mobile, desktop and short screens", async ({ page }) => {
  for (const viewport of [{ width: 390, height: 844 }, { width: 1440, height: 900 }, { width: 667, height: 375 }]) {
    await page.setViewportSize(viewport);
    for (const path of ["/login/", "/signup/"]) {
      await page.goto(path);
      await expect(page.getByRole("heading", { level: 1 }).filter({ visible: true })).toBeVisible();
      expect(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth)).toBe(true);
      const link = page.getByRole("link", { name: path === "/login/" ? "Sign up" : "Log in", exact: true });
      await link.scrollIntoViewIfNeeded();
      await expect(link).toBeInViewport();
    }
  }
});
