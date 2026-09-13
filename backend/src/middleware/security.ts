import { Request, Response, NextFunction } from "express";
import { PlayerRequest } from "./player";

// Per-player rate limiter. Stores are in-memory (resets on restart), which is
// acceptable for the hackathon backend. Keys are `playerId` + an optional
// prefix so different routes can have independent windows.

interface Bucket {
  resetAt: number;
  count: number;
}

export interface RateLimitOptions {
  windowMs: number;
  max: number;
  keyPrefix?: string;
  message?: string;
}

const buckets = new Map<string, Bucket>();

function cleanupBuckets() {
  const now = Date.now();
  for (const [key, bucket] of buckets) {
    if (bucket.resetAt < now) buckets.delete(key);
  }
}

// Trim stale buckets every 60s in production; skip in tests to avoid leaking
// timers across module resets.
if (!process.env.VITEST) {
  setInterval(cleanupBuckets, 60_000);
}

export function rateLimitByPlayer(options: RateLimitOptions) {
  const { windowMs, max, keyPrefix = "", message = "Too many requests" } = options;

  return (req: PlayerRequest, res: Response, next: NextFunction): void => {
    const playerId = req.playerId;
    if (!playerId) {
      // No player id -> no rate limit, but routes that use this middleware
      // already require `requirePlayerId`.
      next();
      return;
    }

    const now = Date.now();
    const key = `${keyPrefix}:${playerId}`;
    let bucket = buckets.get(key);

    if (!bucket || bucket.resetAt <= now) {
      bucket = { resetAt: now + windowMs, count: 1 };
      buckets.set(key, bucket);
      next();
      return;
    }

    bucket.count += 1;
    if (bucket.count > max) {
      res.setHeader("Retry-After", Math.ceil((bucket.resetAt - now) / 1000));
      res.status(429).json({
        error: {
          code: "RATE_LIMITED",
          message,
          retryAfter: Math.ceil((bucket.resetAt - now) / 1000)
        }
      });
      return;
    }

    next();
  };
}

/** IP-keyed rate limiter for pre-auth routes (register/login) where no
 *  player identity exists yet. Shares the same bucket store. */
export function rateLimit(options: RateLimitOptions) {
  const { windowMs, max, keyPrefix = "", message = "Too many requests" } = options;

  return (req: Request, res: Response, next: NextFunction): void => {
    const now = Date.now();
    const clientIp = req.ip ?? (req.socket ? String((req.socket as any).remoteAddress) : undefined) ?? "unknown";
    const key = `${keyPrefix}:${clientIp}`;
    let bucket = buckets.get(key);

    if (!bucket || bucket.resetAt <= now) {
      bucket = { resetAt: now + windowMs, count: 1 };
      buckets.set(key, bucket);
      next();
      return;
    }

    bucket.count += 1;
    if (bucket.count > max) {
      res.setHeader("Retry-After", Math.ceil((bucket.resetAt - now) / 1000));
      res.status(429).json({
        error: {
          code: "RATE_LIMITED",
          message,
          retryAfter: Math.ceil((bucket.resetAt - now) / 1000)
        }
      });
      return;
    }
    next();
  };
}

export function requireAdminToken(req: Request, res: Response, next: NextFunction): void {
  const token = req.headers["x-admin-token"];
  const adminToken = process.env.NUTRIQUEST_ADMIN_TOKEN;
  if (!adminToken) {
    res.status(503).json({
      error: { code: "ADMIN_ROUTES_DISABLED", message: "Admin operations are disabled on this server." }
    });
    return;
  }
  if (typeof token !== "string" || !token) {
    res.status(403).json({
      error: { code: "ADMIN_TOKEN_REQUIRED", message: "Admin token is required for this operation." }
    });
    return;
  }
  if (token !== adminToken) {
    res.status(403).json({
      error: { code: "ADMIN_TOKEN_INVALID", message: "Admin token is invalid." }
    });
    return;
  }
  next();
}

export function adminRoutesEnabled(): boolean {
  return !!process.env.NUTRIQUEST_ADMIN_TOKEN;
}
