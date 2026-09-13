// Battle / PvP mirror -> the marquee TigerData feature.
//
// A resolved friend battle is written as: app.battles (ordinary settlement row) +
// app.battle_participants + telemetry.battle_events (the ordered replay hypertable)
// + telemetry.battle_metrics (per-participant performance hypertable). This is the
// "one database, two storage models" story: relational battle record joined to its
// time-series event stream. Server-authoritative, so it runs as a system transaction
// (both participants written) rather than player-scoped.
import { randomUUID } from "crypto";
import { withTransaction } from "../pg";
import { ensurePlayer } from "./players";

export interface BattleEventIn {
  event?: string;
  [key: string]: unknown;
}

export interface FriendBattleMirror {
  challengerId: string;
  defenderId: string;
  winnerSide: 0 | 1;      // 0 = challenger, 1 = defender
  rounds: number;
  events: BattleEventIn[];
  mode?: string;
  rulesVersion?: string;
}

/** Mirror a resolved friend battle into the relational + hypertable stores.
 *  Returns the generated battle id. */
export async function mirrorFriendBattle(p: FriendBattleMirror): Promise<string> {
  const battleId = randomUUID();
  const streamStart = new Date();
  const endedAt = new Date();
  const mode = p.mode ?? "friendly";
  const rules = p.rulesVersion ?? "v1";

  await withTransaction(async (client) => {
    await ensurePlayer(client, p.challengerId);
    await ensurePlayer(client, p.defenderId);

    await client.query(
      `insert into app.battles
         (id, stream_started_at, mode, rules_version, status, ended_at, settlement_state, last_event_sequence)
       values ($1,$2,$3,$4,'settled',$5,'settled',$6)`,
      [battleId, streamStart, mode, rules, endedAt, p.events.length]
    );

    await client.query(
      `insert into app.battle_participants (battle_id, slot, player_id, is_npc, unit_snapshot)
       values ($1,0,$2,false,'{}'::jsonb), ($1,1,$3,false,'{}'::jsonb)`,
      [battleId, p.challengerId, p.defenderId]
    );

    let seq = 0;
    for (const ev of p.events) {
      seq += 1;
      await client.query(
        `insert into telemetry.battle_events
           (battle_id, stream_started_at, sequence, occurred_at, event_type, payload, payload_version)
         values ($1,$2,$3, now(), $4, $5::jsonb, 'v1')`,
        [battleId, streamStart, seq, String(ev.event ?? "turn"), JSON.stringify(ev)]
      );
    }

    const challengerResult = p.winnerSide === 0 ? "win" : "loss";
    const defenderResult = p.winnerSide === 1 ? "win" : "loss";
    await client.query(
      `insert into telemetry.battle_metrics
         (battle_id, player_id, ended_at, mode, result, rounds)
       values ($1,$2,$3,$4,$5,$6), ($1,$7,$3,$4,$8,$6)`,
      [battleId, p.challengerId, endedAt, mode, challengerResult, p.rounds, p.defenderId, defenderResult]
    );
  });

  return battleId;
}
