// Gameplay event stream -> telemetry.gameplay_events hypertable.
// One append per accepted game action (scan, collect, crate open, quest claim,
// achievement, casino play). Powers the analytics.gameplay_hourly aggregate.
import { randomUUID } from "crypto";
import { withPlayer } from "../pg";
import { ensurePlayer } from "./players";

export type GameplayEventType =
  | "scan" | "collect" | "open" | "quest_claim" | "achievement" | "dungeon" | "gym"
  | "cauldron" | "sell" | "merge";

/** Append one accepted-action fact. Player-scoped (RLS applies once the app
 *  connects as the restricted role). Best-effort caller decides error handling. */
export async function recordGameplayEvent(
  playerId: string,
  eventType: GameplayEventType,
  payload: Record<string, unknown> = {}
): Promise<void> {
  await withPlayer(playerId, async (client) => {
    await ensurePlayer(client, playerId);
    await client.query(
      `insert into telemetry.gameplay_events (event_id, occurred_at, player_id, event_type, payload)
       values ($1, now(), $2, $3, $4::jsonb)
       on conflict do nothing`,
      [randomUUID(), playerId, eventType, JSON.stringify(payload)]
    );
  });
}
