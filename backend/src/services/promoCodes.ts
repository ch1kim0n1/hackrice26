import { db } from "../db";
import { Crate, Fairness, LootDrop } from "../types";
import { CHARACTERS, CRATES, RARITY_TIERS, CHARACTER_FLAVOR } from "../data/lootTable";
import * as engine from "./lootboxEngine";
import { stateFor } from "./lootboxState";

export interface PromoCode {
  code: string;
  reward: string;
  usesLimit: number;
  uses: number;
  expiresAt: string | null;
}

export interface PromoRewardResult {
  reward: string;
  keys: number;
  /** Only present when the reward is a free crate open. */
  drop?: CrateOpenResult;
}

export interface CrateOpenResult {
  crateId: string;
  character: Record<string, unknown>;
  power: number;
  powerLabel: string;
  shiny: boolean;
  value: number;
  rolls: LootDrop["rolls"];
  fairness: Fairness;
  openedAt: string;
  reel: Record<string, unknown>[];
  reelWinnerIndex: number;
}

const CODE_PATTERN = /^[A-Z0-9]{4,16}$/;
const REWARD_PATTERN = /^(keys:\d{1,4}|crate:[a-z0-9-]+)$/;

/** Character plus presentational bits shared with the lootbox routes. */
function characterPayload(id: string) {
  const global = CHARACTERS[id];
  if (!global) return { id, name: id, colorHex: "#888888", rarity: "common" as const, statType: "protein" as const, isLocked: false, rarityLabel: "Common", rarityColorHex: "#888888", flavor: "" };
  const tier = RARITY_TIERS[global.rarity];
  return {
    ...global,
    rarityLabel: tier.label,
    rarityColorHex: tier.colorHex,
    flavor: CHARACTER_FLAVOR[id] ?? ""
  };
}

export function createPromo(
  code: string,
  reward: string,
  options: { usesLimit?: number; expiresAt?: string } = {}
): PromoCode {
  if (!CODE_PATTERN.test(code)) {
    throw new Error("INVALID_PROMO_CODE_FORMAT");
  }
  if (!REWARD_PATTERN.test(reward)) {
    throw new Error("INVALID_PROMO_REWARD");
  }
  db.prepare(
    `INSERT INTO promo_code (code, reward, uses_limit, expires_at) VALUES (?, ?, ?, ?)`
  ).run(code, reward, options.usesLimit ?? 0, options.expiresAt ?? null);

  return { code, reward, usesLimit: options.usesLimit ?? 0, uses: 0, expiresAt: options.expiresAt ?? null };
}

export function getPromo(code: string): PromoCode | null {
  const row = db
    .prepare(`SELECT code, reward, uses_limit, uses, expires_at FROM promo_code WHERE code = ?`)
    .get(code) as
    | { code: string; reward: string; uses_limit: number; uses: number; expires_at: string | null }
    | undefined;
  if (!row) return null;
  return { code: row.code, reward: row.reward, usesLimit: row.uses_limit, uses: row.uses, expiresAt: row.expires_at };
}

export function deletePromo(code: string): void {
  db.prepare(`DELETE FROM promo_redeem WHERE code = ?`).run(code);
  db.prepare(`DELETE FROM promo_code WHERE code = ?`).run(code);
}

function parseReward(reward: string): { type: "keys"; amount: number } | { type: "crate"; crateId: string } {
  const keysMatch = reward.match(/^keys:(\d+)$/);
  if (keysMatch) return { type: "keys", amount: Number(keysMatch[1]) };
  const crateMatch = reward.match(/^crate:([a-z0-9-]+)$/);
  if (crateMatch) return { type: "crate", crateId: crateMatch[1] };
  throw new Error("INVALID_PROMO_REWARD");
}

export function redeemPromo(playerId: string, code: string): PromoRewardResult {
  if (!CODE_PATTERN.test(code)) {
    throw new Error("INVALID_PROMO_CODE_FORMAT");
  }

  const promo = getPromo(code);
  if (!promo) throw new Error("PROMO_NOT_FOUND");
  if (promo.expiresAt && new Date(promo.expiresAt) < new Date()) throw new Error("PROMO_EXPIRED");
  if (promo.usesLimit > 0 && promo.uses >= promo.usesLimit) throw new Error("PROMO_FULLY_REDEEMED");

  const already = db
    .prepare(`SELECT 1 FROM promo_redeem WHERE player_id = ? AND code = ?`)
    .get(playerId, code);
  if (already) throw new Error("PROMO_ALREADY_REDEEMED");

  // Validate the reward BEFORE consuming a use: a promo pointing at a deleted
  // crate must fail without burning the player's one redemption.
  const parsed = parseReward(promo.reward);
  const crate = parsed.type === "crate" ? CRATES[parsed.crateId] : undefined;
  if (parsed.type === "crate" && !crate) throw new Error("PROMO_CRATE_NOT_FOUND");

  db.exec("BEGIN");
  try {
    const update = db
      .prepare(
        `UPDATE promo_code
         SET uses = uses + 1
         WHERE code = ? AND (uses_limit = 0 OR uses < uses_limit)`
      )
      .run(code);
    if (update.changes === 0) {
      throw new Error("PROMO_FULLY_REDEEMED");
    }
    db.prepare(`INSERT INTO promo_redeem (player_id, code) VALUES (?, ?)`).run(playerId, code);
    db.exec("COMMIT");
  } catch (err) {
    db.exec("ROLLBACK");
    throw err;
  }

  const state = stateFor(playerId);

  if (parsed.type === "keys") {
    const keys = state.grantKeys(parsed.amount);
    return { reward: promo.reward, keys };
  }

  // crate is guaranteed non-null here — keys rewards returned above, and a
  // missing crate already threw before the redemption was consumed.
  if (!crate) throw new Error("PROMO_CRATE_NOT_FOUND");
  const pair = state.current;
  const nonce = state.consumeNonce();
  const outcome = engine.openCrate(crate, pair.serverSeed, pair.clientSeed, nonce);

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
    fairness: state.fairnessFor(pair, nonce),
    openedAt: outcome.openedAt
  };
  state.record(drop);

  return {
    reward: promo.reward,
    keys: state.keys,
    drop: {
      ...drop,
      character: characterPayload(outcome.character.id),
      reel: outcome.reel.map(characterPayload),
      reelWinnerIndex: outcome.reelWinnerIndex
    }
  };
}

