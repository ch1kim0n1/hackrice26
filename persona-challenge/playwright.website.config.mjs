import { defineConfig } from "@playwright/test";

export default defineConfig({
  testDir: "./e2e",
  testMatch: "website.spec.mjs",
  timeout: 60_000,
  workers: 1,
  reporter: "list",
  use: {
    channel: process.env.PLAYWRIGHT_CHANNEL || undefined,
    baseURL: process.env.WEBSITE_TEST_URL || "http://localhost:8125",
    viewport: { width: 390, height: 844 },
  },
  webServer: process.env.WEBSITE_TEST_URL ? undefined : {
    command: "node ../backend/dist/index.js",
    url: "http://localhost:8125/health",
    env: { PORT: "8125", NUTRIQUEST_DB: ":memory:", DATABASE_URL: "", PERSONA_API_KEY: "" },
    reuseExistingServer: false,
  },
});
