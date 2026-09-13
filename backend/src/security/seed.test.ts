import { describe, it, expect } from "vitest";
import { battleSeedU64, battleSeedForDb } from "./seed";

describe("battle seed = HMAC(matchId, SERVER_SECRET)", () => {
  const secret = "test-server-secret";

  it("is deterministic for the same match id + secret", () => {
    expect(battleSeedU64("match-1", secret)).toBe(battleSeedU64("match-1", secret));
  });

  it("differs across match ids", () => {
    expect(battleSeedU64("match-1", secret)).not.toBe(battleSeedU64("match-2", secret));
  });

  it("depends on the secret (client can't reproduce it)", () => {
    expect(battleSeedU64("match-1", secret)).not.toBe(battleSeedU64("match-1", "other-secret"));
  });

  it("db form is the signed 64-bit reinterpretation of the u64 seed", () => {
    const u = battleSeedU64("match-1", secret);
    expect(battleSeedForDb("match-1", secret)).toBe(BigInt.asIntN(64, u));
  });

  it("u64 fits in 64 bits", () => {
    const u = battleSeedU64("anything", secret);
    expect(u).toBeGreaterThanOrEqual(0n);
    expect(u).toBeLessThan(1n << 64n);
  });
});
