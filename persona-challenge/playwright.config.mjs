import { defineConfig } from "@playwright/test";

// Static app — no build. Backend is mocked per-test with page.route(), so
// these specs exercise the web app + its glue to the API contract, not the
// server (backend has its own vitest suite).
export default defineConfig({
  testDir: "./e2e",
  testIgnore: "website.spec.mjs",
  timeout: 45_000,
  retries: 0,
  reporter: "list",
  use: {
    channel: process.env.PLAYWRIGHT_CHANNEL || undefined,
    baseURL: "http://localhost:8123",
    viewport: { width: 420, height: 800 },
  },
  webServer: {
    // Runtime files live in backend/public/human-gate/ — served at /gate by
    // the backend in production, mirrored here from the same source.
    command: "python3 -m http.server 8123 -d ../backend/public/human-gate",
    url: "http://localhost:8123",
    reuseExistingServer: true,
  },
});
