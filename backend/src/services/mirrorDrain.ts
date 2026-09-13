// Delivers what mirrorQueue enqueued.
//
// One loop, started at boot when DATABASE_URL is set. It takes due rows,
// hands each to the repository that knows how to write it, and deletes the row
// only once Postgres has accepted it. A failure is rescheduled with backoff
// rather than discarded, which is the entire point of the queue.
//
// Delivery is at-least-once: a process that dies between the Postgres write
// and the row delete will send that event again. Every target below is an
// upsert keyed on the event's own id, so a redelivery is a no-op.
import { hasDatabaseUrl } from "../db/pg";
import {
  MirrorKind,
  QueuedMirror,
  claimDue,
  markDelivered,
  markFailed,
} from "./mirrorQueue";

import {
  mirrorCauldronRound,
  mirrorMinesRound,
  mirrorPlinkoDrop,
  mirrorPortalWheelSpin,
} from "../db/repositories/gambleRepo";
import { mirrorMealIntake } from "../db/repositories/nutritionRepo";
import { mirrorFriendBattle } from "../db/repositories/battleRepo";
import { recordGameplayEvent } from "../db/repositories/gameEventsRepo";
import { mirrorSnapshot, recordBodyMetric } from "../db/repositories/healthRepo";
import {
  recordAcquisitionEvent,
  recordDungeonProgress,
  recordStreakEvent,
} from "../db/repositories/telemetryRepo";
import { recordCoinsPg } from "./coinsPg";

/** How many rows one pass will attempt. Small: a pass holds no transaction and
 *  the loop comes round again immediately when there is more to do. */
const BATCH = 25;

/** Idle poll interval. Fast enough that a mirror lands within a couple of
 *  seconds in the normal case, slow enough to be free when the queue is empty. */
const IDLE_MS = 2_000;

type Deliver = (payload: never) => Promise<unknown>;

const DELIVERERS: Record<MirrorKind, Deliver> = {
  mines_round: mirrorMinesRound as Deliver,
  plinko_drop: mirrorPlinkoDrop as Deliver,
  portal_wheel_spin: mirrorPortalWheelSpin as Deliver,
  cauldron_round: mirrorCauldronRound as Deliver,
  meal_intake: (p: never) => {
    const { playerId, meal } = p as unknown as { playerId: string; meal: unknown };
    return mirrorMealIntake(playerId, meal as never);
  },
  friend_battle: mirrorFriendBattle as Deliver,
  gameplay_event: (p: never) => {
    const e = p as unknown as { playerId: string; type: string; detail?: unknown };
    return recordGameplayEvent(e.playerId, e.type as never, e.detail as never);
  },
  health_snapshot: (p: never) => {
    const s = p as unknown as { playerId: string; snapshot: unknown };
    return mirrorSnapshot(s.playerId, s.snapshot as never);
  },
  streak_event: recordStreakEvent as Deliver,
  acquisition_event: recordAcquisitionEvent as Deliver,
  dungeon_progress: recordDungeonProgress as Deliver,
  // The authoritative coin write. Idempotent on the entry id the SQLite side
  // generated, so an at-least-once redelivery credits nothing twice.
  body_metric: (p: never) => {
    const b = p as unknown as { playerId: string; metric: unknown };
    return recordBodyMetric(b.playerId, b.metric as never);
  },
  coin_entry: (p: never) => {
    const e = p as unknown as {
      id: string; playerId: string; amount: number; reason: string; refId: string | null;
    };
    return recordCoinsPg(e.playerId, e.id, e.amount, e.reason as never, e.refId ?? null);
  },
};

let timer: NodeJS.Timeout | null = null;
let running = false;
let stopped = false;

/** Deliver one row. Returns true when the queue should keep going immediately. */
async function deliver(item: QueuedMirror): Promise<void> {
  const handler = DELIVERERS[item.kind];
  if (!handler) {
    // An unknown kind cannot succeed by being retried. Retire it so it stops
    // occupying the head of the queue behind rows that would deliver fine.
    markFailed(item.id, `no deliverer registered for kind "${item.kind}"`);
    return;
  }
  try {
    await handler(item.payload as never);
    markDelivered(item.id);
  } catch (err) {
    const message = (err as Error).message ?? String(err);
    const fate = markFailed(item.id, message);
    if (fate === "dead") {
      console.error(
        `[mirror-drain] giving up on ${item.kind} ${item.idempotencyKey} after ` +
          `repeated failures; moved to mirror_outbox_dead. Last error: ${message}`
      );
    }
  }
}

/** One pass over the due rows. Exported so a test can drive the queue without
 *  waiting on the timer. Returns how many rows it attempted. */
export async function drainOnce(limit = BATCH): Promise<number> {
  if (!hasDatabaseUrl()) return 0;
  const due = claimDue(limit);
  for (const item of due) {
    if (stopped) break;
    await deliver(item);
  }
  return due.length;
}

async function tick(): Promise<void> {
  if (running || stopped) return;
  running = true;
  try {
    // Keep going while a full batch comes back — a backlog after an outage
    // should clear at the speed Postgres accepts it, not one batch per poll.
    let attempted = 0;
    do {
      attempted = await drainOnce();
    } while (attempted === BATCH && !stopped);
  } catch (err) {
    // The loop itself failing (SQLite unreadable, say) must not kill the timer.
    console.error(`[mirror-drain] pass failed: ${(err as Error).message}`);
  } finally {
    running = false;
  }
}

/** Start the background drain. No-op without DATABASE_URL, so the SQLite-only
 *  dev and test setups are unaffected. */
export function startMirrorDrain(): void {
  if (timer || !hasDatabaseUrl()) return;
  stopped = false;
  timer = setInterval(() => void tick(), IDLE_MS);
  // Do not hold the process open for the sake of an empty queue.
  timer.unref?.();
}

export function stopMirrorDrain(): void {
  stopped = true;
  if (timer) {
    clearInterval(timer);
    timer = null;
  }
}
