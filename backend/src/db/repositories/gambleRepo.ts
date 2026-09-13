// Casino / gambling mirror -> TigerData (issue: casino Postgres schema).
// SQLite stays the source of truth for the live games; when DATABASE_URL is set
// these best-effort mirrors persist authoritative round rows + append to the
// telemetry.gamble_events hypertable (analytics.gamble_hourly rolls it up).
//
// Server-authoritative writes run through withPlayer (RLS player context set),
// which also lets the restricted role read its own rows — except mines layout,
// which is withheld by a column grant (migration 0015).
import { PoolClient } from "pg";
import { withPlayer } from "../pg";
import { ensurePlayer } from "./players";

type GambleMode = "crash" | "mines" | "plinko" | "wheel";

async function recordGambleEvent(
  client: PoolClient,
  playerId: string,
  mode: GambleMode,
  outcome: string,
  wagerValue: number,
  multiplier: number | null,
  netWorthChange: number,
  refId: string
): Promise<void> {
  await client.query(
    `insert into telemetry.gamble_events
       (occurred_at, player_id, mode, outcome, wager_value, multiplier, net_worth_change, ref_id)
     values (now(), $1, $2, $3, $4, $5, $6, $7)`,
    [playerId, mode, outcome, Math.round(wagerValue), multiplier, Math.round(netWorthChange), refId]
  );
}

// --- Kitchen Mines --------------------------------------------------------
export interface MinesRoundMirror {
  roundId: string;
  playerId: string;
  wager: unknown;
  wagerValue: number;
  mines: number;
  layout: number[];
  revealed: number[];
  status: "ACTIVE" | "SERVED" | "BURNT";
  startedAt: string;
  cashOutMultiplier?: number | null;
  finalNetWorth?: number | null;
  reward?: unknown | null;
  completedAt?: string | null;
  fairness: unknown;
}

export async function mirrorMinesRound(r: MinesRoundMirror): Promise<void> {
  await withPlayer(r.playerId, async (client) => {
    await ensurePlayer(client, r.playerId);
    await client.query(
      `insert into app.mines_rounds
         (round_id, player_id, wager, wager_value, mines, layout, revealed, status,
          started_at, cash_out_multiplier, final_net_worth, reward, completed_at, fairness)
       values ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14)
       on conflict (round_id) do update set
         revealed = excluded.revealed, status = excluded.status,
         cash_out_multiplier = excluded.cash_out_multiplier,
         final_net_worth = excluded.final_net_worth, reward = excluded.reward,
         completed_at = excluded.completed_at`,
      [r.roundId, r.playerId, JSON.stringify(r.wager), r.wagerValue, r.mines, r.layout, r.revealed,
       r.status, r.startedAt, r.cashOutMultiplier ?? null, r.finalNetWorth ?? null,
       r.reward ? JSON.stringify(r.reward) : null, r.completedAt ?? null, JSON.stringify(r.fairness)]
    );
    if (r.status !== "ACTIVE") {
      await recordGambleEvent(client, r.playerId, "mines", r.status === "SERVED" ? "served" : "burnt",
        r.wagerValue, r.cashOutMultiplier ?? null, (r.finalNetWorth ?? 0) - r.wagerValue, r.roundId);
    }
  });
}

// --- Plinko ---------------------------------------------------------------
export interface PlinkoDropMirror {
  dropId: string;
  playerId: string;
  wager: unknown;
  wagerValue: number;
  path: boolean[];
  slot: number;
  multiplier: number;
  finalNetWorth: number;
  reward?: unknown | null;
  createdAt: string;
  fairness: unknown;
}

export async function mirrorPlinkoDrop(d: PlinkoDropMirror): Promise<void> {
  await withPlayer(d.playerId, async (client) => {
    await ensurePlayer(client, d.playerId);
    await client.query(
      `insert into app.plinko_drops
         (drop_id, player_id, wager, wager_value, path, slot, multiplier, final_net_worth, reward, created_at, fairness)
       values ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11)
       on conflict (drop_id) do nothing`,
      [d.dropId, d.playerId, JSON.stringify(d.wager), d.wagerValue, d.path, d.slot, d.multiplier,
       d.finalNetWorth, d.reward ? JSON.stringify(d.reward) : null, d.createdAt, JSON.stringify(d.fairness)]
    );
    await recordGambleEvent(client, d.playerId, "plinko", d.multiplier === 0 ? "busted" : "dropped",
      d.wagerValue, d.multiplier, d.finalNetWorth - d.wagerValue, d.dropId);
  });
}

// --- Portal Wheel ---------------------------------------------------------
export interface PortalWheelSpinMirror {
  spinId: string;
  playerId: string;
  wager: unknown;
  wagerValue: number;
  pick: string;
  section: number;
  winningColor: string;
  won: boolean;
  multiplier: number;
  finalNetWorth: number;
  reward?: unknown | null;
  createdAt: string;
  fairness: unknown;
}

export async function mirrorPortalWheelSpin(s: PortalWheelSpinMirror): Promise<void> {
  await withPlayer(s.playerId, async (client) => {
    await ensurePlayer(client, s.playerId);
    await client.query(
      `insert into app.portal_wheel_spins
         (spin_id, player_id, wager, wager_value, pick, section, winning_color, won,
          multiplier, final_net_worth, reward, created_at, fairness)
       values ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13)
       on conflict (spin_id) do nothing`,
      [s.spinId, s.playerId, JSON.stringify(s.wager), s.wagerValue, s.pick, s.section,
       s.winningColor, s.won, s.multiplier, s.finalNetWorth,
       s.reward ? JSON.stringify(s.reward) : null, s.createdAt, JSON.stringify(s.fairness)]
    );
    await recordGambleEvent(client, s.playerId, "wheel", s.won ? "won" : "lost",
      s.wagerValue, s.multiplier, s.finalNetWorth - s.wagerValue, s.spinId);
  });
}

// --- Cauldron Crash -------------------------------------------------------
export interface CauldronRoundMirror {
  roundId: string;
  playerId: string;
  wager: unknown;                 // array of monsters
  startingNetWorth: number;
  crashMultiplier: number;
  status: "ACTIVE" | "CASHED_OUT" | "CRASHED";
  startedAt: string;
  cashOutAt?: string | null;
  cashOutMultiplier?: number | null;
  finalNetWorth?: number | null;
  reward?: unknown | null;
  completedAt?: string | null;
  fairness: unknown;
}

export async function mirrorCauldronRound(r: CauldronRoundMirror): Promise<void> {
  await withPlayer(r.playerId, async (client) => {
    await ensurePlayer(client, r.playerId);
    await client.query(
      `insert into app.cauldron_rounds
         (round_id, player_id, wager, starting_net_worth, crash_multiplier, status,
          started_at, cash_out_at, cash_out_multiplier, final_net_worth, reward, fairness, completed_at)
       values ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13)
       on conflict (round_id) do update set
         status = excluded.status, cash_out_at = excluded.cash_out_at,
         cash_out_multiplier = excluded.cash_out_multiplier, final_net_worth = excluded.final_net_worth,
         reward = excluded.reward, completed_at = excluded.completed_at`,
      [r.roundId, r.playerId, JSON.stringify(r.wager), Math.round(r.startingNetWorth), r.crashMultiplier,
       r.status, r.startedAt, r.cashOutAt ?? null, r.cashOutMultiplier ?? null, r.finalNetWorth ?? null,
       r.reward ? JSON.stringify(r.reward) : null, JSON.stringify(r.fairness), r.completedAt ?? null]
    );
    if (r.status !== "ACTIVE") {
      await recordGambleEvent(client, r.playerId, "crash", r.status === "CASHED_OUT" ? "cashed_out" : "crashed",
        r.startingNetWorth, r.cashOutMultiplier ?? null, (r.finalNetWorth ?? 0) - r.startingNetWorth, r.roundId);
    }
  });
}
