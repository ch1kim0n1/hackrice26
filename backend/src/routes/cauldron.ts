// Cauldron Crash — the wagering surface.
//
// Thin by design (docs/CONVENTIONS.md): every decision that matters happens in
// services/cauldronState.ts and services/cauldronEngine.ts. What lives here is
// validation, and the rule that a round in flight never tells the client where
// it is going to crash.

import { Router } from "express";
import { z } from "zod";
import {
  HOUSE_EDGE,
  MAX_WAGER_MONSTERS,
  MIN_WAGER_MONSTERS,
  MULTIPLIER_GROWTH_RATE,
  VISUAL_INTENSITY_THRESHOLDS
} from "../data/cauldron";
import { RARITY_BANDS, STAR_BONUS } from "../game/rarityBands";
import { RARITY_ORDER, RARITY_TIERS } from "../data/lootTable";
import { PlayerRequest, requirePlayerId } from "../middleware/player";
import { rateLimitByPlayer } from "../middleware/security";
import { intensityFor, rarityForValue } from "../services/cauldronEngine";
import {
  CAULDRON_ERRORS,
  CauldronRound,
  activeRound,
  cashOut,
  liveMultiplier,
  recentRounds,
  startRound
} from "../services/cauldronState";
import { StoredDrop, stateFor } from "../services/lootboxState";
import { characterPayload } from "./lootbox";
import { hasDatabaseUrl } from "../db/pg";
import { enqueueMirror } from "../services/mirrorQueue";

export const cauldronRouter = Router();
cauldronRouter.use(requirePlayerId);

const startRoundSchema = z.object({
  dropIds: z
    .array(z.string().min(1).max(64))
    .min(MIN_WAGER_MONSTERS)
    .max(MAX_WAGER_MONSTERS)
});

/** Operational failures -> status codes. Anything else is a genuine 500. */
const ERROR_STATUS: Record<string, number> = {
  [CAULDRON_ERRORS.WAGER_SIZE]: 400,
  [CAULDRON_ERRORS.WAGER_UNAVAILABLE]: 409,
  [CAULDRON_ERRORS.ROUND_IN_PROGRESS]: 409,
  [CAULDRON_ERRORS.ROUND_NOT_FOUND]: 404
};

const ERROR_MESSAGE: Record<string, string> = {
  [CAULDRON_ERRORS.WAGER_SIZE]: `A wager is ${MIN_WAGER_MONSTERS}-${MAX_WAGER_MONSTERS} monsters.`,
  [CAULDRON_ERRORS.WAGER_UNAVAILABLE]:
    "One of those monsters is no longer yours to wager. Refresh your collection.",
  [CAULDRON_ERRORS.ROUND_IN_PROGRESS]: "You already have a cauldron bubbling.",
  [CAULDRON_ERRORS.ROUND_NOT_FOUND]: "No such round."
};

/** A wagered or owned monster, with the presentational bits the UI needs. */
function monsterPayload(drop: StoredDrop) {
  return {
    id: drop.id,
    character: characterPayload(drop.character.id, drop.character),
    baseMintValue: drop.baseMintValue,
    stars: drop.stars ?? 1,
    /** This monster's net worth — what it contributes to the pot. */
    netWorth: drop.value,
    acquiredAt: drop.openedAt
  };
}

/**
 * A round as the client is allowed to see it.
 *
 * While the round is ACTIVE this deliberately omits `crashMultiplier`: the
 * whole game is that nobody knows it yet, and a field the UI never reads is
 * still a field a proxy can. It is disclosed once the round is over, which is
 * when knowing how close you came is the point.
 */
function roundPayload(round: CauldronRound, now = Date.now()) {
  const live = round.status === "ACTIVE";
  const multiplier = live ? liveMultiplier(round, now) : round.cashOutMultiplier ?? round.crashMultiplier;
  const netWorth = live
    ? Math.floor(round.startingNetWorth * multiplier)
    : round.finalNetWorth ?? round.startingNetWorth;

  return {
    roundId: round.roundId,
    status: round.status,
    startedAt: round.startedAt,
    /** The server's clock, so the client can animate against it rather than
     *  against a device clock that may be minutes off. */
    serverTime: new Date(now).toISOString(),
    wager: round.wager.map(monsterPayload),
    startingNetWorth: round.startingNetWorth,
    startingRarity: rarityForValue(round.startingNetWorth),
    multiplier,
    netWorth,
    rarity: rarityForValue(netWorth),
    intensity: intensityFor(multiplier),
    growthRate: MULTIPLIER_GROWTH_RATE,
    fairness: round.fairness,
    ...(live
      ? {}
      : {
          crashMultiplier: round.crashMultiplier,
          cashOutMultiplier: round.cashOutMultiplier,
          finalNetWorth: round.finalNetWorth,
          lostNetWorth: round.status === "CRASHED" ? round.startingNetWorth : 0,
          reward: round.reward
            ? { ...monsterPayload(round.reward), budget: round.reward.budget }
            : null,
          completedAt: round.completedAt
        })
  };
}

// GET /cauldron/config -- the published rules: edge, wager limits, brackets.
cauldronRouter.get("/config", (_req, res) => {
  res.json({
    houseEdge: HOUSE_EDGE,
    minWagerMonsters: MIN_WAGER_MONSTERS,
    maxWagerMonsters: MAX_WAGER_MONSTERS,
    growthRate: MULTIPLIER_GROWTH_RATE,
    intensityThresholds: VISUAL_INTENSITY_THRESHOLDS,
    rarityRanges: RARITY_ORDER.map((rarity) => ({
      rarity,
      label: RARITY_TIERS[rarity].label,
      colorHex: RARITY_TIERS[rarity].colorHex,
      min: RARITY_BANDS[rarity].min,
      // JSON has no Infinity; the top bracket is open-ended.
      max: Number.isFinite(RARITY_BANDS[rarity].max) ? RARITY_BANDS[rarity].max : null,
      // Published so the UI can explain what mastery is worth without
      // re-deriving the star economy client-side.
      starBonuses: STAR_BONUS[rarity]
    })),
    survivalOdds: [1.1, 1.25, 1.5, 2, 3, 5, 10, 20, 50, 100].map((multiplier) => ({
      multiplier,
      chance: (1 - HOUSE_EDGE) / multiplier
    })),
    howItWorks:
      "P(round reaches x) = (1 - houseEdge) / x. The crash point is drawn from " +
      "HMAC_SHA256(serverSeed, `${clientSeed}:${nonce}:40`) whose hash was published " +
      "before the round, and depends on nothing about you, your wager, or your history."
  });
});

// GET /cauldron/state -- the live round (if any) plus what you can wager.
// Also the reconnect path: a round that crashed while the app was closed is
// settled here and comes back as CRASHED.
cauldronRouter.get("/state", (req, res) => {
  const playerId = (req as PlayerRequest).playerId!;
  const now = Date.now();
  const round = activeRound(playerId, now);
  const session = stateFor(playerId);

  // Nothing live: surface the last finished round so a client returning from
  // the background still learns how it ended.
  const lastFinished = round ? null : recentRounds(playerId, 1)[0] ?? null;

  res.json({
    round: round ? roundPayload(round, now) : null,
    lastRound: lastFinished ? roundPayload(lastFinished, now) : null,
    // Staked monsters are owned but not wagerable — escrow holds them (#116).
    wagerable: session.inventory
      .filter((d) => !d.lockedBy)
      .slice()
      .reverse()
      .map(monsterPayload),
    serverTime: new Date(now).toISOString()
  });
});

// GET /cauldron/history -- finished rounds, newest first.
cauldronRouter.get("/history", (req, res) => {
  const requested = Number(req.query.limit ?? 20);
  if (!Number.isInteger(requested) || requested < 1 || requested > 100) {
    return res.status(400).json({ error: { code: "BAD_LIMIT", message: "limit must be an integer between 1 and 100." } });
  }
  const now = Date.now();
  const rounds = recentRounds((req as PlayerRequest).playerId!, requested)
    .filter((round) => round.status !== "ACTIVE")
    .map((round) => roundPayload(round, now));
  return res.json({ rounds });
});

// POST /cauldron/rounds -- lock 1-3 monsters in and start the multiplier.
cauldronRouter.post(
  "/rounds",
  rateLimitByPlayer({ windowMs: 60_000, max: 30, keyPrefix: "cauldron", message: "Too many cauldron rounds. Try again later." }),
  (req, res) => {
    const parsed = startRoundSchema.safeParse(req.body);
    if (!parsed.success) {
      return res.status(400).json({
        error: {
          code: "BAD_WAGER",
          message: `dropIds must be ${MIN_WAGER_MONSTERS}-${MAX_WAGER_MONSTERS} owned monster ids.`
        }
      });
    }

    try {
      const round = startRound((req as PlayerRequest).playerId!, parsed.data.dropIds);
      if (hasDatabaseUrl()) {
        enqueueMirror("cauldron_round", round.roundId, round);
      }
      return res.status(201).json({ round: roundPayload(round) });
    } catch (err) {
      return failure(res, err);
    }
  }
);

// POST /cauldron/rounds/:id/cashout -- take the multiplier, if it is still
// there to take. The server prices this off its own clock.
cauldronRouter.post("/rounds/:id/cashout", (req, res) => {
  try {
    const round = cashOut((req as PlayerRequest).playerId!, req.params.id);
    if (hasDatabaseUrl()) {
      enqueueMirror("cauldron_round", round.roundId, round);
    }
    return res.json({ round: roundPayload(round) });
  } catch (err) {
    return failure(res, err);
  }
});

// GET /cauldron/rounds/:id -- one round, for a client that lost its place.
cauldronRouter.get("/rounds/:id", (req, res) => {
  const playerId = (req as PlayerRequest).playerId!;
  const round = recentRounds(playerId, 100).find((candidate) => candidate.roundId === req.params.id);
  if (!round) {
    return res.status(404).json({ error: { code: CAULDRON_ERRORS.ROUND_NOT_FOUND, message: ERROR_MESSAGE[CAULDRON_ERRORS.ROUND_NOT_FOUND] } });
  }
  return res.json({ round: roundPayload(round) });
});

function failure(res: import("express").Response, err: unknown) {
  const code = err instanceof Error ? err.message : "INTERNAL";
  const status = ERROR_STATUS[code];
  if (!status) throw err;
  return res.status(status).json({ error: { code, message: ERROR_MESSAGE[code] ?? code } });
}
