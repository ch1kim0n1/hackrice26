// Trends -- the read side of the TimescaleDB continuous aggregates.
//
// Every series here is pre-rolled by a continuous aggregate, so the query cost
// does not grow with how long the player has been playing: a 90-day streak
// chart reads 90 daily buckets, not 90 days of raw rows. That is the entire
// reason the aggregates exist, and until this router they had no reader.
//
// Reads go to the replica pool (backend/src/db/pg.ts), which is the primary
// until DATABASE_URL_REPLICA is set.
//
// When no Postgres is configured at all -- the normal local/SQLite setup --
// these answer 200 with `available: false` and an empty series rather than
// failing. A chart with nothing in it is a correct answer for a player with no
// mirrored history; an error banner is not.
import { Router } from "express";
import { z } from "zod";
import { PlayerRequest, requirePlayerId } from "../middleware/player";
import { rateLimitByPlayer } from "../middleware/security";
import { hasDatabaseUrl, hasReadReplica } from "../db/pg";
import {
  getAcquisitionTrend,
  getBattleTrend,
  getDungeonTrend,
  getGambleTrend,
  getGameplayTrend,
  getHealthTrend,
  getNutritionTrend,
  getStreakTrend,
} from "../db/repositories/trendsRepo";

export const trendsRouter = Router();
trendsRouter.use(requirePlayerId);

// Aggregate reads are cheap but not free, and a chart that repaints on scroll
// should not be able to hammer the replica.
trendsRouter.use(
  rateLimitByPlayer({
    windowMs: 60_000,
    max: 120,
    keyPrefix: "trends",
    message: "Too many trend requests",
  })
);

const windowSchema = z.object({
  hours: z.coerce.number().int().positive().max(24 * 90).optional(),
});

interface Envelope<T> {
  available: boolean;
  source: "replica" | "primary" | "none";
  points: T[];
}

function unavailable<T>(): Envelope<T> {
  return { available: false, source: "none", points: [] };
}

function envelope<T>(points: T[]): Envelope<T> {
  return { available: true, source: hasReadReplica() ? "replica" : "primary", points };
}

/** Wraps a trend handler: validates the window, short-circuits when Postgres
 *  is not configured, and turns a repo rejection into a 503 rather than a 500 --
 *  the aggregate being briefly unreachable is an availability problem, not a bug
 *  in the request. */
function trendRoute<T>(
  load: (playerId: string, hours: number | undefined) => Promise<T[]>
) {
  return async (req: PlayerRequest, res: import("express").Response): Promise<void> => {
    const parsed = windowSchema.safeParse(req.query);
    if (!parsed.success) {
      res.status(400).json({
        error: { code: "INVALID_WINDOW", message: "hours must be a positive integer up to 2160" },
      });
      return;
    }
    if (!hasDatabaseUrl()) {
      res.json(unavailable<T>());
      return;
    }
    try {
      const points = await load(req.playerId!, parsed.data.hours);
      res.json(envelope(points));
    } catch (err) {
      console.warn(`[trends] ${req.path} unavailable: ${(err as Error).message}`);
      res.status(503).json({
        error: { code: "TRENDS_UNAVAILABLE", message: "Trend data is temporarily unavailable" },
      });
    }
  };
}

// GET /trends/casino -- hourly wagered / net swing / wins per game mode.
// The series behind the casino luck chart.
trendsRouter.get(
  "/casino",
  trendRoute((playerId, hours) => getGambleTrend(playerId, hours ?? 72))
);

// GET /trends/nutrition -- hourly netted intake.
trendsRouter.get(
  "/nutrition",
  trendRoute((playerId, hours) => getNutritionTrend(playerId, hours ?? 24 * 7))
);

// GET /trends/battles -- hourly battles, wins, damage by mode.
trendsRouter.get(
  "/battles",
  trendRoute((playerId, hours) => getBattleTrend(playerId, hours ?? 24 * 14))
);

// GET /trends/gameplay -- hourly counts per event type.
trendsRouter.get(
  "/gameplay",
  trendRoute((playerId, hours) => getGameplayTrend(playerId, hours ?? 24 * 7))
);

// GET /trends/streak -- daily consistency history (0020).
trendsRouter.get(
  "/streak",
  trendRoute((playerId, hours) => getStreakTrend(playerId, hours ?? 24 * 90))
);

// GET /trends/pulls -- rarity mix over time, i.e. how the luck has run (0020).
trendsRouter.get(
  "/pulls",
  trendRoute((playerId, hours) => getAcquisitionTrend(playerId, hours ?? 24 * 30))
);

// GET /trends/dungeon -- daily deepest floor and clear rate (0020).
trendsRouter.get(
  "/dungeon",
  trendRoute((playerId, hours) => getDungeonTrend(playerId, hours ?? 24 * 30))
);

// GET /trends/health?metric=heart_rate -- hourly min/max/avg for one metric.
const healthSchema = windowSchema.extend({
  metric: z.string().regex(/^[a-z_]{2,32}$/).default("heart_rate"),
});

trendsRouter.get("/health", async (req: PlayerRequest, res) => {
  const parsed = healthSchema.safeParse(req.query);
  if (!parsed.success) {
    res.status(400).json({
      error: { code: "INVALID_QUERY", message: "metric must be a lowercase identifier" },
    });
    return;
  }
  if (!hasDatabaseUrl()) {
    res.json(unavailable());
    return;
  }
  try {
    const points = await getHealthTrend(
      req.playerId!,
      parsed.data.metric,
      parsed.data.hours ?? 24
    );
    res.json(envelope(points));
  } catch (err) {
    console.warn(`[trends] /health unavailable: ${(err as Error).message}`);
    res.status(503).json({
      error: { code: "TRENDS_UNAVAILABLE", message: "Trend data is temporarily unavailable" },
    });
  }
});
