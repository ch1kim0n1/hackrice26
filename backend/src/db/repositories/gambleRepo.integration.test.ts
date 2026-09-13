// Integration tests for the casino mirrors against live Tiger Cloud. Gated on
// DATABASE_URL. Run:
//   DATABASE_URL="$(TIGER_READ_ONLY=prod tiger db connection-string <id> --with-password)" \
//     npx vitest run gambleRepo.integration
import { randomUUID } from "crypto";
import { afterAll, describe, expect, it } from "vitest";
import { getPool, closePool } from "../pg";
import { mirrorPlinkoDrop, mirrorMinesRound, mirrorCauldronRound } from "./gambleRepo";

const RUN = Boolean(process.env.DATABASE_URL);
const suite = RUN ? describe : describe.skip;

suite("casino mirrors (integration)", () => {
  const p = `p_ittest_${Date.now()}_g`;
  const iso = new Date().toISOString();

  afterAll(async () => {
    await getPool().query("delete from app.players where id = $1", [p]);
    await closePool();
  });

  it("mirrors a plinko drop + emits a gamble event", async () => {
    await mirrorPlinkoDrop({
      dropId: randomUUID(), playerId: p, wager: { id: "x" }, wagerValue: 1000,
      path: [true, false, true, true, false, false, true, false, true, false, true, false],
      slot: 6, multiplier: 1.5, finalNetWorth: 1500, reward: { id: "x", budget: 1500 },
      createdAt: iso, fairness: { serverSeedHash: "h", clientSeed: "c", nonce: 1 },
    });
    const drops = await getPool().query("select count(*)::int n from app.plinko_drops where player_id=$1", [p]);
    expect(drops.rows[0].n).toBe(1);
    const ev = await getPool().query("select count(*)::int n from telemetry.gamble_events where player_id=$1 and mode='plinko'", [p]);
    expect(ev.rows[0].n).toBe(1);
  });

  it("mirrors a served mines round and hides the layout from the restricted role", async () => {
    const roundId = randomUUID();
    await mirrorMinesRound({
      roundId, playerId: p, wager: { id: "y" }, wagerValue: 2000, mines: 3,
      layout: [1, 5, 9], revealed: [0, 2, 4], status: "SERVED", startedAt: iso,
      cashOutMultiplier: 2.0, finalNetWorth: 4000, reward: { id: "y", budget: 4000 },
      completedAt: iso, fairness: { serverSeedHash: "h", clientSeed: "c", nonce: 2 },
    });
    const row = await getPool().query("select status, final_net_worth from app.mines_rounds where round_id=$1", [roundId]);
    expect(row.rows[0].status).toBe("SERVED");

    // Restricted role must NOT be able to read the mine layout.
    const client = await getPool().connect();
    let denied = false;
    try {
      await client.query("begin");
      await client.query("set local role nutriquest_app");
      await client.query("select set_config('app.current_player', $1, true)", [p]);
      try {
        await client.query(`select layout from app.mines_rounds where round_id=$1`, [roundId]);
      } catch {
        denied = true;
      }
      await client.query("rollback");
    } finally {
      client.release();
    }
    expect(denied).toBe(true);
  });

  it("mirrors a cashed-out cauldron round", async () => {
    const roundId = randomUUID();
    await mirrorCauldronRound({
      roundId, playerId: p, wager: [{ id: "z" }], startingNetWorth: 3000, crashMultiplier: 5.0,
      status: "CASHED_OUT", startedAt: iso, cashOutAt: iso, cashOutMultiplier: 2.5,
      finalNetWorth: 7500, reward: { id: "z", budget: 7500 }, completedAt: iso,
      fairness: { serverSeedHash: "h", clientSeed: "c", nonce: 3 },
    });
    const row = await getPool().query("select status from app.cauldron_rounds where round_id=$1", [roundId]);
    expect(row.rows[0].status).toBe("CASHED_OUT");
  });

  it("gamble_hourly aggregate reflects the plays (real-time)", async () => {
    const agg = await getPool().query(
      "select sum(plays)::int plays from analytics.gamble_hourly where player_id=$1", [p]
    );
    expect(agg.rows[0].plays).toBeGreaterThanOrEqual(3);
  });
});
