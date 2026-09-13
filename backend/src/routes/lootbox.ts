import { Router } from "express";
import {
  CHARACTERS,
  CHARACTER_FLAVOR,
  CRATES,
  RARITY_ORDER,
  RARITY_TIERS,
  RARITY_TOTAL,
  SHOP_CASES,
  ShopCase
} from "../data/lootTable";
import { db } from "../db";
import { hasDatabaseUrl } from "../db/pg";
import * as engine from "../services/lootboxEngine";
import { publicSeedPair, resetPlayer, stateFor } from "../services/lootboxState";
import * as promo from "../services/promoCodes";
import { PlayerRequest, requirePlayerId } from "../middleware/player";
import { rateLimitByPlayer, requireAdminToken } from "../middleware/security";
import { Character, Crate, LootDrop } from "../types";
import { getOrCreate } from "./user";
import { tierForPoints } from "../game/rankTiers";
import { enqueueMirror } from "../services/mirrorQueue";
import { COIN_ERRORS, coinBalance, recordCoins } from "../services/coins";

export const lootboxRouter = Router();

// Every lootbox route is scoped to the X-Player-Id caller.
lootboxRouter.use(requirePlayerId);

/**
 * Character plus the presentational bits the crate UI needs.
 *
 * `fallback` covers a character that isn't in the gacha catalog at all — the
 * starter roster (lootboxState.ts seedStarterRoster) is a real owned drop
 * like any other, but was never rolled from CHARACTERS, so it isn't in it.
 * Every route reading a *stored* drop back already has that drop's own
 * embedded character data sitting right there and should pass it, so this
 * degrades instead of throwing on an id the catalog has never heard of.
 */
export function characterPayload(id: string, fallback?: Character) {
  const character = CHARACTERS[id] ?? fallback;
  if (!character) throw new Error(`Unknown character '${id}'`);
  const tier = RARITY_TIERS[character.rarity];
  return {
    ...character,
    rarityLabel: tier.label,
    rarityColorHex: tier.colorHex,
    flavor: CHARACTER_FLAVOR[id] ?? ""
  };
}

function cratePayload(crate: Crate, includeContents = false, playerId?: string) {
  const payload: Record<string, unknown> = {
    id: crate.id,
    name: crate.name,
    description: crate.description,
    keyCost: crate.keyCost,
    characterCount: crate.characterIds.length,
    odds: engine.crateOdds(crate)
  };
  if (playerId) {
    const s = stateFor(playerId);
    payload.pity = {
      sinceEpic: s.sinceEpic,
      sinceLegendary: s.sinceLegendary,
      epicIn: Math.max(0, engine.EPIC_PITY - s.sinceEpic),
      legendaryIn: Math.max(0, engine.LEGENDARY_PITY - s.sinceLegendary)
    };
  }
  if (includeContents) {
    payload.contents = crate.characterIds
      .map((c) => characterPayload(c))
      .sort(
        (a, b) =>
          RARITY_TIERS[a.rarity].order - RARITY_TIERS[b.rarity].order ||
          a.name.localeCompare(b.name)
      );
  }
  return payload;
}

// GET /lootbox/rarities -- the tier ladder, most common first.
lootboxRouter.get("/rarities", (_req, res) => {
  res.json({
    rarities: RARITY_ORDER.map((id) => ({
      id,
      label: RARITY_TIERS[id].label,
      colorHex: RARITY_TIERS[id].colorHex,
      chance: RARITY_TIERS[id].weight / RARITY_TOTAL,
      oneIn: Math.round(RARITY_TOTAL / RARITY_TIERS[id].weight)
    }))
  });
});

// GET /lootbox/crates -- every crate with its published drop rates + pity.
lootboxRouter.get("/crates", (req, res) => {
  const pid = (req as PlayerRequest).playerId!;
  res.json({ crates: Object.values(CRATES).map((c) => cratePayload(c, false, pid)) });
});

// GET /lootbox/crates/:id -- one crate, including its full contents.
lootboxRouter.get("/crates/:id", (req, res) => {
  const crate = CRATES[req.params.id];
  if (!crate) return res.status(404).json({ error: `No crate '${req.params.id}'.` });
  return res.json(cratePayload(crate, true));
});

/**
 * One key-crate open: the roll with rank-scaled odds and the pity ladder.
 * Shop cases do not come through here — see the shop routes below.
 */
function resolveCrateOpen(playerId: string, crate: Crate, clientSeed?: string) {
  if (clientSeed !== undefined) {
    stateFor(playerId).setClientSeed(clientSeed);
  }

  const session = stateFor(playerId);
  const pair = session.current;
  const nonce = session.consumeNonce();
  // Higher consistency rank = better odds on non-common pulls (#86). Pity
  // still applies after scaling, so guarantees are unaffected.
  const rankTier = tierForPoints(getOrCreate(playerId).rankPoints ?? 0);
  const outcome = engine.openCrate(crate, pair.serverSeed, pair.clientSeed, nonce, {
    sinceEpic: session.sinceEpic,
    sinceLegendary: session.sinceLegendary
  }, rankTier);

  // Pity counters advance on the resolved tier (a pity-forced pull resets them).
  const next = engine.advancePity(
    { sinceEpic: session.sinceEpic, sinceLegendary: session.sinceLegendary },
    outcome.character.rarity
  );
  session.sinceEpic = next.sinceEpic;
  session.sinceLegendary = next.sinceLegendary;

  const drop: LootDrop = {
    crateId: crate.id,
    character: outcome.character,
    // Every monster instance carries its mastery, so the planned fusion
    // system is never handed an inventory where half the rows have no
    // stars at all. A fresh pull is always 1 star.
    stars: 1,
    power: outcome.power,
    powerLabel: outcome.powerLabel,
    shiny: outcome.shiny,
    value: outcome.value,
    rolls: outcome.rolls,
    pityForced: outcome.pityForced,
    fairness: session.fairnessFor(pair, nonce),
    openedAt: outcome.openedAt
  };

  // The reel is animation data; it does not belong in stored history.
  // `record` mints this drop's real per-instance id — the client needs it
  // back (not just the character/pity summary) to ever sell what it just
  // pulled, so `stored` (not `drop`) is what the routes below respond with.
  const stored = session.record(drop);

  // Best-effort gameplay-event mirror into the TigerData hypertable.
  if (hasDatabaseUrl()) {
    enqueueMirror("gameplay_event", `open:${stored.id}`, {
      playerId,
      type: "open",
      detail: {
        crateId: crate.id, characterId: outcome.character.id, rarity: outcome.character.rarity,
      },
    });
    // The pull itself, for analytics.acquisition_hourly -- "has my luck been
    // good lately" is a different question from "what did I open".
    enqueueMirror("acquisition_event", stored.id, {
      playerId,
      sourceKind: "lootbox",
      rarity: outcome.character.rarity,
      netWorth: stored.value,
      starLevel: stored.stars ?? 1,
      characterRef: stored.id,
    });
  }

  return { session, drop: stored, outcome };
}

// POST /lootbox/crates/:id/open -- spend keys, resolve one drop.
lootboxRouter.post("/crates/:id/open", rateLimitByPlayer({ windowMs: 60_000, max: 30, keyPrefix: "crate", message: "Too many crate opens. Try again later." }), (req, res) => {
  const crate = CRATES[req.params.id];
  if (!crate) return res.status(404).json({ error: `No crate '${req.params.id}'.` });

  const clientSeedRaw = req.body?.clientSeed;
  let clientSeed: string | undefined;
  if (clientSeedRaw !== undefined && clientSeedRaw !== null) {
    if (typeof clientSeedRaw !== "string" || clientSeedRaw.length < 6 || clientSeedRaw.length > 64) {
      return res.status(400).json({ error: "clientSeed must be a string of 6-64 characters." });
    }
    clientSeed = clientSeedRaw;
  }

  const playerId = (req as PlayerRequest).playerId!;
  if (!stateFor(playerId).spendKeys(crate.keyCost)) {
    return res.status(402).json({
      error: `Not enough keys: ${crate.name} costs ${crate.keyCost}, you have ${stateFor(playerId).keys}.`
    });
  }

  const { session, drop, outcome } = resolveCrateOpen(playerId, crate, clientSeed);

  return res.json({
    ...drop,
    character: characterPayload(outcome.character.id),
    reel: outcome.reel.map((c) => characterPayload(c)),
    reelWinnerIndex: outcome.reelWinnerIndex,
    keysRemaining: session.keys,
    pity: {
      sinceEpic: session.sinceEpic,
      sinceLegendary: session.sinceLegendary,
      epicIn: Math.max(0, engine.EPIC_PITY - session.sinceEpic),
      legendaryIn: Math.max(0, engine.LEGENDARY_PITY - session.sinceLegendary)
    }
  });
});

// ===== Shop cases ===========================================================
//
// The coin shop: one case per rarity (data/lootTable.ts SHOP_CASES). The roll
// is the plain weighted draw over the tiers a case stocks, no rank boost, no
// pity -- so a pricier case is better only because it stocks rarer tiers.
// Drops are priced off BASE_VALUES (engine.openShopCase). Key crates, rank
// odds and pity above are untouched by anything here.

function shopCasePayload(shopCase: ShopCase) {
  return {
    id: shopCase.id,
    name: shopCase.name,
    description: shopCase.description,
    coinCost: engine.shopCaseCoinCost(shopCase),
    characterCount: shopCase.characterIds.length,
    odds: engine.crateOdds(shopCase)
  };
}

// GET /lootbox/shop-cases -- every shop case, cheapest first, with price and odds.
lootboxRouter.get("/shop-cases", (_req, res) => {
  res.json({ cases: Object.values(SHOP_CASES).map(shopCasePayload) });
});

// POST /lootbox/shop-cases/:id/open -- pay the case's coin price, resolve one drop.
lootboxRouter.post("/shop-cases/:id/open", rateLimitByPlayer({ windowMs: 60_000, max: 30, keyPrefix: "shop-case", message: "Too many case opens. Try again later." }), (req, res) => {
  const shopCase = SHOP_CASES[req.params.id];
  if (!shopCase) return res.status(404).json({ error: `No case '${req.params.id}'.` });

  const clientSeedRaw = req.body?.clientSeed;
  let clientSeed: string | undefined;
  if (clientSeedRaw !== undefined && clientSeedRaw !== null) {
    if (typeof clientSeedRaw !== "string" || clientSeedRaw.length < 6 || clientSeedRaw.length > 64) {
      return res.status(400).json({ error: "clientSeed must be a string of 6-64 characters." });
    }
    clientSeed = clientSeedRaw;
  }

  const playerId = (req as PlayerRequest).playerId!;
  const cost = engine.shopCaseCoinCost(shopCase);
  try {
    recordCoins(playerId, -cost, "case_open", shopCase.id);
  } catch (err) {
    if (err instanceof Error && err.message === COIN_ERRORS.INSUFFICIENT) {
      return res.status(402).json({
        error: `Not enough coins: ${shopCase.name} costs ${cost}, you have ${coinBalance(playerId)}.`
      });
    }
    throw err;
  }

  const session = stateFor(playerId);
  if (clientSeed !== undefined) session.setClientSeed(clientSeed);
  const pair = session.current;
  const nonce = session.consumeNonce();
  const outcome = engine.openShopCase(shopCase, pair.serverSeed, pair.clientSeed, nonce);

  const stored = session.record({
    crateId: shopCase.id,
    character: outcome.character,
    stars: 1,
    power: outcome.power,
    powerLabel: outcome.powerLabel,
    shiny: outcome.shiny,
    value: outcome.value,
    rolls: outcome.rolls,
    pityForced: null,
    fairness: session.fairnessFor(pair, nonce),
    openedAt: outcome.openedAt
  });

  if (hasDatabaseUrl()) {
    enqueueMirror("gameplay_event", `open:${stored.id}`, {
      playerId,
      type: "open",
      detail: {
        crateId: shopCase.id, characterId: outcome.character.id, rarity: outcome.character.rarity,
      },
    });
    // A shop pull mints a monster, same as a crate pull — keep it in the
    // pull-luck series.
    enqueueMirror("acquisition_event", stored.id, {
      playerId,
      sourceKind: "shop_case",
      rarity: outcome.character.rarity,
      netWorth: stored.value,
      starLevel: stored.stars ?? 1,
      characterRef: stored.id,
    });
  }

  return res.json({
    ...stored,
    character: characterPayload(outcome.character.id),
    reel: outcome.reel.map((c) => characterPayload(c)),
    reelWinnerIndex: outcome.reelWinnerIndex,
    coinsSpent: cost,
    coinBalance: coinBalance(playerId)
  });
});

// GET /lootbox/inventory -- what this session has pulled, newest first.
lootboxRouter.get("/inventory", (req, res) => {
  const requested = Number(req.query.limit ?? 50);
  if (!Number.isFinite(requested) || requested < 1 || requested > 200) {
    return res.status(400).json({ error: "limit must be a number between 1 and 200." });
  }
  const limit = Math.max(1, Math.min(Number.isFinite(requested) ? requested : 50, 200));
  const items = stateFor((req as PlayerRequest).playerId!).inventory.slice(-limit).reverse();

  const session = stateFor((req as PlayerRequest).playerId!);
  res.json({
    keys: session.keys,
    count: session.inventory.length,
    totalValue: session.inventory.reduce((sum, d) => sum + d.value, 0),
    items: items.map((d) => ({ ...d, character: characterPayload(d.character.id, d.character) })),
    pity: {
      sinceEpic: session.sinceEpic,
      sinceLegendary: session.sinceLegendary,
      epicIn: Math.max(0, engine.EPIC_PITY - session.sinceEpic),
      legendaryIn: Math.max(0, engine.LEGENDARY_PITY - session.sinceLegendary)
    }
  });
});

// POST /lootbox/keys/grant -- award keys. This is where the rest of the game pays out.
// Admin-only: clients must not be able to mint keys for themselves.
lootboxRouter.post("/keys/grant", requireAdminToken, (req, res) => {
  const amount = Number(req.body?.amount);
  if (!Number.isInteger(amount) || amount < 1 || amount > 1000) {
    return res.status(400).json({ error: "amount must be an integer between 1 and 1000." });
  }
  const reason = typeof req.body?.reason === "string" ? req.body.reason.slice(0, 120) : "granted";
  return res.json({ keys: stateFor((req as PlayerRequest).playerId!).grantKeys(amount), reason });
});

// POST /lootbox/reset -- clear the session. Admin-only.
lootboxRouter.post("/reset", requireAdminToken, (req: PlayerRequest, res) => {
  stateFor((req as PlayerRequest).playerId!).reset();
  res.json({ reset: true, keys: stateFor((req as PlayerRequest).playerId!).keys });
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
  const clientSeed = req.body?.clientSeed;
  if (typeof clientSeed !== "string" || clientSeed.length < 6 || clientSeed.length > 64) {
    return res.status(400).json({ error: "clientSeed must be a string of 6-64 characters." });
  }
  stateFor((req as PlayerRequest).playerId!).setClientSeed(clientSeed);
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
// body: { code: "BIGCHEESE", reward: "keys:50" | "crate:starter-crate", usesLimit?: number, expiresAt?: ISO }
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
        PROMO_ALREADY_REDEEMED: 409,
        PROMO_CRATE_NOT_FOUND: 500
      };
      return res.status(status[code] ?? 400).json({ error: { code, message: code } });
    }
  }
);

// POST /lootbox/verify -- recompute a past open from its published inputs.
lootboxRouter.post("/verify", (req, res) => {
  const { crateId, serverSeed, clientSeed, nonce } = req.body ?? {};
  const crate = typeof crateId === "string" ? CRATES[crateId] : undefined;

  if (!crate) return res.status(404).json({ error: `No crate '${crateId}'.` });
  if (typeof serverSeed !== "string" || !serverSeed.length) {
    return res.status(400).json({ error: "serverSeed is required." });
  }
  if (typeof clientSeed !== "string" || !clientSeed.length) {
    return res.status(400).json({ error: "clientSeed is required." });
  }
  if (!Number.isInteger(nonce) || nonce < 0) {
    return res.status(400).json({ error: "nonce must be a non-negative integer." });
  }

  const outcome = engine.openCrate(crate, serverSeed, clientSeed, nonce);
  return res.json({
    serverSeedHash: engine.hashSeed(serverSeed),
    result: {
      crateId: crate.id,
      character: characterPayload(outcome.character.id),
      power: outcome.power,
      powerLabel: outcome.powerLabel,
      shiny: outcome.shiny,
      value: outcome.value,
      rolls: outcome.rolls,
      fairness: { serverSeedHash: engine.hashSeed(serverSeed), clientSeed, nonce }
    }
  });
});
