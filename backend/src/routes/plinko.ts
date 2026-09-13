// Plinko — the wagering surface.
//
// Thin by design. One POST resolves an entire round, so there is no live
// state to guard and nothing to withhold: the path is sent with the result
// precisely so the client can animate the outcome the server already decided.

import { Router } from "express";
import { z } from "zod";
import {
  HOUSE_EDGE,
  PEG_ROWS,
  SLOT_COUNT,
  SLOT_MULTIPLIERS,
  TOTAL_PATHS,
  slotTier
} from "../data/plinko";
import { RARITY_ORDER, RARITY_TIERS } from "../data/lootTable";
import { RARITY_BANDS, rarityForValue } from "../game/rarityBands";
import { PlayerRequest, requirePlayerId } from "../middleware/player";
import { rateLimitByPlayer } from "../middleware/security";
import { actualHouseEdge, expectedMultiplier, payoutTable } from "../services/plinkoEngine";
import { PLINKO_ERRORS, PlinkoDrop, drop, recentDrops } from "../services/plinkoState";
import { StoredDrop, stateFor } from "../services/lootboxState";
import { characterPayload } from "./lootbox";
import { hasDatabaseUrl } from "../db/pg";
import { enqueueMirror } from "../services/mirrorQueue";

export const plinkoRouter = Router();
plinkoRouter.use(requirePlayerId);

const dropSchema = z.object({
  dropId: z.string().min(1).max(64)
});

const ERROR_STATUS: Record<string, number> = {
  [PLINKO_ERRORS.WAGER_UNAVAILABLE]: 409,
  [PLINKO_ERRORS.DROP_NOT_FOUND]: 404
};

const ERROR_MESSAGE: Record<string, string> = {
  [PLINKO_ERRORS.WAGER_UNAVAILABLE]:
    "That monster is no longer yours to wager. Refresh your collection.",
  [PLINKO_ERRORS.DROP_NOT_FOUND]: "No such drop."
};

function monsterPayload(monster: StoredDrop) {
  return {
    id: monster.id,
    character: characterPayload(monster.character.id, monster.character),
    power: monster.power,
    powerLabel: monster.powerLabel,
    shiny: monster.shiny,
    stars: monster.stars ?? 1,
    netWorth: monster.value,
    acquiredAt: monster.openedAt
  };
}

/**
 * A resolved drop.
 *
 * `path` is included deliberately: the client needs it to draw the orb
 * bouncing to the slot the server already chose. Sending the route rather than
 * only the destination is what stops the animation and the outcome from being
 * two different things.
 */
function dropPayload(resolved: PlinkoDrop) {
  return {
    dropId: resolved.dropId,
    wager: monsterPayload(resolved.wager),
    wagerValue: resolved.wagerValue,
    path: resolved.path,
    slot: resolved.slot,
    multiplier: resolved.multiplier,
    tier: slotTier(resolved.multiplier),
    finalNetWorth: resolved.finalNetWorth,
    rarity: resolved.finalNetWorth > 0 ? rarityForValue(resolved.finalNetWorth) : null,
    busted: resolved.multiplier === 0,
    reward: resolved.reward
      ? { ...monsterPayload(resolved.reward), budget: resolved.reward.budget }
      : null,
    createdAt: resolved.createdAt,
    fairness: resolved.fairness
  };
}

// GET /plinko/config -- the board, the payout table, and the real odds.
plinkoRouter.get("/config", (_req, res) => {
  res.json({
    houseEdge: HOUSE_EDGE,
    /** What the board actually charges, given the table below. */
    actualHouseEdge: actualHouseEdge(),
    expectedMultiplier: expectedMultiplier(),
    pegRows: PEG_ROWS,
    slotCount: SLOT_COUNT,
    totalPaths: TOTAL_PATHS,
    multipliers: SLOT_MULTIPLIERS,
    slots: payoutTable().map((entry) => ({
      ...entry,
      tier: slotTier(entry.multiplier)
    })),
    rarityRanges: RARITY_ORDER.map((rarity) => ({
      rarity,
      label: RARITY_TIERS[rarity].label,
      colorHex: RARITY_TIERS[rarity].colorHex,
      min: RARITY_BANDS[rarity].min,
      max: Number.isFinite(RARITY_BANDS[rarity].max) ? RARITY_BANDS[rarity].max : null
    })),
    howItWorks:
      "Twelve peg rows, thirteen slots. Each row is one left/right decision, so a drop " +
      "is twelve coin flips and the slot is how many went right: P(slot k) = C(12, k) / 4096. " +
      "Centre slots are common and pay least; the edges are one path in 4096. The whole " +
      "table is weighted to pay back about 95%."
  });
});

// GET /plinko/state -- the bank, plus recent drops for the history strip.
plinkoRouter.get("/state", (req, res) => {
  const playerId = (req as PlayerRequest).playerId!;
  const session = stateFor(playerId);
  const history = recentDrops(playerId, 10);

  res.json({
    wagerable: session.inventory.slice().reverse().map(monsterPayload),
    lastDrop: history[0] ? dropPayload(history[0]) : null,
    recent: history.map((entry) => ({
      dropId: entry.dropId,
      slot: entry.slot,
      multiplier: entry.multiplier,
      finalNetWorth: entry.finalNetWorth,
      createdAt: entry.createdAt
    })),
    serverTime: new Date().toISOString()
  });
});

// POST /plinko/drops -- spend one monster and drop the orb. Resolves entirely
// server-side before it answers; the client animates what comes back.
plinkoRouter.post(
  "/drops",
  rateLimitByPlayer({ windowMs: 60_000, max: 60, keyPrefix: "plinko", message: "Too many drops. Try again later." }),
  (req, res) => {
    const parsed = dropSchema.safeParse(req.body);
    if (!parsed.success) {
      return res.status(400).json({
        error: { code: "BAD_WAGER", message: "Send the id of a monster you own." }
      });
    }
    try {
      const resolved = drop((req as PlayerRequest).playerId!, parsed.data.dropId);
      if (hasDatabaseUrl()) {
        enqueueMirror("plinko_drop", resolved.dropId, resolved);
      }
      return res.status(201).json({ drop: dropPayload(resolved) });
    } catch (err) {
      return failure(res, err);
    }
  }
);

// GET /plinko/history -- past drops, newest first.
plinkoRouter.get("/history", (req, res) => {
  const requested = Number(req.query.limit ?? 20);
  if (!Number.isInteger(requested) || requested < 1 || requested > 100) {
    return res.status(400).json({ error: { code: "BAD_LIMIT", message: "limit must be an integer between 1 and 100." } });
  }
  return res.json({
    drops: recentDrops((req as PlayerRequest).playerId!, requested).map(dropPayload)
  });
});

function failure(res: import("express").Response, err: unknown) {
  const code = err instanceof Error ? err.message : "INTERNAL";
  const status = ERROR_STATUS[code];
  if (!status) throw err;
  return res.status(status).json({ error: { code, message: ERROR_MESSAGE[code] ?? code } });
}
