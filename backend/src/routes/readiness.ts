// Readiness probe for the Tiger Cloud database.
//
// /health stays a liveness check (process is up). /ready reports whether the
// TigerData store is actually usable: TLS connect works, the TimescaleDB
// extension is present, the six hypertables exist, and migrations have run.
// Returns 503 (not 500) when not ready, so orchestrators can gate traffic.
import { Router } from "express";
import { asyncHandler } from "../http/asyncHandler";
import { getPool, hasDatabaseUrl } from "../db/pg";

export const readinessRouter = Router();

readinessRouter.get(
  "/ready",
  asyncHandler(async (_req, res) => {
    if (!hasDatabaseUrl()) {
      // Expected while the app still runs on SQLite and no Tiger Cloud URL is set.
      return res.status(503).json({ ready: false, reason: "DATABASE_URL not set" });
    }
    try {
      const pool = getPool();
      const ext = await pool.query<{ extversion: string }>(
        "select extversion from pg_extension where extname = 'timescaledb'"
      );
      const hyper = await pool.query<{ n: number }>(
        "select count(*)::int as n from timescaledb_information.hypertables"
      );
      const migr = await pool.query<{ n: number; latest: string | null }>(
        "select count(*)::int as n, max(version) as latest from ops.schema_migrations"
      );
      const timescale = ext.rows[0]?.extversion ?? null;
      const hypertables = hyper.rows[0]?.n ?? 0;
      const ready = Boolean(timescale) && hypertables >= 6;
      return res.status(ready ? 200 : 503).json({
        ready,
        timescale,
        hypertables,
        migrations: migr.rows[0]?.n ?? 0,
        latestMigration: migr.rows[0]?.latest ?? null,
      });
    } catch (err) {
      return res.status(503).json({ ready: false, reason: (err as Error).message });
    }
  })
);
