// Integration tests for the game/PvP TigerData mirrors (gameplay_events +
// battle events/metrics hypertables). Gated on DATABASE_URL like healthRepo's.
//   DATABASE_URL="$(TIGER_READ_ONLY=prod tiger db connection-string <id> --with-password)" \
//     npx vitest run gameAndBattle.integration
import { afterAll, describe, expect, it } from "vitest";
import { getPool, closePool } from "../pg";
import { recordGameplayEvent } from "./gameEventsRepo";
import { mirrorFriendBattle } from "./battleRepo";

const RUN = Boolean(process.env.DATABASE_URL);
const suite = RUN ? describe : describe.skip;

suite("game + battle mirrors (integration)", () => {
  const p1 = `p_ittest_${Date.now()}_a`;
  const p2 = `p_ittest_${Date.now()}_b`;
  let battleId = "";

  afterAll(async () => {
    if (battleId) {
      await getPool().query("delete from telemetry.battle_events where battle_id = $1", [battleId]);
      await getPool().query("delete from app.battles where id = $1", [battleId]);
    }
    await getPool().query("delete from app.players where id = any($1)", [[p1, p2]]);
    await closePool();
  });

  it("records a gameplay event into the hypertable (auto-creating the player)", async () => {
    await recordGameplayEvent(p1, "scan", { barcode: "0038000138416" });
    const { rows } = await getPool().query(
      "select count(*)::int n from telemetry.gameplay_events where player_id = $1 and event_type = 'scan'",
      [p1]
    );
    expect(rows[0].n).toBe(1);
  });

  it("mirrors a friend battle into relational + event/metric hypertables", async () => {
    battleId = await mirrorFriendBattle({
      challengerId: p1,
      defenderId: p2,
      winnerSide: 0,
      rounds: 3,
      events: [{ event: "start" }, { event: "hit", dmg: 40 }, { event: "victory", winner: "A" }],
    });
    expect(battleId).toMatch(/[0-9a-f-]{36}/);

    const battle = await getPool().query("select status from app.battles where id = $1", [battleId]);
    expect(battle.rows[0].status).toBe("settled");

    const events = await getPool().query(
      "select count(*)::int n from telemetry.battle_events where battle_id = $1",
      [battleId]
    );
    expect(events.rows[0].n).toBe(3);

    const metrics = await getPool().query(
      "select player_id, result from telemetry.battle_metrics where battle_id = $1 order by player_id",
      [battleId]
    );
    expect(metrics.rows).toHaveLength(2);
    const byPlayer = Object.fromEntries(metrics.rows.map((r) => [r.player_id, r.result]));
    expect(byPlayer[p1]).toBe("win");
    expect(byPlayer[p2]).toBe("loss");
  });
});
