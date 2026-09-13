import { Router } from "express";
import {
  COOKBOOKS,
  RARITY_ORDER,
  RARITY_TIERS
} from "../data/lootTable";
import { ROSTER, asCharacter, rosterCharacter } from "../data/roster";
import { db } from "../db";
import { hasDatabaseUrl } from "../db/pg";
import * as engine from "../services/lootboxEngine";
import {
  consumeCase,
  pendingCases,
  publicSeedPair,
  resetPlayer,
  stateFor
} from "../services/lootboxState";
import * as promo from "../services/promoCodes";
import { PlayerRequest, requirePlayerId } from "../middleware/player";
import { rateLimitByPlayer, requireAdminToken } from "../middleware/security";
import { Character, Cookbook, Rarity } from "../types";
import { enqueueMirror } from "../services/mirrorQueue";
import { COIN_ERRORS, coinBalance, recordCoinsInTransaction } from "../services/coins";
import { consumeCookbookBoost } from "./user";
import { ledger, transact } from "../services/characterMutations";
import {
  clientSeedBodySchema,
  mailboxClaimSchema,
  verifyOpenSchema
} from "../schemas/gameSchemas";

export const lootboxRouter = Router();

// Every lootbox route is scoped to the X-Player-Id caller.
lootboxRouter.use(requirePlayerId);

/**
 * Character plus the presentational bits the case UI needs.
 *
 * `fallback` covers a character that isn't in the gacha catalog at all — the
 * starter roster (lootboxState.ts seedStarterRoster) is a real owned drop
 * like any other, but was never rolled from CHARACTERS, so it isn't in it.
 * Every route reading a *stored* drop back already has that drop's own
 * embedded character data sitting right there and should pass it, so this
 * degrades instead of throwing on an id the catalog has never heard of.
 */
export function characterPayload(id: string, fallback?: Character) {
  const character = fallback ?? (rosterCharacter(id) ? asCharacter(rosterCharacter(id)!, "common") : undefined);
  if (!character) throw new Error(`Unknown character '${id}'`);
  const tier = RARITY_TIERS[character.rarity];
  return {
    ...character,
    rarityLabel: tier.label,
    rarityColorHex: tier.colorHex,
    flavor: rosterCharacter(id)?.tagline ?? character.tagline ?? ""
  };
}

function cookbookPayload(book: Cookbook, includeContents = false) {
  const payload: Record<string, unknown> = {
    id: book.id,
    name: book.name,
    description: book.description,
    price: book.price,
    odds: engine.cookbookOdds(book)
  };
  if (includeContents) {
    // The whole catalog is in every book — rarity is rolled per instance, so
    // "contents" is the 14 designs, not a per-tier slice. The odds table is
    // what differs between books.
    payload.contents = ROSTER.map((c) => characterPayload(c.id, asCharacter(c, "common")))
      .sort((a, b) => a.name.localeCompare(b.name));
  }
  return payload;
}

// GET /lootbox/rarities -- the tier ladder, most common first.
lootboxRouter.get("/rarities", (_req, res) => {
  res.json({
    rarities: RARITY_ORDER.map((id) => ({
      id,
      label: RARITY_TIERS[id].label,
      colorHex: RARITY_TIERS[id].colorHex
    }))
  });
});

// GET /lootbox/cookbooks -- the four Cookbooks with price + published odds.
lootboxRouter.get("/cookbooks", (_req, res) => {
  res.json({ cookbooks: COOKBOOKS.map((b) => cookbookPayload(b)) });
});

// GET /lootbox/cookbooks/:id -- one Cookbook, including its full contents.
lootboxRouter.get("/cookbooks/:id", (req, res) => {
  const book = engine.cookbookFor(req.params.id);
  if (!book) return res.status(404).json({ error: `No cookbook '${req.params.id}'.` });
  return res.json(cookbookPayload(book));
});

/** The response shape every mint-producing open shares. */
function openResponse(
  playerId: string,
  outcome: engine.OpenOutcome,
  stored: { id: string },
  extra: Record<string, unknown> = {}
) {
  return {
    ...stored,
    character: characterPayload(outcome.character.id, outcome.character),
    caseRarity: outcome.caseRarity,
    reel: outcome.reel.map((c) => characterPayload(c.id, c)),
    reelWinnerIndex: outcome.reelWinnerIndex,
    coinBalance: coinBalance(playerId),
    ...extra
  };
}

/**
 * Mirror a mint into the TigerData hypertables — best-effort, and kept out of
 * the open transaction on purpose: the mirror is a queue, not part of the
 * atomic commit.
 */
function mirrorMint(playerId: string, sourceKind: string, sourceId: string, stored: { id: string; value: number; stars?: number }, outcome: engine.OpenOutcome) {
  if (!hasDatabaseUrl()) return;
  enqueueMirror("gameplay_event", `open:${stored.id}`, {
    playerId,
    type: "open",
    detail: {
      crateId: sourceId, characterId: outcome.character.id, rarity: outcome.character.rarity
    }
  });
  enqueueMirror("acquisition_event", stored.id, {
    playerId,
    sourceKind,
    rarity: outcome.character.rarity,
    netWorth: stored.value,
    starLevel: stored.stars ?? 1,
    characterRef: stored.id
  });
}

// POST /lootbox/cookbooks/:id/open — spec §3 atomic open:
// coin debit + rarity RNG + monster mint + both ledgers, one transaction.
lootboxRouter.post(
  "/cookbooks/:id/open",
  rateLimitByPlayer({ windowMs: 60_000, max: 30, keyPrefix: "cookbook", message: "Too many cookbook opens. Try again later." }),
  (req, res) => {
    const book = engine.cookbookFor(req.params.id);
    if (!book) return res.status(404).json({ error: `No cookbook '${req.params.id}'.` });

    const parsed = clientSeedBodySchema.safeParse(req.body ?? {});
    if (!parsed.success) {
      return res.status(400).json({ error: "clientSeed must be a string of 6-64 characters." });
    }
    const playerId = (req as PlayerRequest).playerId!;

    try {
      const { outcome, stored, overflowed, boosted } = transact(() => {
        const session = stateFor(playerId);
        if (parsed.data.clientSeed !== undefined) session.setClientSeed(parsed.data.clientSeed);
        const pair = session.current;
        const nonce = session.consumeNonce();
        // The debit first: insufficient coins throws and rolls the nonce
        // increment back too, so a failed open never burns a roll.
        recordCoinsInTransaction(playerId, -book.price, "case_open", book.id);
        // Cookbook Boost (spec §6): the player asks, the store decrements one
        // held boost, and the rarity roll runs on the ×1.15 Rare+ table —
        // all inside this transaction, so a failed open refunds the boost.
        const boosted = parsed.data.useBoost === true && consumeCookbookBoost(playerId);
        const odds = boosted ? engine.boostedOdds(book.odds) : book.odds;
        const outcome = engine.openCookbook(book, pair.serverSeed, pair.clientSeed, nonce, odds);
        const { drop: stored, overflowed } = session.record({
          crateId: book.id,
          character: outcome.character,
          stars: 1,
          baseMintValue: outcome.baseMintValue,
          value: outcome.value,
          rolls: outcome.rolls,
          caseRarity: outcome.caseRarity,
          boosted,
          fairness: session.fairnessFor(pair, nonce),
          openedAt: outcome.openedAt
        });
        ledger(playerId, "cookbook_open", [stored.id], {
          bookId: book.id,
          price: book.price,
          caseRarity: outcome.caseRarity,
          value: outcome.value,
          boosted,
          overflowed
        });
        return { outcome, stored, overflowed, boosted };
      });

      mirrorMint(playerId, "cookbook", book.id, stored, outcome);
      return res.json(openResponse(playerId, outcome, stored, {
        coinsSpent: book.price,
        overflowed,
        boostApplied: boosted
      }));
    } catch (err) {
      if (err instanceof Error && err.message === COIN_ERRORS.INSUFFICIENT) {
        return res.status(402).json({
          error: `Not enough coins: ${book.name} costs ${book.price}, you have ${coinBalance(playerId)}.`
        });
      }
      throw err;
    }
  }
);

// ===== Granted Cases =======================================================
//
// Ranked wins and promos hand out a Case of a fixed rarity (spec §3/§5).
// Opening one is the same mint path a Cookbook's rolled case takes — no coin
// cost, since the case itself was the reward.

// GET /lootbox/cases — this player's unopened Cases.
lootboxRouter.get("/cases", (req: PlayerRequest, res) => {
  res.json({ cases: pendingCases(req.playerId!) });
});

// POST /lootbox/cases/:caseId/open — consume the case, mint its rarity.
lootboxRouter.post(
  "/cases/:caseId/open",
  rateLimitByPlayer({ windowMs: 60_000, max: 30, keyPrefix: "case", message: "Too many case opens. Try again later." }),
  (req, res) => {
    const parsed = clientSeedBodySchema.safeParse(req.body ?? {});
    if (!parsed.success) {
      return res.status(400).json({ error: "clientSeed must be a string of 6-64 characters." });
    }
    const playerId = (req as PlayerRequest).playerId!;

    const { outcome, stored, overflowed } = transact(() => {
      const session = stateFor(playerId);
      // Consuming the row inside the transaction is what makes a double-open
      // impossible: a racing second request sees no case and 404s.
      const pending = consumeCase(playerId, req.params.caseId);
      if (!pending) return { outcome: null, stored: null, overflowed: false };
      if (parsed.data.clientSeed !== undefined) session.setClientSeed(parsed.data.clientSeed);
      const pair = session.current;
      const nonce = session.consumeNonce();
      const outcome = engine.openCaseRarity(pending.rarity, pair.serverSeed, pair.clientSeed, nonce);
      const { drop: stored, overflowed } = session.record({
        crateId: `case:${pending.rarity}`,
        character: outcome.character,
        stars: 1,
        baseMintValue: outcome.baseMintValue,
        value: outcome.value,
        rolls: outcome.rolls,
        caseRarity: outcome.caseRarity,
        fairness: session.fairnessFor(pair, nonce),
        openedAt: outcome.openedAt
      });
      ledger(playerId, "case_open", [stored.id], {
        caseId: pending.caseId,
        source: pending.source,
        caseRarity: pending.rarity,
        value: outcome.value,
        overflowed
      });
      return { outcome, stored, overflowed };
    });

    if (!outcome || !stored) {
      return res.status(404).json({ error: `No pending case '${req.params.caseId}'.` });
    }

    mirrorMint(playerId, "case", `case:${stored.caseRarity ?? outcome.caseRarity}`, stored, outcome);
    return res.json(openResponse(playerId, outcome, stored, { overflowed }));
  }
);

// GET /lootbox/inventory — what this player owns, newest first, plus mailbox.
lootboxRouter.get("/inventory", (req, res) => {
  const requested = Number(req.query.limit ?? 50);
  if (!Number.isFinite(requested) || requested < 1 || requested > 200) {
    return res.status(400).json({ error: "limit must be a number between 1 and 200." });
  }
  const limit = Math.max(1, Math.min(Number.isFinite(requested) ? requested : 50, 200));
  const session = stateFor((req as PlayerRequest).playerId!);
  const items = session.inventory.slice(-limit).reverse();

  res.json({
    count: session.inventory.length,
    totalValue: session.inventory.reduce((sum, d) => sum + d.value, 0),
    items: items.map((d) => ({ ...d, character: characterPayload(d.character.id, d.character) })),
    mailbox: {
      count: session.mailbox.length,
      items: session.mailbox.slice(-50).reverse().map((d) => ({
        ...d,
        character: characterPayload(d.character.id, d.character)
      }))
    },
    cases: pendingCases((req as PlayerRequest).playerId!)
  });
});

// POST /lootbox/mailbox/claim — move overflow drops into the inventory.
lootboxRouter.post("/mailbox/claim", (req: PlayerRequest, res) => {
  const parsed = mailboxClaimSchema.safeParse(req.body ?? {});
  if (!parsed.success) {
    return res.status(400).json({ error: "dropIds must be a non-empty array of drop ids." });
  }
  const session = stateFor(req.playerId!);
  const { claimed, remaining } = session.claimMailbox(parsed.data.dropIds);
  res.json({
    claimed,
    remaining,
    count: session.inventory.length,
    mailboxCount: session.mailbox.length
  });
});

// POST /lootbox/reset -- clear the session. Admin-only.
lootboxRouter.post("/reset", requireAdminToken, (req: PlayerRequest, res) => {
  resetPlayer(req.playerId!);
  res.json({ reset: true });
});

// GET /lootbox/fairness -- the current commitment, plus every revealed seed.
lootboxRouter.get("/fairness", (req: PlayerRequest, res) => {
  res.json({
    current: publicSeedPair(stateFor((req as PlayerRequest).playerId!).current),
    retired: stateFor((req as PlayerRequest).playerId!).retired.slice(-10).map((p) => publicSeedPair(p, true)),
    howItWorks:
      "roll = HMAC_SHA256(serverSeed, `${clientSeed}:${nonce}:${cursor}`); the first " +
      "8 hex digits become a float in [0,1). The server publishes SHA256(serverSeed) " +
      "before any open and reveals serverSeed on rotation, so past rolls can be " +
      "recomputed but never chosen."
  });
});

// POST /lootbox/fairness/client-seed -- players supply their own entropy.
lootboxRouter.post("/fairness/client-seed", (req, res) => {
  const parsed = clientSeedBodySchema.safeParse(req.body ?? {});
  if (!parsed.success || parsed.data.clientSeed === undefined) {
    return res.status(400).json({ error: "clientSeed must be a string of 6-64 characters." });
  }
  stateFor((req as PlayerRequest).playerId!).setClientSeed(parsed.data.clientSeed);
  return res.json({ current: publicSeedPair(stateFor((req as PlayerRequest).playerId!).current) });
});

// POST /lootbox/fairness/rotate -- retire the active seed (revealing it) and commit anew.
lootboxRouter.post("/fairness/rotate", (req: PlayerRequest, res) => {
  const revealed = stateFor((req as PlayerRequest).playerId!).rotateSeed();
  res.json({
    revealed: publicSeedPair(revealed, true),
    current: publicSeedPair(stateFor((req as PlayerRequest).playerId!).current)
  });
});

// ===== Promo codes =========================================================

// POST /lootbox/promos -- create a promo code (admin only).
// body: { code: "BIGCHEESE", reward: "coins:500" | "case:epic", usesLimit?: number, expiresAt?: ISO }
lootboxRouter.post("/promos", requireAdminToken, (req, res) => {
  const { code, reward, usesLimit, expiresAt } = req.body ?? {};
  if (typeof code !== "string" || typeof reward !== "string") {
    return res.status(400).json({ error: "code and reward are required" });
  }
  const limit = usesLimit !== undefined ? Number(usesLimit) : 0;
  if (!Number.isInteger(limit) || limit < 0) {
    return res.status(400).json({ error: "usesLimit must be a non-negative integer" });
  }
  const exp = typeof expiresAt === "string" && expiresAt.length > 0 ? expiresAt : undefined;
  try {
    const created = promo.createPromo(code.toUpperCase(), reward, { usesLimit: limit, expiresAt: exp });
    return res.status(201).json({ promo: created });
  } catch (err: any) {
    return res.status(400).json({ error: err.message });
  }
});

// GET /lootbox/promos -- list all codes and their remaining uses (admin only).
lootboxRouter.get("/promos", requireAdminToken, (_req, res) => {
  const rows = db
    .prepare(`SELECT code, reward, uses_limit, uses, expires_at FROM promo_code ORDER BY created_at DESC`)
    .all() as { code: string; reward: string; uses_limit: number; uses: number; expires_at: string | null }[];
  res.json({
    promos: rows.map((r) => ({
      code: r.code,
      reward: r.reward,
      usesLimit: r.uses_limit,
      uses: r.uses,
      remaining: r.uses_limit > 0 ? r.uses_limit - r.uses : null,
      expired: r.expires_at && new Date(r.expires_at) < new Date(),
      expiresAt: r.expires_at
    }))
  });
});

// POST /lootbox/promos/:code/redeem -- one per player, atomic.
lootboxRouter.post(
  "/promos/:code/redeem",
  rateLimitByPlayer({ windowMs: 60_000, max: 5, keyPrefix: "promo", message: "Too many promo attempts." }),
  (req, res) => {
    try {
      const result = promo.redeemPromo((req as PlayerRequest).playerId!, req.params.code.toUpperCase());
      return res.json({ result });
    } catch (err: any) {
      const code = err.message;
      const status: Record<string, number> = {
        INVALID_PROMO_CODE_FORMAT: 400,
        INVALID_PROMO_REWARD: 400,
        PROMO_NOT_FOUND: 404,
        PROMO_EXPIRED: 410,
        PROMO_FULLY_REDEEMED: 410,
        PROMO_ALREADY_REDEEMED: 409
      };
      return res.status(status[code] ?? 400).json({ error: { code, message: code } });
    }
  }
);

// POST /lootbox/verify -- recompute a past cookbook open from published inputs.
lootboxRouter.post("/verify", (req, res) => {
  const parsed = verifyOpenSchema.safeParse(req.body ?? {});
  if (!parsed.success) {
    return res.status(400).json({ error: "bookId, serverSeed, clientSeed and a non-negative integer nonce are required." });
  }
  const { bookId, serverSeed, clientSeed, nonce, boosted } = parsed.data;
  const book = engine.cookbookFor(bookId);
  if (!book) return res.status(404).json({ error: `No cookbook '${bookId}'.` });

  const outcome = engine.openCookbook(
    book, serverSeed, clientSeed, nonce,
    boosted ? engine.boostedOdds(book.odds) : book.odds
  );
  return res.json({
    serverSeedHash: engine.hashSeed(serverSeed),
    result: {
      bookId: book.id,
      character: characterPayload(outcome.character.id),
      caseRarity: outcome.caseRarity,
      baseMintValue: outcome.baseMintValue,
      value: outcome.value,
      rolls: outcome.rolls,
      fairness: { serverSeedHash: engine.hashSeed(serverSeed), clientSeed, nonce }
    }
  });
});
