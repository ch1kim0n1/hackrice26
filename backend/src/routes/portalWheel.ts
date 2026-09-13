// Portal Wheel — the wagering surface.
//
// Thin by design (docs/CONVENTIONS.md). One POST resolves an entire round, so
// there is no live state to guard and nothing to withhold: the winning section
// is sent with the result precisely so the client can spin the wheel to the
// wedge the server already chose.
//
// Everything published here — section counts, probabilities, multipliers — is
// derived from the layout in data/portalWheel.ts rather than restated, because
// a help table that can drift from the wheel is a help table that will.

import { Router } from "express";
import { z } from "zod";
import {
  HOUSE_EDGE,
  PORTAL_COLORS,
  PORTAL_PALETTE,
  SECTION_LAYOUT,
  TOTAL_SECTIONS,
  WAGER_MONSTERS
} from "../data/portalWheel";
import { RARITY_ORDER, RARITY_TIERS } from "../data/lootTable";
import { RARITY_BANDS, rarityForValue } from "../game/rarityBands";
import { PlayerRequest, requirePlayerId } from "../middleware/player";
import { rateLimitByPlayer } from "../middleware/security";
import { oddsTable, worstHouseEdge } from "../services/portalWheelEngine";
import {
  PORTAL_WHEEL_ERRORS,
  PortalWheelSpin,
  recentSpins,
  spin
} from "../services/portalWheelState";
import { StoredDrop, stateFor } from "../services/lootboxState";
import { characterPayload } from "./lootbox";
import { hasDatabaseUrl } from "../db/pg";
import { enqueueMirror } from "../services/mirrorQueue";

export const portalWheelRouter = Router();
portalWheelRouter.use(requirePlayerId);

const spinSchema = z.object({
  dropId: z.string().min(1).max(64),
  // The colour is committed with the wager. There is no later request that
  // could change it, which is what "locked once SPIN is pressed" means here.
  color: z.enum(["blue", "red", "yellow", "green"])
});

const ERROR_STATUS: Record<string, number> = {
  [PORTAL_WHEEL_ERRORS.WAGER_UNAVAILABLE]: 409,
  [PORTAL_WHEEL_ERRORS.BAD_COLOR]: 400,
  [PORTAL_WHEEL_ERRORS.SPIN_NOT_FOUND]: 404
};

const ERROR_MESSAGE: Record<string, string> = {
  [PORTAL_WHEEL_ERRORS.WAGER_UNAVAILABLE]:
    "That monster is no longer yours to wager. Refresh your collection.",
  [PORTAL_WHEEL_ERRORS.BAD_COLOR]: "Pick one of the four portal colours.",
  [PORTAL_WHEEL_ERRORS.SPIN_NOT_FOUND]: "No such spin."
};

function monsterPayload(monster: StoredDrop) {
  return {
    id: monster.id,
    character: characterPayload(monster.character.id, monster.character),
    baseMintValue: monster.baseMintValue,
    stars: monster.stars ?? 1,
    netWorth: monster.value,
    acquiredAt: monster.openedAt
  };
}

/**
 * A resolved spin.
 *
 * `section` is included deliberately: the client needs the exact wedge to stop
 * the pointer on. Sending the section rather than only the colour is what stops
 * the animation and the outcome from being two different things — a colour
 * alone would leave the wheel free to stop on any of that colour's wedges, and
 * an animation with that much latitude is no longer a rendering of the result.
 */
function spinPayload(resolved: PortalWheelSpin) {
  return {
    spinId: resolved.spinId,
    wager: monsterPayload(resolved.wager),
    wagerValue: resolved.wagerValue,
    pick: resolved.pick,
    section: resolved.section,
    winningColor: resolved.winningColor,
    won: resolved.won,
    /** What the chosen colour was quoted at. Paid only on a win. */
    multiplier: resolved.multiplier,
    finalNetWorth: resolved.finalNetWorth,
    rarity: resolved.finalNetWorth > 0 ? rarityForValue(resolved.finalNetWorth) : null,
    reward: resolved.reward
      ? { ...monsterPayload(resolved.reward), budget: resolved.reward.budget }
      : null,
    createdAt: resolved.createdAt,
    fairness: resolved.fairness
  };
}

// GET /portal-wheel/config -- the wheel, the odds and the real edge.
portalWheelRouter.get("/config", (_req, res) => {
  res.json({
    houseEdge: HOUSE_EDGE,
    /** The worst edge any single colour charges, once payouts are floored. */
    worstHouseEdge: worstHouseEdge(),
    totalSections: TOTAL_SECTIONS,
    wagerMonsters: WAGER_MONSTERS,
    /** The wheel itself, clockwise from the pointer. The client draws this. */
    layout: SECTION_LAYOUT,
    colors: oddsTable().map((entry) => ({
      ...entry,
      label: PORTAL_PALETTE[entry.color].label,
      colorHex: PORTAL_PALETTE[entry.color].colorHex
    })),
    rarityRanges: RARITY_ORDER.map((rarity) => ({
      rarity,
      label: RARITY_TIERS[rarity].label,
      colorHex: RARITY_TIERS[rarity].colorHex,
      min: RARITY_BANDS[rarity].min,
      max: Number.isFinite(RARITY_BANDS[rarity].max) ? RARITY_BANDS[rarity].max : null
    })),
    howItWorks:
      `The wheel has ${TOTAL_SECTIONS} equal sections and the four colours own different numbers ` +
      "of them, so a colour's chance is simply its share of the rim: P = sections / total. " +
      `The payout is (1 - houseEdge) / P, which is why the rarest colour pays the most. The ` +
      "winning section is drawn from a server seed whose hash was published beforehand, and it " +
      "depends on nothing about you, your monster, or the colour you picked."
  });
});

// GET /portal-wheel/state -- the bank, plus recent spins for the history strip.
portalWheelRouter.get("/state", (req, res) => {
  const playerId = (req as PlayerRequest).playerId!;
  const session = stateFor(playerId);
  const history = recentSpins(playerId, 10);

  res.json({
    wagerable: session.inventory.slice().reverse().map(monsterPayload),
    lastSpin: history[0] ? spinPayload(history[0]) : null,
    recent: history.map((entry) => ({
      spinId: entry.spinId,
      pick: entry.pick,
      winningColor: entry.winningColor,
      won: entry.won,
      multiplier: entry.multiplier,
      finalNetWorth: entry.finalNetWorth,
      createdAt: entry.createdAt
    })),
    serverTime: new Date().toISOString()
  });
});

// POST /portal-wheel/spins -- commit one monster to one colour and spin.
// Resolves entirely server-side before it answers; the client animates what
// comes back.
portalWheelRouter.post(
  "/spins",
  rateLimitByPlayer({
    windowMs: 60_000,
    max: 60,
    keyPrefix: "portal-wheel",
    message: "Too many spins. Try again later."
  }),
  (req, res) => {
    const parsed = spinSchema.safeParse(req.body);
    if (!parsed.success) {
      return res.status(400).json({
        error: {
          code: "BAD_WAGER",
          message: `Send the id of a monster you own and one of: ${PORTAL_COLORS.join(", ")}.`
        }
      });
    }
    try {
      const resolved = spin(
        (req as PlayerRequest).playerId!,
        parsed.data.dropId,
        parsed.data.color
      );
      if (hasDatabaseUrl()) {
        enqueueMirror("portal_wheel_spin", resolved.spinId, resolved);
      }
      return res.status(201).json({ spin: spinPayload(resolved) });
    } catch (err) {
      return failure(res, err);
    }
  }
);

// GET /portal-wheel/history -- past spins, newest first.
portalWheelRouter.get("/history", (req, res) => {
  const requested = Number(req.query.limit ?? 20);
  if (!Number.isInteger(requested) || requested < 1 || requested > 100) {
    return res
      .status(400)
      .json({ error: { code: "BAD_LIMIT", message: "limit must be an integer between 1 and 100." } });
  }
  return res.json({
    spins: recentSpins((req as PlayerRequest).playerId!, requested).map(spinPayload)
  });
});

function failure(res: import("express").Response, err: unknown) {
  const code = err instanceof Error ? err.message : "INTERNAL";
  const status = ERROR_STATUS[code];
  if (!status) throw err;
  return res.status(status).json({ error: { code, message: ERROR_MESSAGE[code] ?? code } });
}
