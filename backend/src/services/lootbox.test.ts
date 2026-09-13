import { describe, it, expect, beforeEach } from "vitest";
import {
  createSeedPair,
  publicSeedPair,
  state,
  STARTING_KEYS,
  SeedPair
} from "./lootboxState";
import {
  openCrate,
  hashSeed,
  roll,
  CURSOR,
  newServerSeed,
  applyPity,
  advancePity
} from "./lootboxEngine";
import { CRATES, CHARACTERS, RARITY_ORDER, RARITY_TIERS } from "../data/lootTable";
import { createHash } from "crypto";

// ============================================================================
// Lootbox fairness tests.
//
// Three properties the provably-fair scheme MUST hold:
//   1. Commit-reveal: SHA256(serverSeed) == serverSeedHash published up front.
//   2. Seed rotation: rotateSeed() retires the old pair (reveals serverSeed,
//      sets retiredAt) and commits a fresh pair with a NEW serverSeedHash.
//   3. spendKeys refuses to overspend — never goes negative, never spends
//      more than the balance.
// ============================================================================

beforeEach(() => {
  state.reset();
});

describe("lootbox — commit-reveal hash verifies", () => {
  it("hashSeed(serverSeed) === serverSeedHash on a fresh pair", () => {
    const pair = createSeedPair("client-xyz");
    expect(pair.serverSeedHash).toBe(hashSeed(pair.serverSeed));
    // Independent recompute via node crypto to catch a hashSeed bug.
    expect(pair.serverSeedHash).toBe(
      createHash("sha256").update(pair.serverSeed).digest("hex")
    );
  });

  it("publicSeedPair withholds serverSeed unless reveal=true", () => {
    const pair = createSeedPair("client-xyz");
    const hidden = publicSeedPair(pair, false) as Record<string, unknown>;
    expect(hidden).not.toHaveProperty("serverSeed");
    expect(hidden).toHaveProperty("serverSeedHash");

    const revealed = publicSeedPair(pair, true) as Record<string, unknown>;
    expect(revealed).toHaveProperty("serverSeed");
    expect(revealed.serverSeed).toBe(pair.serverSeed);
  });

  it("every roll can be recomputed from the published inputs", () => {
    const pair = createSeedPair("client-verify");
    const crate = CRATES["starter-crate"];
    const outcome = openCrate(crate, pair.serverSeed, pair.clientSeed, 0);

    // Recompute each roll independently from (serverSeed, clientSeed, nonce, cursor).
    expect(outcome.rolls.rarity).toBeCloseTo(
      roll(pair.serverSeed, pair.clientSeed, 0, CURSOR.rarity),
      12
    );
    expect(outcome.rolls.character).toBeCloseTo(
      roll(pair.serverSeed, pair.clientSeed, 0, CURSOR.character),
      12
    );
    expect(outcome.rolls.power).toBeCloseTo(
      roll(pair.serverSeed, pair.clientSeed, 0, CURSOR.power),
      12
    );
    expect(outcome.rolls.shiny).toBeCloseTo(
      roll(pair.serverSeed, pair.clientSeed, 0, CURSOR.shiny),
      12
    );
  });

  it("the published hash commits the server to the seed it actually used", () => {
    // The contract: the server cannot change serverSeed after publishing
    // serverSeedHash without breaking the hash. Tampering must be detectable.
    const pair = createSeedPair("client-tamper");
    const tampered = newServerSeed();
    expect(hashSeed(tampered)).not.toBe(pair.serverSeedHash);
  });
});

describe("lootbox — seed rotation retires the old pair correctly", () => {
  it("rotateSeed reveals the old serverSeed and retires it", () => {
    const before = state.current;
    const oldServerSeed = before.serverSeed;
    const oldHash = before.serverSeedHash;

    const revealed = state.rotateSeed();

    // The retired pair is the one that was current.
    expect(revealed.serverSeed).toBe(oldServerSeed);
    expect(revealed.serverSeedHash).toBe(oldHash);
    expect(revealed.retiredAt).not.toBeNull();
    expect(state.retired).toContain(revealed);
  });

  it("rotateSeed commits a fresh pair with a different serverSeed + hash", () => {
    const oldSeed = state.current.serverSeed;
    const oldHash = state.current.serverSeedHash;

    state.rotateSeed();

    expect(state.current.serverSeed).not.toBe(oldSeed);
    expect(state.current.serverSeedHash).not.toBe(oldHash);
    expect(state.current.retiredAt).toBeNull();
    expect(state.current.nonce).toBe(0);
  });

  it("after rotation, the old pair's hash still verifies against its revealed seed", () => {
    const revealed = state.rotateSeed();
    expect(hashSeed(revealed.serverSeed)).toBe(revealed.serverSeedHash);
  });

  it("rotation preserves the client seed (player's entropy carries over)", () => {
    state.setClientSeed("my-entropy");
    state.rotateSeed();
    expect(state.current.clientSeed).toBe("my-entropy");
  });

  it("a roll under the retired seed can be recomputed from the revealed inputs", () => {
    const pair = state.current;
    const crate = CRATES["starter-crate"];
    // Make one open under the current pair.
    const outcome = openCrate(crate, pair.serverSeed, pair.clientSeed, 0);
    // Now rotate, which reveals the seed.
    const revealed = state.rotateSeed();
    expect(revealed.serverSeed).toBe(pair.serverSeed);

    // Recompute the open from the now-public inputs — must match.
    const recomputed = openCrate(crate, revealed.serverSeed, revealed.clientSeed, 0);
    expect(recomputed.character.id).toBe(outcome.character.id);
    expect(recomputed.power).toBe(outcome.power);
    expect(recomputed.shiny).toBe(outcome.shiny);
  });
});

describe("lootbox — spendKeys refuses to overspend", () => {
  it("starts with STARTING_KEYS keys", () => {
    expect(state.keys).toBe(STARTING_KEYS);
  });

  it("spends keys when balance is sufficient", () => {
    expect(state.spendKeys(1)).toBe(true);
    expect(state.keys).toBe(STARTING_KEYS - 1);
  });

  it("refuses to spend more than the balance", () => {
    expect(state.spendKeys(STARTING_KEYS + 1)).toBe(false);
    expect(state.keys).toBe(STARTING_KEYS); // unchanged
  });

  it("refuses zero and negative amounts", () => {
    // The current implementation only checks `this.keys < amount`, so
    // spendKeys(0) returns true and spendKeys(-5) returns true (and
    // INCREASES the balance). This is a bug — see QA report L-001.
    // The test documents the expected behavior; it will FAIL until L-001
    // is fixed.
    expect(state.spendKeys(0)).toBe(false);
    expect(state.keys).toBe(STARTING_KEYS);

    expect(state.spendKeys(-5)).toBe(false);
    expect(state.keys).toBe(STARTING_KEYS);
  });

  it("spending down to exactly zero succeeds", () => {
    expect(state.spendKeys(STARTING_KEYS)).toBe(true);
    expect(state.keys).toBe(0);
    expect(state.spendKeys(1)).toBe(false);
  });

  it("grantKeys increases the balance", () => {
    state.spendKeys(5);
    expect(state.grantKeys(10)).toBe(STARTING_KEYS - 5 + 10);
  });
});

describe("lootbox — distribution sanity (statistical guard)", () => {
  // Not a strict fairness proof, but catches a grossly broken weight table
  // or an inverted cumulative walk. 1000 draws is enough to flag a tier that
  // never appears or appears far too often.
  it("starter-crate drops every reasonably-likely tier over 1000 opens", () => {
    const crate = CRATES["starter-crate"];
    // Only check tiers with expected count > 10 in 1000 draws
    // (weight / RARITY_TOTAL * 1000 > 10). Rarer tiers (legendary, mythic,
    // secret) are statistically unlikely to appear in 1000 draws and are
    // covered by the cumulative-weight unit test in lootboxEngine instead.
    const RARITY_TOTAL = 1_000_000;
    const likelyTiers = new Set(
      Object.keys(RARITY_TIERS).filter(
        (r) => (RARITY_TIERS[r as keyof typeof RARITY_TIERS].weight / RARITY_TOTAL) * 1000 > 10
      )
    );
    const seen = new Set<string>();

    for (let i = 0; i < 1000; i++) {
      const outcome = openCrate(crate, "server-seed-fixed", "client-seed", i);
      seen.add(outcome.character.rarity);
    }

    // common (80%), uncommon (16%), rare (3.2%) should all appear.
    for (const tier of likelyTiers) {
      expect(seen.has(tier)).toBe(true);
    }
  });

  it("common is the most frequent tier over 1000 opens", () => {
    const crate = CRATES["starter-crate"];
    const counts: Record<string, number> = {};

    for (let i = 0; i < 1000; i++) {
      const outcome = openCrate(crate, "server-seed-fixed", "client-seed", i);
      counts[outcome.character.rarity] = (counts[outcome.character.rarity] ?? 0) + 1;
    }

    // Common has weight 800000 / 1000000 = 80% of the distribution.
    expect(counts["common"]).toBeGreaterThan(counts["rare"] ?? 0);
    expect(counts["common"]).toBeGreaterThan(counts["epic"] ?? 0);
    expect(counts["common"]).toBeGreaterThan(counts["legendary"] ?? 0);
  });

  it("reel has REEL_LENGTH entries with the winner at REEL_WINNER_INDEX", () => {
    const crate = CRATES["starter-crate"];
    const outcome = openCrate(crate, "server-seed-fixed", "client-seed", 0);
    expect(outcome.reel).toHaveLength(60);
    expect(outcome.reel[outcome.reelWinnerIndex]).toBe(outcome.character.id);
  });
});

describe("lootbox — pity guarantees (live path)", () => {
  const crate = CRATES["starter-crate"];
  const EPIC_PLUS = new Set(["epic", "legendary", "mythic", "secret"]);
  const LEGENDARY_PLUS = new Set(["legendary", "mythic", "secret"]);

  it("applyPity forces epic on the 15th open without an epic-or-better", () => {
    const { rarity, forced } = applyPity(crate, "common", { sinceEpic: 14, sinceLegendary: 0 });
    expect(forced).toBe("epic");
    expect(EPIC_PLUS.has(rarity)).toBe(true);
  });

  it("applyPity forces legendary-or-better on the 40th without one", () => {
    const { rarity, forced } = applyPity(crate, "rare", { sinceEpic: 0, sinceLegendary: 39 });
    expect(forced).toBe("legendary");
    expect(LEGENDARY_PLUS.has(rarity)).toBe(true);
  });

  it("a natural epic+ pull resets the epic counter", () => {
    const next = advancePity({ sinceEpic: 7, sinceLegendary: 7 }, "epic");
    expect(next.sinceEpic).toBe(0);
    expect(next.sinceLegendary).toBe(8);
  });

  it("over 39 forced opens, no window exceeds the pity bound", () => {
    // With pity wired, a player can never see 15 opens without Epic+.
    let pity = { sinceEpic: 0, sinceLegendary: 0 };
    for (let i = 0; i < 200; i++) {
      const outcome = openCrate(crate, "pity-seed", "pity-client", i, pity);
      pity = advancePity(pity, outcome.character.rarity);
      expect(pity.sinceEpic).toBeLessThan(15);
      expect(pity.sinceLegendary).toBeLessThan(40);
    }
  });

  it("pityForced is disclosed on the outcome", () => {
    const outcome = openCrate(crate, "pity-seed", "pity-client", 0, { sinceEpic: 14, sinceLegendary: 0 });
    expect(outcome.pityForced).toBe("epic");
    // And the raw roll is still reported for auditability.
    expect(outcome.rolls.rarity).toBeGreaterThanOrEqual(0);
    expect(outcome.rolls.rarity).toBeLessThan(1);
  });
});

describe("lootbox — secret crate joke", () => {
  it("only drops the brainrot roster, always at secret", () => {
    const crate = CRATES["secret-crate"];
    const allowed = new Set(crate.characterIds);
    expect(allowed.size).toBe(5);

    for (let i = 0; i < 40; i++) {
      const outcome = openCrate(crate, "brainrot-seed", "brainrot-client", i);
      expect(outcome.character.rarity).toBe("secret");
      expect(allowed.has(outcome.character.id)).toBe(true);
      expect(CHARACTERS[outcome.character.id].name.length).toBeGreaterThan(0);
    }
  });
});
