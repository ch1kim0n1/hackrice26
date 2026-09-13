// Kitchen Mines — the wagering surface.
//
// Thin by design (docs/CONVENTIONS.md). The one rule that lives here rather
// than in the service: a live round never tells the client where the mines
// are. `publicRound()` is the only shape that reaches a player, and it omits
// the layout until the round is over.

import { Router } from "express";
import { z } from "zod";
import {
  HEAT_THRESHOLDS,
  HOUSE_EDGE,
  MAX_MINES,
  MINE_PRESETS,
  MIN_MINES,
  TILE_COUNT,
  BOARD_ROWS,
  BOARD_COLUMNS
} from "../data/mines";
import { RARITY_ORDER, RARITY_TIERS } from "../data/lootTable";
import { RARITY_BANDS } from "../game/rarityBands";
import { PlayerRequest, requirePlayerId } from "../middleware/player";
import { rateLimitByPlayer } from "../middleware/security";
import {
  heatFor,
  multiplierAfter,
  nextMultiplier,
  nextPickSafeChance,
  potValue,
  safeTiles,
  survivalProbability
} from "../services/minesEngine";
import { rarityForValue } from "../game/rarityBands";
import {
  MINES_ERRORS,
  MinesRound,
  activeRound,
  cashOut,
  currentMultiplier,
  isBoardCleared,
  recentRounds,
  reveal,
  startRound
} from "../services/minesState";
import { StoredDrop, stateFor } from "../services/lootboxState";
import { characterPayload } from "./lootbox";
import { hasDatabaseUrl } from "../db/pg";
import { enqueueMirror } from "../services/mirrorQueue";

export const minesRouter = Router();
minesRouter.use(requirePlayerId);

const startSchema = z.object({
  dropId: z.string().min(1).max(64),
  mines: z.number().int().min(MIN_MINES).max(MAX_MINES)
});

const revealSchema = z.object({
  tile: z.number().int().min(0).max(TILE_COUNT - 1)
});

const ERROR_STATUS: Record<string, number> = {
  [MINES_ERRORS.MINE_COUNT]: 400,
  [MINES_ERRORS.BAD_TILE]: 400,
  [MINES_ERRORS.WAGER_UNAVAILABLE]: 409,
  [MINES_ERRORS.ROUND_IN_PROGRESS]: 409,
  [MINES_ERRORS.ROUND_OVER]: 409,
  [MINES_ERRORS.TILE_ALREADY_REVEALED]: 409,
  [MINES_ERRORS.ROUND_NOT_FOUND]: 404
};

const ERROR_MESSAGE: Record<string, string> = {
  [MINES_ERRORS.MINE_COUNT]: `Pick between ${MIN_MINES} and ${MAX_MINES} burnt dishes.`,
  [MINES_ERRORS.BAD_TILE]: "That dish is not on the board.",
  [MINES_ERRORS.WAGER_UNAVAILABLE]: "That monster is no longer yours to wager. Refresh your collection.",
  [MINES_ERRORS.ROUND_IN_PROGRESS]: "You already have a board on the go.",
  [MINES_ERRORS.ROUND_OVER]: "That round is already finished.",
  [MINES_ERRORS.TILE_ALREADY_REVEALED]: "That dish is already uncovered.",
  [MINES_ERRORS.ROUND_NOT_FOUND]: "No such round."
};

function monsterPayload(drop: StoredDrop) {
  return {
    id: drop.id,
    character: characterPayload(drop.character.id, drop.character),
    power: drop.power,
    powerLabel: drop.powerLabel,
    shiny: drop.shiny,
    stars: drop.stars ?? 1,
    netWorth: drop.value,
    acquiredAt: drop.openedAt
  };
}

/**
 * A round as the client is allowed to see it.
 *
 * `layout` is absent while the round is ACTIVE. That is the whole game: a
 * field the UI never reads is still a field a proxy can, so the server does
 * not send it until there is nothing left to protect.
 */
function publicRound(round: MinesRound, now = Date.now()) {
  const live = round.status === "ACTIVE";
  const picks = round.revealed.length;
  const multiplier = live ? currentMultiplier(round) : round.cashOutMultiplier ?? currentMultiplier(round);
  const netWorth = live ? potValue(round.wagerValue, multiplier) : round.finalNetWorth ?? 0;
  const upcoming = nextMultiplier(round.mines, picks);

  return {
    roundId: round.roundId,
    status: round.status,
    startedAt: round.startedAt,
    serverTime: new Date(now).toISOString(),
    wager: monsterPayload(round.wager),
    wagerValue: round.wagerValue,
    mines: round.mines,
    safeDishes: safeTiles(round.mines),
    revealed: round.revealed,
    picks,
    multiplier,
    netWorth,
    rarity: rarityForValue(netWorth),
    heat: heatFor(multiplier),
    cleared: isBoardCleared(round),
    /** What one more safe dish would be worth. Never says which dish. */
    next: upcoming === null
      ? null
      : {
          multiplier: upcoming,
          netWorth: potValue(round.wagerValue, upcoming),
          rarity: rarityForValue(potValue(round.wagerValue, upcoming)),
          safeChance: nextPickSafeChance(round.mines, picks)
        },
    fairness: round.fairness,
    ...(live
      ? {}
      : {
          // The board is only ever opened after the round is decided.
          layout: round.layout,
          cashOutMultiplier: round.cashOutMultiplier,
          finalNetWorth: round.finalNetWorth,
          lostNetWorth: round.status === "BURNT" ? round.wagerValue : 0,
          reward: round.reward
            ? { ...monsterPayload(round.reward), budget: round.reward.budget }
            : null,
          completedAt: round.completedAt
        })
  };
}

// GET /mines/config -- the published rules and the full payout table.
minesRouter.get("/config", (_req, res) => {
  res.json({
    houseEdge: HOUSE_EDGE,
    rows: BOARD_ROWS,
    columns: BOARD_COLUMNS,
    tileCount: TILE_COUNT,
    minMines: MIN_MINES,
    maxMines: MAX_MINES,
    minePresets: MINE_PRESETS,
    heatThresholds: HEAT_THRESHOLDS,
    rarityRanges: RARITY_ORDER.map((rarity) => ({
      rarity,
      label: RARITY_TIERS[rarity].label,
      colorHex: RARITY_TIERS[rarity].colorHex,
      min: RARITY_BANDS[rarity].min,
      max: Number.isFinite(RARITY_BANDS[rarity].max) ? RARITY_BANDS[rarity].max : null
    })),
    howItWorks:
      "Every multiplier is the real chance of having survived that many safe dishes: " +
      "P = C(safe, picks) / C(25, picks), and the payout is (1 - houseEdge) / P. " +
      "The board is laid before your first pick, from a server seed whose hash was " +
      "published beforehand, and it depends on nothing about you or your monster."
  });
});

// GET /mines/payouts?mines=5 -- the ladder for one board, so the UI can show
// the whole climb rather than one number at a time.
minesRouter.get("/payouts", (req, res) => {
  const mines = Number(req.query.mines ?? 5);
  if (!Number.isInteger(mines) || mines < MIN_MINES || mines > MAX_MINES) {
    return res.status(400).json({
      error: { code: MINES_ERRORS.MINE_COUNT, message: ERROR_MESSAGE[MINES_ERRORS.MINE_COUNT] }
    });
  }
  const rungs = [];
  for (let picks = 1; picks <= safeTiles(mines); picks++) {
    rungs.push({
      picks,
      multiplier: multiplierAfter(mines, picks),
      survivalChance: survivalProbability(mines, picks)
    });
  }
  return res.json({ mines, safeDishes: safeTiles(mines), rungs });
});

// GET /mines/state -- the live board (if any), the last result, and the bank.
minesRouter.get("/state", (req, res) => {
  const playerId = (req as PlayerRequest).playerId!;
  const now = Date.now();
  const round = activeRound(playerId, now);
  const session = stateFor(playerId);
  const lastFinished = round ? null : recentRounds(playerId, 1)[0] ?? null;

  res.json({
    round: round ? publicRound(round, now) : null,
    lastRound: lastFinished ? publicRound(lastFinished, now) : null,
    // Staked monsters are owned but not wagerable — escrow holds them (#116).
    wagerable: session.inventory.filter((d) => !d.lockedBy).slice().reverse().map(monsterPayload),
    serverTime: new Date(now).toISOString()
  });
});

// POST /mines/rounds -- commit one monster, lay the board, lock the mine count.
minesRouter.post(
  "/rounds",
  rateLimitByPlayer({ windowMs: 60_000, max: 40, keyPrefix: "mines", message: "Too many rounds. Try again later." }),
  (req, res) => {
    const parsed = startSchema.safeParse(req.body);
    if (!parsed.success) {
      return res.status(400).json({
        error: {
          code: "BAD_WAGER",
          message: `Send an owned monster id and a mine count between ${MIN_MINES} and ${MAX_MINES}.`
        }
      });
    }
    try {
      const round = startRound((req as PlayerRequest).playerId!, parsed.data.dropId, parsed.data.mines);
      if (hasDatabaseUrl()) {
        enqueueMirror("mines_round", round.roundId, round);
      }
      return res.status(201).json({ round: publicRound(round) });
    } catch (err) {
      return failure(res, err);
    }
  }
);

// POST /mines/rounds/:id/reveal -- lift one dish.
minesRouter.post("/rounds/:id/reveal", (req, res) => {
  const parsed = revealSchema.safeParse(req.body);
  if (!parsed.success) {
    return res.status(400).json({
      error: { code: MINES_ERRORS.BAD_TILE, message: ERROR_MESSAGE[MINES_ERRORS.BAD_TILE] }
    });
  }
  try {
    const result = reveal((req as PlayerRequest).playerId!, req.params.id, parsed.data.tile);
    if (hasDatabaseUrl()) {
      enqueueMirror("mines_round", result.round.roundId, result.round);
    }
    return res.json({
      tile: result.tile,
      safe: result.safe,
      round: publicRound(result.round)
    });
  } catch (err) {
    return failure(res, err);
  }
});

// POST /mines/rounds/:id/cashout -- serve the dish and take the monster.
minesRouter.post("/rounds/:id/cashout", (req, res) => {
  try {
    const round = cashOut((req as PlayerRequest).playerId!, req.params.id);
    if (hasDatabaseUrl()) {
      enqueueMirror("mines_round", round.roundId, round);
    }
    return res.json({ round: publicRound(round) });
  } catch (err) {
    return failure(res, err);
  }
});

// GET /mines/history -- finished boards, newest first.
minesRouter.get("/history", (req, res) => {
  const requested = Number(req.query.limit ?? 20);
  if (!Number.isInteger(requested) || requested < 1 || requested > 100) {
    return res.status(400).json({ error: { code: "BAD_LIMIT", message: "limit must be an integer between 1 and 100." } });
  }
  const now = Date.now();
  const rounds = recentRounds((req as PlayerRequest).playerId!, requested)
    .filter((round) => round.status !== "ACTIVE")
    .map((round) => publicRound(round, now));
  return res.json({ rounds });
});

function failure(res: import("express").Response, err: unknown) {
  const code = err instanceof Error ? err.message : "INTERNAL";
  const status = ERROR_STATUS[code];
  if (!status) throw err;
  return res.status(status).json({ error: { code, message: ERROR_MESSAGE[code] ?? code } });
}
