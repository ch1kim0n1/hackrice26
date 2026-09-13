import { db } from "../db";
import { Rarity } from "../types";
import { RARITY_ORDER } from "../data/lootTable";
import { PendingCase, grantCase } from "./lootboxState";
import { coinBalance, recordCoinsInTransaction } from "./coins";
import { hasDatabaseUrl } from "../db/pg";
import { enqueueMirror } from "./mirrorQueue";

export interface PromoCode {
  code: string;
  reward: string;
  usesLimit: number;
  uses: number;
  expiresAt: string | null;
}

export interface PromoRewardResult {
  reward: string;
  /** Present when the reward granted coins. */
  coinBalance?: number;
  /** Present when the reward granted a Case of a fixed rarity. */
  case?: PendingCase;
}

const CODE_PATTERN = /^[A-Z0-9]{4,16}$/;
const REWARD_PATTERN = /^(coins:\d{1,7}|case:[a-z]+)$/;

export function createPromo(
  code: string,
  reward: string,
  options: { usesLimit?: number; expiresAt?: string } = {}
): PromoCode {
  if (!CODE_PATTERN.test(code)) {
    throw new Error("INVALID_PROMO_CODE_FORMAT");
  }
  const parsed = REWARD_PATTERN.test(reward) ? parseReward(reward) : null;
  if (!parsed) {
    throw new Error("INVALID_PROMO_REWARD");
  }
  // Validate the reward's referent at creation time: a promo for a Case of a
  // rarity that does not exist should fail here, not at redemption.
  if (parsed.type === "case" && !RARITY_ORDER.includes(parsed.rarity)) {
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

function parseReward(reward: string): { type: "coins"; amount: number } | { type: "case"; rarity: Rarity } {
  const coinsMatch = reward.match(/^coins:(\d+)$/);
  if (coinsMatch) return { type: "coins", amount: Number(coinsMatch[1]) };
  const caseMatch = reward.match(/^case:([a-z]+)$/);
  if (caseMatch) return { type: "case", rarity: caseMatch[1] as Rarity };
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

  // Validate the reward BEFORE consuming a use: a promo pointing at something
  // invalid must fail without burning the player's one redemption.
  const parsed = parseReward(promo.reward);
  if (parsed.type === "case" && !RARITY_ORDER.includes(parsed.rarity)) {
    throw new Error("INVALID_PROMO_REWARD");
  }

  // Redemption and the reward are one transaction: a crash between "marked
  // redeemed" and "reward granted" can no longer spend the redemption and
  // deliver nothing.
  db.exec("BEGIN IMMEDIATE");
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
    if (hasDatabaseUrl()) {
      enqueueMirror("promo_redemption", `${code}:${playerId}`, {
        playerId,
        code,
        reward: promo.reward,
        usesLimit: promo.usesLimit,
        expiresAt: promo.expiresAt,
      });
    }

    let result: PromoRewardResult;
    if (parsed.type === "coins") {
      recordCoinsInTransaction(playerId, parsed.amount, "grant", `promo:${code}`);
      result = { reward: promo.reward, coinBalance: coinBalance(playerId) };
    } else {
      result = { reward: promo.reward, case: grantCase(playerId, parsed.rarity, `promo:${code}`) };
    }
    db.exec("COMMIT");
    return result;
  } catch (err) {
    try {
      db.exec("ROLLBACK");
    } catch {
      // A failed BEGIN leaves nothing to roll back.
    }
    throw err;
  }
}
