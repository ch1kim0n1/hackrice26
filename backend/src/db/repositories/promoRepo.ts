// Promo code redemption mirror -> TigerData (DB finalization pass).
//
// promoCodes.ts had no Postgres awareness at all before this. A redemption
// upserts the code into app.promo_codes (by code_norm) if it hasn't been seen
// yet, then inserts the redemption row — this is how the catalog table stays
// honest without a separate mirror for admin createPromo/deletePromo.
import { PoolClient } from "pg";
import { withPlayer } from "../pg";
import { ensurePlayer } from "./players";

export interface PromoRedemptionMirror {
  playerId: string;
  code: string;
  reward: string;
  usesLimit: number;
  expiresAt: string | null;
}

export async function mirrorPromoRedemption(p: PromoRedemptionMirror): Promise<void> {
  await withPlayer(p.playerId, async (client: PoolClient) => {
    await ensurePlayer(client, p.playerId);
    const codeNorm = p.code.toLowerCase();
    const inserted = await client.query(
      `insert into app.promo_codes (code_norm, code_display, reward, max_uses, expires_at)
       values ($1,$2,$3,$4,$5)
       on conflict (code_norm) do nothing
       returning id`,
      [codeNorm, p.code, JSON.stringify({ raw: p.reward }), p.usesLimit || null, p.expiresAt]
    );
    const codeId = inserted.rowCount
      ? (inserted.rows[0].id as string)
      : ((await client.query(`select id from app.promo_codes where code_norm = $1`, [codeNorm])).rows[0].id as string);

    await client.query(
      `insert into app.promo_redemptions (code_id, player_id) values ($1,$2)
       on conflict (code_id, player_id) do nothing`,
      [codeId, p.playerId]
    );
  });
}
