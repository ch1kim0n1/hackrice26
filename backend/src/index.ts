import "./env";
import express, { ErrorRequestHandler } from "express";
import { join } from "path";
import cors from "cors";
import { charactersRouter } from "./routes/characters";
import { scanRouter } from "./routes/scan";
import { battleRouter } from "./routes/battle";
import { userRouter } from "./routes/user";
import { vitalsRouter } from "./vitals/vitalsRoutes";
import { lootboxRouter } from "./routes/lootbox";
import { cauldronRouter } from "./routes/cauldron";
import { minesRouter } from "./routes/mines";
import { plinkoRouter } from "./routes/plinko";
import { portalWheelRouter } from "./routes/portalWheel";
import { authRouter } from "./auth/routes";
import { humanGateRouter } from "./humanGate/routes";
import { readinessRouter } from "./routes/readiness";
import { trendsRouter } from "./routes/trends";
import { startMirrorDrain } from "./services/mirrorDrain";
import { sweepExpiredSessions } from "./auth/store";
import { sweepExpiredGateSessions } from "./humanGate/store";
import { closeDatabase } from "./db";

/** Uniform JSON error handler. Catches thrown errors from route handlers
 *  (e.g. PLAYER_CAPACITY from stateFor) and returns a structured JSON
 *  response instead of Express's default HTML stack-trace page.
 *  Known operational codes map to specific status codes; everything else
 *  is a 500 with a generic message (no stack trace leak). */
const errorHandler: ErrorRequestHandler = (err, _req, res, _next) => {
  // Body-parser JSON errors carry a statusCode (400) and type marker.
  if (err?.type === "entity.parse.failed" && typeof err?.statusCode === "number") {
    return res.status(err.statusCode).json({ error: { code: "BAD_JSON", message: "Request body is not valid JSON" } });
  }
  const code = typeof err?.message === "string" ? err.message : "INTERNAL";
  const STATUS: Record<string, number> = {
    PLAYER_CAPACITY: 503
  };
  const status = STATUS[code] ?? 500;
  // Only log true 500s; operational errors (503 etc.) are expected.
  if (status === 500) console.error(`[error] ${code}:`, err);
  // Hide internal details for true 500s; surface the code for operational errors.
  const message = status === 500 ? "Internal server error" : code;
  res.status(status).json({ error: { code, message } });
};

/** Builds the fully-wired app without binding a port, so tests can mount it
 *  with their own listener (or a supertest-style harness). */
export function buildApp(): express.Express {
  const app = express();
  // Reflect the request origin only when an explicit allow-list is set;
  // otherwise fall back to the open default the hackathon frontend expects.
  const corsOrigin = process.env.CORS_ORIGIN || true;
  app.use(cors({ origin: corsOrigin }));
  // Dish photos arrive as base64 — only the analyze route gets a larger limit.
  // Its confirm counterpart carries a tiny edits array, so it stays on the
  // small limit along with everything else: a fat body can't smuggle in
  // anywhere except the one route that genuinely needs it.
  app.use("/scan/photo/analyze", express.json({ limit: "8mb" }));
  app.use(express.json({ limit: "64kb" }));

  app.use("/auth", authRouter);
  app.use("/human-gate", humanGateRouter);
  // Pre-generated character art (game-assets/) — catalog/image routes point here.
  app.use("/assets", express.static(join(__dirname, "..", "..", "game-assets")));
  app.use("/characters", charactersRouter);
  app.use("/scan", scanRouter);
  app.use("/battle", battleRouter);
  app.use("/user", userRouter);
  app.use("/vitals", vitalsRouter);
  app.use("/lootbox", lootboxRouter);
  app.use("/cauldron", cauldronRouter);
  app.use("/mines", minesRouter);
  app.use("/plinko", plinkoRouter);
  app.use("/portal-wheel", portalWheelRouter);
  app.use("/trends", trendsRouter);

  app.get("/health", (_req, res) => res.json({ ok: true }));
  // Readiness probe for the Tiger Cloud store (returns 503 until DATABASE_URL is wired).
  app.use(readinessRouter);

  // JSON body-parse errors (e.g. malformed JSON, Infinity literal) land here
  // too — Express emits SyntaxError with `type: "entity.parse.failed"`.
  // Deliver anything the routes queued for TigerData. No-op without
  // DATABASE_URL, so the SQLite-only dev and test setups are untouched.
  startMirrorDrain();

  app.use(errorHandler);

  return app;
}

export const app = buildApp();

// Vitest sets VITEST=1; importing this module in tests must not bind :4000.
if (!process.env.VITEST) {
  // Housekeeping: drop expired sessions hourly.
  setInterval(() => {
    sweepExpiredSessions();
    sweepExpiredGateSessions();
  }, 60 * 60 * 1000).unref();
  const port = process.env.PORT ? Number(process.env.PORT) : 4000;
  const server = app.listen(port, () => {
    console.log(`NutriQuest backend listening on :${port}`);
  });
  let shuttingDown = false;
  const shutdown = () => {
    if (shuttingDown) return;
    shuttingDown = true;
    server.close(() => {
      closeDatabase();
      process.exit(0);
    });
  };
  process.once("SIGINT", shutdown);
  process.once("SIGTERM", shutdown);
}
