import { describe, it, expect, beforeAll, beforeEach, afterEach } from "vitest";
import express from "express";

// ============================================================================
// Trends — the read side of the continuous aggregates.
//
// The behaviour worth pinning here is what happens WITHOUT Postgres, because
// that is how the app runs locally and in CI: every route has to answer with an
// empty series rather than a 500, or the casino tab shows an error banner to
// every player who has never had a mirror configured.
//
// The queries themselves are exercised against a real TimescaleDB by
// backend/tests/db/invariants.sql and the integration tests; there is no value
// in mocking pg here to assert that a SELECT was formatted correctly.
// ============================================================================

// In-memory: these routes never touch SQLite, but importing the router pulls in
// the auth store, which opens the database at import time. An in-memory file
// keeps that harmless and leaves nothing on disk to clean up -- the file-based
// teardown other route tests use is what makes them fail on Windows, where the
// handle is still open when rmSync runs.
beforeAll(() => {
  process.env.NUTRIQUEST_DB = "memory";
});

// These routes branch on DATABASE_URL, so each test owns the env explicitly
// rather than inheriting whatever the developer happens to have exported.
let savedUrl: string | undefined;
let savedAdmin: string | undefined;

beforeEach(() => {
  savedUrl = process.env.DATABASE_URL;
  savedAdmin = process.env.DATABASE_URL_ADMIN;
  delete process.env.DATABASE_URL;
  delete process.env.DATABASE_URL_ADMIN;
});

afterEach(() => {
  if (savedUrl === undefined) delete process.env.DATABASE_URL;
  else process.env.DATABASE_URL = savedUrl;
  if (savedAdmin === undefined) delete process.env.DATABASE_URL_ADMIN;
  else process.env.DATABASE_URL_ADMIN = savedAdmin;
});

type Call = (url: string) => Promise<Response>;

async function withServer(run: (call: Call) => Promise<void>): Promise<void> {
  const { trendsRouter } = await import("./trends");

  const app = express();
  app.use(express.json());
  app.use("/trends", trendsRouter);

  const server = app.listen(0);
  await new Promise<void>((resolve) => server.once("listening", resolve));
  const port = (server.address() as { port: number }).port;

  const call: Call = (url) =>
    fetch(`http://127.0.0.1:${port}${url}`, {
      headers: { "X-Player-Id": "trend_player_1" }
    });

  try {
    await run(call);
  } finally {
    await new Promise<void>((resolve) => server.close(() => resolve()));
  }
}

const SERIES = ["casino", "nutrition", "battles", "gameplay", "streak", "pulls", "dungeon"];

describe("GET /trends/* without Postgres", () => {
  it("answers every series with an empty, explicitly-unavailable envelope", async () => {
    await withServer(async (call) => {
      for (const series of SERIES) {
        const res = await call(`/trends/${series}`);
        expect(res.status, `${series} should not error`).toBe(200);
        const body = (await res.json()) as { available: boolean; source: string; points: unknown[] };
        expect(body.available, `${series} available`).toBe(false);
        expect(body.source, `${series} source`).toBe("none");
        expect(body.points, `${series} points`).toEqual([]);
      }
    });
  });

  it("treats health the same way, with its metric parameter", async () => {
    await withServer(async (call) => {
      const res = await call("/trends/health?metric=heart_rate");
      expect(res.status).toBe(200);
      const body = (await res.json()) as { available: boolean; points: unknown[] };
      expect(body.available).toBe(false);
      expect(body.points).toEqual([]);
    });
  });
});

describe("GET /trends/* window validation", () => {
  it("rejects a window that is not a positive integer", async () => {
    await withServer(async (call) => {
      for (const bad of ["hours=0", "hours=-5", "hours=abc"]) {
        const res = await call(`/trends/casino?${bad}`);
        expect(res.status, bad).toBe(400);
        const body = (await res.json()) as { error: { code: string } };
        expect(body.error.code).toBe("INVALID_WINDOW");
      }
    });
  });

  it("rejects a window past the 90-day ceiling rather than silently clamping", async () => {
    await withServer(async (call) => {
      const res = await call("/trends/casino?hours=99999");
      expect(res.status).toBe(400);
    });
  });

  it("accepts a window inside the ceiling", async () => {
    await withServer(async (call) => {
      const res = await call("/trends/casino?hours=24");
      expect(res.status).toBe(200);
    });
  });

  it("rejects a health metric that is not a plain identifier", async () => {
    await withServer(async (call) => {
      const res = await call("/trends/health?metric=heart%20rate");
      expect(res.status).toBe(400);
      const body = (await res.json()) as { error: { code: string } };
      expect(body.error.code).toBe("INVALID_QUERY");
    });
  });
});

describe("GET /trends/* identity", () => {
  it("requires a player id", async () => {
    const { trendsRouter } = await import("./trends");
    const app = express();
    app.use("/trends", trendsRouter);
    const server = app.listen(0);
    await new Promise<void>((resolve) => server.once("listening", resolve));
    const port = (server.address() as { port: number }).port;
    try {
      // No X-Player-Id header at all.
      const res = await fetch(`http://127.0.0.1:${port}/trends/casino`);
      expect(res.status).toBe(400);
    } finally {
      await new Promise<void>((resolve) => server.close(() => resolve()));
    }
  });
});
