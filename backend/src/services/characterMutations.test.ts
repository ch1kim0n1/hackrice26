import { describe, it, expect, beforeAll } from "vitest";

// ============================================================================
// Atomic character mutations (issue #133) + arena escrow (issue #116).
//
// The double-spend class of bugs: the same monster sold AND merged, staked
// AND wagered, settled twice. These tests drive the service directly — the
// "concurrency" here is two mutations racing the same rows, and the contract
// is that the second always loses cleanly.
// ============================================================================

beforeAll(() => {
  process.env.NUTRIQUEST_DB = ":memory:";
});

let counter = 0;
async function playerWithDrops(count: number, value = 600, stars = 1) {
  const { stateFor } = await import("./lootboxState");
  const { testDrop, testCharacter } = await import("../testkit");
  const { rarityForValue } = await import("../game/rarityBands");
  const playerId = `mut_${counter++}_${Date.now()}`;
  const session = stateFor(playerId);
  const character = testCharacter(rarityForValue(value));
  const drops = [];
  for (let i = 0; i < count; i++) {
    drops.push(
      session.record(
        testDrop({
          crateId: "test",
          character,
          stars,
          baseMintValue: value,
          value,
          fairness: { serverSeedHash: "h", clientSeed: "c", nonce: i }
        })
      ).drop
    );
  }
  return { playerId, session, character, drops };
}

/** This test's own drops (and whatever they merged into), filtered out from
 *  the starter roster every fresh player now owns too (services/lootboxState.ts
 *  seedStarterRoster). */
function testDrops(session: Awaited<ReturnType<typeof playerWithDrops>>["session"]) {
  return session.inventory.filter((d) => d.crateId === "test" || d.crateId === "merge");
}

describe("mutation service — locking and double-spend", () => {
  it("merge consumes three drops once; a second merge of the same ids fails", async () => {
    const { mergeDrops, ledgerFor } = await import("./characterMutations");
    const { playerId, session, drops } = await playerWithDrops(3);
    const ids = drops.map((d) => d.id);

    const result = mergeDrops(playerId, ids);
    expect(result.to.star).toBe(2);
    expect(testDrops(session)).toHaveLength(1);

    await expect(async () => mergeDrops(playerId, ids)).rejects.toThrow("NOT_OWNED");
    expect(ledgerFor(playerId).some((l) => l.kind === "merge")).toBe(true);
  });

  it("sell pays coins at net worth and refuses to sell twice", async () => {
    const { sellDrops } = await import("./characterMutations");
    const { coinBalance } = await import("./coins");
    const { sellValue } = await import("../game/revaluation");
    const { playerId, session, character, drops } = await playerWithDrops(2, 1000);
    const before = coinBalance(playerId);

    const expected = sellValue({ baseValue: 1000, rarity: character.rarity, stars: 1 });
    const result = sellDrops(playerId, [drops[0].id]);
    expect(result.coins).toBe(expected);
    expect(result.sold).toHaveLength(1);
    expect(result.sold[0].entryId).toBeTruthy();
    expect(coinBalance(playerId)).toBe(before + expected);

    await expect(async () => sellDrops(playerId, [drops[0].id])).rejects.toThrow("NOT_OWNED");
    // The second attempt is fully rolled back: no extra coin row.
    expect(coinBalance(playerId)).toBe(before + expected);
    expect(testDrops(session)).toHaveLength(1);
  });

  it("a staked monster cannot be sold, merged, or wagered", async () => {
    const { stakeDrops, sellDrops, mergeDrops, wagerDrops } = await import("./characterMutations");
    const { playerId, session, drops } = await playerWithDrops(3);

    stakeDrops(playerId, [drops[0].id], "battle-x");
    expect(session.dropById(drops[0].id)!.lockedBy).toBe("arena:battle-x");

    await expect(async () => sellDrops(playerId, [drops[0].id])).rejects.toThrow("LOCKED");
    await expect(async () => mergeDrops(playerId, drops.map((d) => d.id))).rejects.toThrow("LOCKED");
    await expect(async () => wagerDrops(playerId, [drops[0].id], "cauldron-crash")).rejects.toThrow("NOT_OWNED");

    // Unstaked siblings still work fine.
    const sale = sellDrops(playerId, [drops[1].id]);
    expect(sale.coins).toBeGreaterThan(0);
  });

  it("stake is all-or-nothing: one bad id locks nothing", async () => {
    const { stakeDrops } = await import("./characterMutations");
    const { playerId, session, drops } = await playerWithDrops(2);

    await expect(async () => stakeDrops(playerId, [drops[0].id, "ghost"], "b1")).rejects.toThrow("NOT_OWNED");
    expect(session.dropById(drops[0].id)!.lockedBy).toBeFalsy();
    expect(session.dropById(drops[1].id)!.lockedBy).toBeFalsy();
  });

  it("cannot stake the same monster on two battles", async () => {
    const { stakeDrops } = await import("./characterMutations");
    const { playerId, drops } = await playerWithDrops(1);

    stakeDrops(playerId, [drops[0].id], "b1");
    await expect(async () => stakeDrops(playerId, [drops[0].id], "b2")).rejects.toThrow();
  });
});

describe("arena settlement (#116)", () => {
  it("challenger win: stake returns, coin equivalent paid, ledger written", async () => {
    const { stakeDrops, settleArena, ledgerFor, ARENA_BURN } = await import("./characterMutations");
    const { coinBalance } = await import("./coins");
    const { sellValue } = await import("../game/revaluation");
    const { playerId, session, character, drops } = await playerWithDrops(1, 2000);
    const defender = `def_${Date.now()}`;

    stakeDrops(playerId, [drops[0].id], "arena-1");
    const coinsBefore = coinBalance(playerId);

    const result = settleArena("arena-1", playerId, defender);
    const expected = Math.floor(sellValue({ baseValue: 2000, rarity: character.rarity, stars: 1 }) * (1 - ARENA_BURN));
    expect(result.transferred).toHaveLength(0);
    expect(result.coinsPaid).toBe(expected);
    expect(coinBalance(playerId)).toBe(coinsBefore + expected);
    expect(session.dropById(drops[0].id)!.lockedBy).toBeNull();

    const kinds = ledgerFor(playerId).map((l) => l.kind);
    expect(kinds).toContain("battle_stake");
    expect(kinds).toContain("battle_payout");
    expect(kinds).toContain("battle_refund");
  });

  it("challenger loss: staked monsters transfer to the defender's inventory", async () => {
    const { stakeDrops, settleArena } = await import("./characterMutations");
    const { stateFor } = await import("./lootboxState");
    const { playerId, session, drops } = await playerWithDrops(2);
    const defenderId = `def_${Date.now()}_b`;
    const defenderSession = stateFor(defenderId);

    stakeDrops(playerId, [drops[0].id, drops[1].id], "arena-2");
    const result = settleArena("arena-2", defenderId, playerId);

    expect(result.transferred).toHaveLength(2);
    expect(testDrops(session)).toHaveLength(0);
    expect(testDrops(defenderSession)).toHaveLength(2);
    expect(testDrops(defenderSession).every((d) => !d.lockedBy)).toBe(true);
  });

  it("settlement is once-only: a second settle throws", async () => {
    const { stakeDrops, settleArena } = await import("./characterMutations");
    const { playerId, drops } = await playerWithDrops(1);

    stakeDrops(playerId, [drops[0].id], "arena-3");
    settleArena("arena-3", playerId, "def-x");
    await expect(async () => settleArena("arena-3", playerId, "def-x")).rejects.toThrow();
  });

  it("refund unlocks both sides and marks the stake REFUNDED", async () => {
    const { stakeDrops, refundArena, ledgerFor } = await import("./characterMutations");
    const { playerId, session, drops } = await playerWithDrops(1);

    stakeDrops(playerId, [drops[0].id], "arena-4");
    refundArena("arena-4");
    expect(session.dropById(drops[0].id)!.lockedBy).toBeNull();
    expect(ledgerFor(playerId).some((l) => l.kind === "battle_refund")).toBe(true);

    // And the monster can be spent normally afterwards.
    const { sellDrops } = await import("./characterMutations");
    expect(sellDrops(playerId, [drops[0].id]).coins).toBeGreaterThan(0);
  });
});
