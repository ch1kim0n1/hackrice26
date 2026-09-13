import { describe, it, expect, beforeAll, afterAll } from "vitest";
import express from "express";
import { rmSync } from "fs";
import { tmpdir } from "os";
import path from "path";

// ============================================================================
// PATCH /user/:id — full nutrition profile write.
//
// The Body & goals editor sends every Mifflin-St Jeor input in one request.
// These tests pin that a valid body lands on the SQLite profile blob, that
// Zod rejects incomplete or out-of-range payloads, and that a player cannot
// overwrite someone else's profile by naming their id in the URL.
// ============================================================================

const DB_FILE = path.join(tmpdir(), `nutriquest-user-${process.pid}-${Date.now()}.db`);

beforeAll(() => {
  process.env.NUTRIQUEST_DB = DB_FILE;
});

afterAll(() => {
  rmSync(DB_FILE, { force: true });
  rmSync(`${DB_FILE}-wal`, { force: true });
  rmSync(`${DB_FILE}-shm`, { force: true });
});

const FULL_PROFILE = {
  age: 34,
  sex: "male" as const,
  heightCm: 180,
  weightKg: 80,
  activity: "light" as const,
  goal: "maintain" as const
};

type Call = (
  method: string,
  path: string,
  headers: Record<string, string>,
  body?: unknown
) => Promise<Response>;

interface ProfileBody {
  profile: {
    age?: number;
    sex?: string;
    heightCm?: number;
    weightKg?: number;
    activity?: string;
    goal?: string;
  };
}

interface ErrorBody {
  error: { code: string; message: string };
}

/** Response.json() is unknown under Node types; tests read fixed shapes. */
async function json<T>(res: Response): Promise<T> {
  return (await res.json()) as T;
}

let playerCounter = 0;

/** Builds a player id that satisfies the X-Player-Id header pattern. */
function freshPlayerId(): string {
  playerCounter += 1;
  return `user_${Date.now().toString(36)}_${playerCounter}`;
}

/** Boots the user router on an ephemeral port with a unique player. */
async function withUserApp(
  run: (call: Call, ctx: { playerId: string; headers: Record<string, string> }) => Promise<void>
): Promise<void> {
  const { userRouter } = await import("./user");
  const playerId = freshPlayerId();
  const headers = { "content-type": "application/json", "x-player-id": playerId };

  const app = express();
  app.use(express.json());
  app.use("/user", userRouter);

  const server = app.listen(0);
  await new Promise<void>((resolve) => server.once("listening", resolve));
  const port = (server.address() as { port: number }).port;
  const call: Call = (method, url, reqHeaders, body) =>
    fetch(`http://127.0.0.1:${port}${url}`, {
      method,
      headers: reqHeaders,
      body: body === undefined ? undefined : JSON.stringify(body)
    });

  try {
    await run(call, { playerId, headers });
  } finally {
    await new Promise<void>((resolve) => server.close(() => resolve()));
  }
}

describe("PATCH /user/:id nutrition profile", () => {
  it("stores all six fields and GET returns them", async () => {
    await withUserApp(async (call, { playerId, headers }) => {
      const patch = await call("PATCH", `/user/${playerId}`, headers, FULL_PROFILE);
      expect(patch.status).toBe(200);
      const patched = await json<ProfileBody>(patch);
      expect(patched.profile).toMatchObject(FULL_PROFILE);

      const get = await call("GET", `/user/${playerId}`, headers);
      expect(get.status).toBe(200);
      const got = await json<ProfileBody>(get);
      expect(got.profile).toMatchObject(FULL_PROFILE);
    });
  });

  it("rejects a missing field", async () => {
    await withUserApp(async (call, { playerId, headers }) => {
      const { age: _age, ...incomplete } = FULL_PROFILE;
      const res = await call("PATCH", `/user/${playerId}`, headers, incomplete);
      expect(res.status).toBe(400);
      const body = await json<ErrorBody>(res);
      expect(body.error.code).toBe("VALIDATION");
    });
  });

  it("rejects age below 10", async () => {
    await withUserApp(async (call, { playerId, headers }) => {
      const res = await call("PATCH", `/user/${playerId}`, headers, { ...FULL_PROFILE, age: 9 });
      expect(res.status).toBe(400);
      expect((await json<ErrorBody>(res)).error.code).toBe("VALIDATION");
    });
  });

  it("rejects sex other", async () => {
    await withUserApp(async (call, { playerId, headers }) => {
      const res = await call("PATCH", `/user/${playerId}`, headers, { ...FULL_PROFILE, sex: "other" });
      expect(res.status).toBe(400);
      expect((await json<ErrorBody>(res)).error.code).toBe("VALIDATION");
    });
  });

  it("rejects an unknown goal", async () => {
    await withUserApp(async (call, { playerId, headers }) => {
      const res = await call("PATCH", `/user/${playerId}`, headers, { ...FULL_PROFILE, goal: "lose" });
      expect(res.status).toBe(400);
      expect((await json<ErrorBody>(res)).error.code).toBe("VALIDATION");
    });
  });

  it("rejects a URL id that does not match the player header", async () => {
    await withUserApp(async (call, { headers }) => {
      const res = await call("PATCH", "/user/someone_else", headers, FULL_PROFILE);
      expect(res.status).toBe(403);
      expect((await json<ErrorBody>(res)).error.code).toBe("PLAYER_ID_MISMATCH");
    });
  });
});
