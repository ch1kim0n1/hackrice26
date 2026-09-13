// Writers for the three streams added in migration 0020.
//
// Each records something the product already asks the player to care about and
// that nothing was keeping over time: how consistent they have been, how their
// pulls have run, and how deep they are getting.
//
// Every write is an upsert on the event's own key, because the mirror queue
// delivers at-least-once — a redelivery must be a no-op, not a second row that
// inflates a streak or a pull count.
import { withPlayer } from "../pg";
import { ensurePlayer } from "./players";

// --- Consistency ------------------------------------------------------------

export interface StreakEventMirror {
  playerId: string;
  /** The game day this resolution is for, as YYYY-MM-DD. */
  gameDay: string;
  streakLength: number;
  bestStreak: number;
  qualified: boolean;
  freezeUsed?: boolean;
  occurredAt?: string;
}

/** One row per game day resolved. The unique index on
 *  (player_id, game_day, occurred_at) is what stops a retried day-close from
 *  writing a second row and doubling the day in analytics.streak_daily. */
export async function recordStreakEvent(e: StreakEventMirror): Promise<void> {
  await withPlayer(e.playerId, async (client) => {
    await ensurePlayer(client, e.playerId);
    await client.query(
      `insert into telemetry.streak_events
         (player_id, game_day, streak_length, best_streak, qualified, freeze_used, occurred_at)
       values ($1, $2::date, $3, $4, $5, $6, coalesce($7::timestamptz, now()))
       on conflict do nothing`,
      [
        e.playerId,
        e.gameDay,
        Math.max(0, Math.round(e.streakLength)),
        Math.max(0, Math.round(e.bestStreak)),
        e.qualified,
        e.freezeUsed ?? false,
        e.occurredAt ?? null,
      ]
    );
  });
}

// --- Pull luck --------------------------------------------------------------

export interface AcquisitionEventMirror {
  playerId: string;
  sourceKind: "scan" | "dish" | "lootbox" | "fusion" | "promo" | "reward" | "merge";
  rarity: string;
  netWorth: number;
  starLevel?: number;
  /** Drop id / owned-character id. Doubles as the dedupe key. */
  characterRef?: string | null;
  occurredAt?: string;
}

/** One row per monster obtained. `character_ref` is the natural event id, so a
 *  redelivery of the same pull collapses rather than counting twice. */
export async function recordAcquisitionEvent(e: AcquisitionEventMirror): Promise<void> {
  await withPlayer(e.playerId, async (client) => {
    await ensurePlayer(client, e.playerId);
    await client.query(
      `insert into telemetry.acquisition_events
         (player_id, source_kind, rarity, net_worth, star_level, character_ref, occurred_at)
       select $1, $2, $3, $4, $5, $6, coalesce($7::timestamptz, now())
        where $6::text is null
           or not exists (
             select 1 from telemetry.acquisition_events
              where player_id = $1 and character_ref = $6::text
           )`,
      [
        e.playerId,
        e.sourceKind,
        e.rarity,
        Math.max(0, Math.round(e.netWorth)),
        Math.min(5, Math.max(1, Math.round(e.starLevel ?? 1))),
        e.characterRef ?? null,
        e.occurredAt ?? null,
      ]
    );
  });
}

// --- Dungeon depth ----------------------------------------------------------

export interface DungeonProgressMirror {
  playerId: string;
  runRef?: string | null;
  floor: number;
  outcome: "cleared" | "failed" | "retreated";
  squadPower?: number | null;
  occurredAt?: string;
}

/** One row per floor resolved. Keyed on (run, floor) for dedupe: a floor can
 *  only be resolved once within a run. */
export async function recordDungeonProgress(e: DungeonProgressMirror): Promise<void> {
  await withPlayer(e.playerId, async (client) => {
    await ensurePlayer(client, e.playerId);
    await client.query(
      `insert into telemetry.dungeon_progress
         (player_id, run_ref, floor, outcome, squad_power, occurred_at)
       select $1, $2, $3, $4, $5, coalesce($6::timestamptz, now())
        where $2::text is null
           or not exists (
             select 1 from telemetry.dungeon_progress
              where player_id = $1 and run_ref = $2::text and floor = $3
           )`,
      [
        e.playerId,
        e.runRef ?? null,
        Math.max(0, Math.round(e.floor)),
        e.outcome,
        e.squadPower === undefined || e.squadPower === null ? null : Math.round(e.squadPower),
        e.occurredAt ?? null,
      ]
    );
  });
}
