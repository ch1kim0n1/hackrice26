// Per-player rate-limit presets for the Postgres-backed game routes
// (docs/SECURITY.md §Rate limits, issue #12). Built on the existing
// rateLimitByPlayer store so limits are per authenticated player. Mount these
// on the corresponding routes; each returns 429 with Retry-After when tripped.
//
//   60 req/min global · /scan 30/day · /gym-check 1/day
//   /capsules/open 10/day · /battles/ranked 20/day

import { rateLimitByPlayer } from "../middleware/security";

const DAY = 24 * 60 * 60 * 1000;
const MIN = 60 * 1000;

export const globalLimit = rateLimitByPlayer({
  windowMs: MIN,
  max: 60,
  keyPrefix: "global",
  message: "Global rate limit exceeded (60/min)"
});

export const scanLimit = rateLimitByPlayer({
  windowMs: DAY,
  max: 30,
  keyPrefix: "scan",
  message: "Daily scan limit reached (30/day)"
});

export const gymCheckLimit = rateLimitByPlayer({
  windowMs: DAY,
  max: 1,
  keyPrefix: "gym",
  message: "Gym check already used today (1/day)"
});

export const capsuleOpenLimit = rateLimitByPlayer({
  windowMs: DAY,
  max: 10,
  keyPrefix: "capsule-open",
  message: "Daily capsule-open limit reached (10/day)"
});

export const rankedBattleLimit = rateLimitByPlayer({
  windowMs: DAY,
  max: 20,
  keyPrefix: "ranked",
  message: "Daily ranked battle limit reached (20/day)"
});
