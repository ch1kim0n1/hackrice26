// Battle seed — server-authoritative determinism. seed = HMAC(matchId,
// SERVER_SECRET), per docs/SECURITY.md (Anti-cheat: "Seed = HMAC(matchId,
// server secret)"). The server secret is NEVER client-visible. The same seed
// drives the Swift SeededRNG (UInt64) and the DB `battles.seed` (bigint).

import { createHmac } from "crypto";

function serverSecret(): string {
  const s = process.env.SERVER_SECRET;
  if (!s) {
    if (process.env.NODE_ENV === "production") {
      throw new Error("SERVER_SECRET is required in production");
    }
    return "DEV_INSECURE_SERVER_SECRET"; // matches the DB _server_secret() dev fallback
  }
  return s;
}

/** Unsigned 64-bit seed (first 8 bytes of the HMAC, big-endian) — the value
 *  the SeededRNG consumes as UInt64. */
export function battleSeedU64(matchId: string, secret = serverSecret()): bigint {
  const digest = createHmac("sha256", secret).update(matchId).digest();
  return digest.readBigUInt64BE(0);
}

/** Signed 64-bit form for the Postgres `bigint` column (same bit pattern). */
export function battleSeedForDb(matchId: string, secret = serverSecret()): bigint {
  return BigInt.asIntN(64, battleSeedU64(matchId, secret));
}
