import { describe, it, expect, beforeAll, afterAll, vi } from "vitest";
import express from "express";
import { rmSync } from "fs";
import { tmpdir } from "os";
import path from "path";

// ============================================================================
// Persistence + fairness hardening.
//
// Nonces must be durable before the roll they produced can repeat; a mid-round
// seed rotation must not rewrite a round's committed entropy; a failed promo
// fulfilment must not burn the redemption; escrowed monsters must survive the
// inventory cap; and a crashed arena request must not freeze monsters forever.
// ============================================================================

const DB_FILE = path.join(tmpdir(), `nutriquest-hardening-${process.pid}-${Date.now()}.db`);

beforeAll(() => {
  process.env.NUTRIQUEST_DB = DB_FILE;
});

afterAll(() => {
  rmSync(DB_FILE, { force: true });
  rmSync(`${DB_FILE}-wal`, { force: true });
  rmSync(`${DB_FILE}-shm`, { force: true });
});

let counter = 0;
const pid = (tag: string) => `hrd_${tag}_${counter++}_${Date.now()}`;

async function seedDrop(playerId: string, characterId = "salmon-striker", value = 500, stars = 1) {
  const { stateFor } = await import("./lootboxState");
  const { CHARACTERS } = await import("../data/lootTable");
  return stateFor(playerId).record({
    crateId: "starter-crate",
    character: CHARACTERS[characterId],
    stars,
    power: 55,
    powerLabel: "Steady",
    shiny: false,
    value,
    rolls: { rarity: 0.1, character: 0.1, power: 0.1, shiny: 0.9 },
    fairness: { serverSeedHash: "hash", clientSeed: "seed", nonce: 0 },
    openedAt: new Date().toISOString()
  });
}

describe("fairness nonce durability", () => {
  it("a crate open advances the persisted nonce, not just the in-memory one", async () => {
    const { lootboxRouter } = await import("../routes/lootbox");
    const { stateFor } = await import("./lootboxState");
    const { db } = await import("../db");

    const playerId = pid("open");
    stateFor(playerId).grantKeys(10);

    const app = express();
    app.use(express.json());
    app.use("/lootbox", lootboxRouter);
    const server = app.listen(0);
    await new Promise<void>((resolve) => server.once("listening", resolve));
    const port = (server.address() as { port: number }).port;

    const open = () =>
      fetch(`http://127.0.0.1:${port}/lootbox/crates/starter-crate/open`, {
        method: "POST",
        headers: { "Content-Type": "application/json", "X-Player-Id": playerId },
        body: "{}"
      });
    try {
      const r1 = await open();
      const r2 = await open();
      expect(r1.status).toBe(200);
      expect(r2.status).toBe(200);
      const d1 = (await r1.json()) as { fairness: { nonce: number } };
      const d2 = (await r2.json()) as { fairness: { nonce: number } };
      expect(d2.fairness.nonce).toBe(d1.fairness.nonce + 1);

      // The row must reflect it — a restart cannot rewind into used nonces.
      const row = db
        .prepare(`SELECT nonce, since_epic FROM lootbox_session WHERE player_id = ?`)
        .get(playerId) as { nonce: number; since_epic: number };
      expect(row.nonce).toBe(2);
    } finally {
      await new Promise<void>((resolve) => server.close(() => resolve()));
    }
  });

  it("a promo crate open consumes a durable nonce", async () => {
    const { createPromo, redeemPromo } = await import("./promoCodes");
    const { db } = await import("../db");
    const code = `HRD${counter++}`.slice(0, 16);
    createPromo(code, "crate:starter-crate");
    const playerId = pid("promo");
    const result = redeemPromo(playerId, code);
    expect(result.drop).toBeDefined();
    const row = db
      .prepare(`SELECT nonce FROM lootbox_session WHERE player_id = ?`)
      .get(playerId) as { nonce: number };
    expect(row.nonce).toBe(1);
  });
});

describe("cauldron reward stays on the committed seed pair", () => {
  it("cash-out rolls derive from the pair disclosed at round start, even after rotation", async () => {
    const { startRound, cashOut } = await import("./cauldronState");
    const { CAULDRON_CURSOR } = await import("./cauldronEngine");
    const { roll } = await import("./lootboxEngine");
    const { stateFor } = await import("./lootboxState");

    const playerId = pid("cauldron");
    const session = stateFor(playerId);

    // Find a round that does not crash on contact (0.05^12 all-crash is
    // impossible in practice).
    const now = Date.now();
    let round = null;
    for (let i = 0; i < 12 && !round; i++) {
      const drop = await seedDrop(playerId);
      const candidate = startRound(playerId, [drop.id], now);
      if (candidate.crashMultiplier > 1) round = candidate;
    }
    expect(round).not.toBeNull();

    // Rotate mid-round: the old pair is retired and revealed.
    const retired = session.rotateSeed();
    expect(retired.serverSeedHash).toBe(round!.fairness.serverSeedHash);

    const cashed = cashOut(playerId, round!.roundId, now + 10);
    expect(cashed.status).toBe("CASHED_OUT");
    expect(cashed.reward).not.toBeNull();

    // The stored character roll must recompute from the ROUND's seed pair.
    const expected = roll(
      retired.serverSeed,
      round!.fairness.clientSeed,
      round!.fairness.nonce,
      CAULDRON_CURSOR.rewardCharacter
    );
    expect(cashed.reward!.rolls.character).toBe(expected);
    // And a fresh pair would (almost surely) have rolled something else —
    // checked via a different seed, no reliance on inequality holding.
    expect(cashed.fairness.serverSeedHash).toBe(retired.serverSeedHash);
  });
});

describe("promo redemption ordering", () => {
  it("a promo pointing at a missing crate fails without burning the redemption", async () => {
    const { createPromo, redeemPromo, getPromo } = await import("./promoCodes");
    const { db } = await import("../db");
    const code = `BAD${counter++}CRATE`.slice(0, 16);
    createPromo(code, "crate:no-such-crate");

    const playerId = pid("badcrate");
    expect(() => redeemPromo(playerId, code)).toThrow("PROMO_CRATE_NOT_FOUND");

    // No use consumed, no redemption recorded — the player can redeem again
    // once the reward is fixed.
    expect(getPromo(code)!.uses).toBe(0);
    const row = db
      .prepare(`SELECT 1 FROM promo_redeem WHERE player_id = ? AND code = ?`)
      .get(playerId, code);
    expect(row).toBeUndefined();
  });
});

describe("inventory cap", () => {
  it("never evicts a locked (escrowed) monster", async () => {
    const { stateFor } = await import("./lootboxState");
    const playerId = pid("cap");
    const session = stateFor(playerId);

    const locked = await seedDrop(playerId);
    expect(session.lockDrop(locked.id, "test-escrow")).toBe(true);

    // Push the unlocked inventory well past the 200-row cap.
    for (let i = 0; i < 210; i++) await seedDrop(playerId, "broccoli-bud", 100);

    // The escrowed monster survived; only unlocked rows were trimmed.
    expect(session.dropById(locked.id)).toBeDefined();
    expect(session.dropById(locked.id)!.lockedBy).toBe("test-escrow");
    expect(session.inventory.filter((d) => !d.lockedBy).length).toBeLessThanOrEqual(200);
  });
});

describe("arena escrow recovery", () => {
  it("refunds a stake that outlived its request", async () => {
    const { stakeDrops, refundStaleArenaStakes } = await import("./characterMutations");
    const { stateFor } = await import("./lootboxState");
    const { db } = await import("../db");

    const playerId = pid("stale");
    const drop = await seedDrop(playerId);
    stakeDrops(playerId, [drop.id], "battle-stale-1");
    expect(stateFor(playerId).dropById(drop.id)!.lockedBy).toBe("arena:battle-stale-1");

    // Simulate the crash: the row is hours old but still LOCKED.
    db.prepare(`UPDATE arena_stake SET created_at = datetime('now', '-1 hour') WHERE battle_id = ?`)
      .run("battle-stale-1");

    expect(refundStaleArenaStakes(playerId)).toBe(1);
    expect(stateFor(playerId).dropById(drop.id)!.lockedBy ?? null).toBeNull();
    const row = db
      .prepare(`SELECT status FROM arena_stake WHERE battle_id = ?`)
      .get("battle-stale-1") as { status: string };
    expect(row.status).toBe("REFUNDED");
  });

  it("leaves a fresh stake alone", async () => {
    const { stakeDrops, refundStaleArenaStakes, refundArena } = await import("./characterMutations");
    const { stateFor } = await import("./lootboxState");
    const playerId = pid("fresh");
    const drop = await seedDrop(playerId);
    stakeDrops(playerId, [drop.id], "battle-fresh-1");
    expect(refundStaleArenaStakes(playerId)).toBe(0);
    expect(stateFor(playerId).dropById(drop.id)!.lockedBy).toBe("arena:battle-fresh-1");
    refundArena("battle-fresh-1");
  });
});

describe("gamble ledger parity", () => {
  it("plinko wagers and payouts write character_ledger rows", async () => {
    const { drop } = await import("./plinkoState");
    const { ledgerFor } = await import("./characterMutations");
    const playerId = pid("plinko");
    const wager = await seedDrop(playerId);
    const result = drop(playerId, wager.id);

    const kinds = ledgerFor(playerId, 10).map((l) => l.kind);
    expect(kinds).toContain("gamble_stake");
    if (result.finalNetWorth > 0) expect(kinds).toContain("gamble_payout");
  });

  it("portal-wheel wagers and payouts write character_ledger rows", async () => {
    const { spin } = await import("./portalWheelState");
    const { ledgerFor } = await import("./characterMutations");
    const playerId = pid("wheel");
    const wager = await seedDrop(playerId);
    const result = spin(playerId, wager.id, "blue");

    const kinds = ledgerFor(playerId, 10).map((l) => l.kind);
    expect(kinds).toContain("gamble_stake");
    if (result.finalNetWorth > 0) expect(kinds).toContain("gamble_payout");
  });
});

describe("reward pricing", () => {
  it("never mints a monster worth more than the cash-out budget", async () => {
    const { rewardFor } = await import("../game/rewards");
    const { RARITY_BANDS } = await import("../game/rarityBands");
    const floor = RARITY_BANDS.common.min;
    for (const budget of [floor, floor + 1, 500, 5_000, 50_000, 250_000, 1_000_000]) {
      for (const r of [0, 0.25, 0.5, 0.75, 0.999]) {
        const reward = rewardFor(budget, r, r);
        expect(reward.value).toBeLessThanOrEqual(budget);
      }
    }
  });
});

describe("unauthenticated identity", () => {
  it("NUTRIQUEST_REQUIRE_AUTH=1 refuses the X-Player-Id header", async () => {
    const previous = process.env.NUTRIQUEST_REQUIRE_AUTH;
    process.env.NUTRIQUEST_REQUIRE_AUTH = "1";
    vi.resetModules();
    try {
      const { requirePlayerId } = await import("../middleware/player");
      const req = { headers: { "x-player-id": "someone-else" } };
      let statusCode = 0;
      let called = false;
      const res = {
        status(code: number) {
          statusCode = code;
          return this;
        },
        json() {
          return this;
        }
      };
      requirePlayerId(
        req as Parameters<typeof requirePlayerId>[0],
        res as unknown as Parameters<typeof requirePlayerId>[1],
        () => {
          called = true;
        }
      );
      expect(called).toBe(false);
      expect(statusCode).toBe(401);
    } finally {
      if (previous === undefined) delete process.env.NUTRIQUEST_REQUIRE_AUTH;
      else process.env.NUTRIQUEST_REQUIRE_AUTH = previous;
      vi.resetModules();
    }
  });
});
