import { describe, it, expect, beforeEach } from "vitest";
import { createHash, randomInt } from "crypto";
import {
  createSeedPair,
  publicSeedPair,
  state
} from "./lootboxState";
import {
  openCookbook,
  openCaseRarity,
  pickDesign,
  pickRarity,
  hashSeed,
  roll,
  CURSOR,
  REEL_LENGTH,
  REEL_WINNER_INDEX
} from "./lootboxEngine";
import { COOKBOOKS, COOKBOOK_BY_ID, RARITY_ORDER, mintPool } from "../data/lootTable";
import { RARITY_BANDS, mintValue } from "../game/rarityBands";
import { Rarity } from "../types";

// ============================================================================
// Cookbook fairness tests.
//
// Three properties the provably-fair scheme MUST hold:
//   1. Commit-reveal: SHA256(serverSeed) == serverSeedHash published up front.
//   2. Seed rotation: rotateSeed() retires the old pair and commits a fresh
//      one with a NEW serverSeedHash.
//   3. Published odds: a large simulated run of opens matches each book's
//      printed table within noise, and every mint lands inside its band.
// ============================================================================

beforeEach(() => {
  state.reset();
});

describe("lootbox — commit-reveal hash verifies", () => {
  it("hashSeed(serverSeed) === serverSeedHash on a fresh pair", () => {
    const pair = createSeedPair("client-xyz");
    expect(pair.serverSeedHash).toBe(hashSeed(pair.serverSeed));
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
    const book = COOKBOOK_BY_ID["home-cookbook"];
    const outcome = openCookbook(book, pair.serverSeed, pair.clientSeed, 0);

    expect(outcome.rolls.rarity).toBeCloseTo(
      roll(pair.serverSeed, pair.clientSeed, 0, CURSOR.rarity), 12);
    expect(outcome.rolls.character).toBeCloseTo(
      roll(pair.serverSeed, pair.clientSeed, 0, CURSOR.character), 12);
    expect(outcome.rolls.mintSegment).toBeCloseTo(
      roll(pair.serverSeed, pair.clientSeed, 0, CURSOR.mintSegment), 12);
    expect(outcome.rolls.mintPosition).toBeCloseTo(
      roll(pair.serverSeed, pair.clientSeed, 0, CURSOR.mintPosition), 12);
  });
});

describe("lootbox — seed rotation discloses the old pair", () => {
  it("rotateSeed retires with a fresh commitment", () => {
    const session = state;
    const before = session.current;
    const retired = session.rotateSeed();

    expect(retired.serverSeedHash).toBe(before.serverSeedHash);
    expect(retired.retiredAt).not.toBeNull();
    expect(session.current.serverSeedHash).not.toBe(before.serverSeedHash);
    expect(session.current.nonce).toBe(0);
    // The client seed carries over — only the server's half rotates.
    expect(session.current.clientSeed).toBe(before.clientSeed);
  });

  it("the revealed seed still verifies its published hash", () => {
    const session = state;
    const retired = session.rotateSeed();
    expect(hashSeed(retired.serverSeed)).toBe(retired.serverSeedHash);
  });
});

describe("lootbox — unbiased selection", () => {
  it("no roll becomes an index via % N — floor(unit * N) is the only path", () => {
    // pickDesign is the one roll -> integer-index conversion in the engine.
    // Probe both ends of the unit interval and the boundary cells.
    const pool = mintPool("rare");
    expect(pickDesign(0, "rare")).toBe(pool[0]);
    expect(pickDesign(1 - Number.EPSILON, "rare")).toBe(pool[pool.length - 1]);
    for (let i = 0; i < pool.length; i++) {
      expect(pickDesign((i + 0.5) / pool.length, "rare")).toBe(pool[i]);
    }
  });

  it("pickRarity honours the published table, rarest-first", () => {
    const book = COOKBOOK_BY_ID["master-cookbook"];
    // A roll of 0 lands on the smallest weight (secret), 1-ε on the largest
    // mass — rarest-first ordering keeps tiny intervals reachable.
    expect(RARITY_ORDER).toContain(pickRarity(book.odds, 0));
    expect(pickRarity(book.odds, 0)).toBe("secret");
    expect(pickRarity(book.odds, 1 - Number.EPSILON)).toBe("uncommon");
  });
});

describe("lootbox — cookbook opens", () => {
  it("every open mints a ★1 monster inside its case rarity's band", () => {
    const pair = createSeedPair("dist-client");
    const book = COOKBOOK_BY_ID["chefs-cookbook"];
    for (let nonce = 0; nonce < 200; nonce++) {
      const outcome = openCookbook(book, pair.serverSeed, pair.clientSeed, nonce);
      const band = RARITY_BANDS[outcome.caseRarity];
      expect(outcome.character.rarity).toBe(outcome.caseRarity);
      expect(outcome.baseMintValue).toBeGreaterThanOrEqual(band.min);
      expect(outcome.baseMintValue).toBeLessThanOrEqual(band.max);
      expect(outcome.value).toBe(outcome.baseMintValue); // ★1: no star bonus
      // baseMintValue is the mint roll applied to the band — recompute it.
      expect(outcome.baseMintValue).toBe(
        mintValue(outcome.caseRarity, outcome.rolls.mintSegment, outcome.rolls.mintPosition)
      );
    }
  });

  it("the reel stops on the winner and fills cosmetically", () => {
    const pair = createSeedPair("reel-client");
    const outcome = openCookbook(COOKBOOK_BY_ID["home-cookbook"], pair.serverSeed, pair.clientSeed, 7);
    expect(outcome.reel).toHaveLength(REEL_LENGTH);
    expect(outcome.reelWinnerIndex).toBe(REEL_WINNER_INDEX);
    expect(outcome.reel[REEL_WINNER_INDEX]).toEqual(outcome.character);
  });

  it("a fixed-rarity Case mints exactly that rarity", () => {
    const pair = createSeedPair("case-client");
    for (const rarity of ["rare", "legendary", "secret"] as Rarity[]) {
      const outcome = openCaseRarity(rarity, pair.serverSeed, pair.clientSeed, randomInt(1_000_000));
      expect(outcome.caseRarity).toBe(rarity);
      expect(outcome.character.rarity).toBe(rarity);
      const band = RARITY_BANDS[rarity];
      expect(outcome.baseMintValue).toBeGreaterThanOrEqual(band.min);
      expect(outcome.baseMintValue).toBeLessThanOrEqual(band.max);
    }
  });
});

describe("lootbox — published odds hold over a simulated run", () => {
  it.each(COOKBOOKS.map((b) => [b.id] as const))(
    "%s matches its printed table within noise",
    (id) => {
      const book = COOKBOOK_BY_ID[id];
      const pair = createSeedPair("ev-client");
      const n = 200_000;
      const counts = new Map<Rarity, number>();
      // Roll the rarity cursor directly — the full open also builds a
      // 60-slot reel, which is needless cost for a distribution check.
      for (let nonce = 0; nonce < n; nonce++) {
        const rarityRoll = roll(pair.serverSeed, pair.clientSeed, nonce, CURSOR.rarity);
        const rarity = pickRarity(book.odds, rarityRoll);
        counts.set(rarity, (counts.get(rarity) ?? 0) + 1);
      }
      for (const rarity of RARITY_ORDER) {
        const expected = book.odds[rarity] ?? 0;
        const observed = (counts.get(rarity) ?? 0) / n;
        // Tolerance: 15% relative for rare tiers, absolute 0.2pp for mass tiers.
        const tol = Math.max(0.002, expected * 0.15);
        expect(Math.abs(observed - expected)).toBeLessThanOrEqual(tol);
      }
    },
    60_000
  );
});
