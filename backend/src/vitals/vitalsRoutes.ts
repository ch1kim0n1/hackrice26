import { Router } from "express";
import { analyze } from "./vitalsAnalysis";
import { presentMetrics, validateSnapshot } from "./validateSnapshot";
import { MAX_SNAPSHOTS, vitalsStoreFor } from "./vitalsStore";
import { PlayerRequest, requirePlayerId } from "../middleware/player";
import { rateLimitByPlayer, requireAdminToken } from "../middleware/security";
import { hasDatabaseUrl } from "../db/pg";
import { enqueueMirror } from "../services/mirrorQueue";

export const vitalsRouter = Router();

// Every vitals route is scoped to the X-Player-Id caller — HealthKit data is
// per-person, so one client must never read another's snapshots.
vitalsRouter.use(requirePlayerId);

// POST /vitals -- receive one HealthKit snapshot from the iOS app.
vitalsRouter.post("/", rateLimitByPlayer({ windowMs: 60_000, max: 60, keyPrefix: "vitals", message: "Too many vitals snapshots. Try again later." }), (req: PlayerRequest, res) => {
  const result = validateSnapshot(req.body);

  if (!result.ok) {
    const fields = [...new Set(result.errors.map((e) => e.field))].sort();
    // Log which fields were rejected, never the values that were sent.
    console.warn(`Rejected malformed snapshot; invalid fields: ${fields.join(", ")}`);
    return res.status(422).json({
      success: false,
      message: `Invalid payload: ${fields.join(", ")}`,
      errors: result.errors
    });
  }

  const { snapshot } = result;
  const analysis = analyze(snapshot);

  vitalsStoreFor(req.playerId!).add({
    receivedAt: new Date().toISOString(),
    snapshot,
    analysis
  });

  // Best-effort mirror into TigerData (normalized hypertables). SQLite above stays
  // the source of truth for the running app; this is additive and only runs when a
  // Tiger Cloud DATABASE_URL is configured. A mirror failure never fails the request.
  if (hasDatabaseUrl()) {
    enqueueMirror("health_snapshot", `${req.playerId!}:${snapshot.timestamp}`, {
      playerId: req.playerId!,
      snapshot,
    });
  }

  // Metric names only -- the values themselves stay out of the log.
  const metrics = presentMetrics(snapshot);
  console.log(
    `Snapshot from ${snapshot.testerId ?? "anonymous"} at ${snapshot.timestamp} ` +
      `with metrics: ${metrics.length ? metrics.join(", ") : "none"}` +
      `${snapshot.recentWorkouts.length ? `, ${snapshot.recentWorkouts.length} workout(s)` : ""}`
  );

  return res.json({
    success: true,
    message: "Health snapshot received",
    analysis
  });
});

// GET /vitals/latest -- most recent snapshot, for demoing the pipeline.
vitalsRouter.get("/latest", (req: PlayerRequest, res) => {
  const latest = vitalsStoreFor(req.playerId!).latest();
  if (!latest) return res.status(404).json({ error: "No snapshots received yet." });
  return res.json(latest);
});

// GET /vitals/recent -- last N snapshots, oldest first.
vitalsRouter.get("/recent", (req: PlayerRequest, res) => {
  const requested = Number(req.query.limit ?? 20);
  if (!Number.isFinite(requested) || requested < 1 || requested > MAX_SNAPSHOTS) {
    return res.status(400).json({ error: "limit must be a number between 1 and MAX_SNAPSHOTS." });
  }
  const limit = Math.max(1, Math.min(requested, MAX_SNAPSHOTS));
  const snapshots = vitalsStoreFor(req.playerId!).recent(limit);
  res.json({ count: snapshots.length, snapshots });
});

// POST /vitals/reset -- clear the in-memory history. Admin-only.
vitalsRouter.post("/reset", requireAdminToken, (req: PlayerRequest, res) => {
  const store = vitalsStoreFor(req.playerId!);
  store.reset();
  res.json({ reset: true, count: store.count });
});
