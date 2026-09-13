// The mirror queue: enqueue here, deliver in mirrorDrain.ts.
//
// Replaces `void mirrorX(...).catch(console.warn)`. That pattern meant an
// unreachable Postgres silently discarded the event — every casino round,
// meal and battle mirrored that way had the same hole, and the only trace was
// a warn line.
//
// Enqueue is a synchronous SQLite insert, so a route pays microseconds and
// never awaits Postgres on the request path. Delivery, retry and backoff are
// the drain's problem.
import { db } from "../db";

/** Every stream that mirrors into TigerData. Matches the CHECK in SQLite
 *  migration 012 — adding one here means adding it there. */
export type MirrorKind =
  | "mines_round"
  | "plinko_drop"
  | "portal_wheel_spin"
  | "cauldron_round"
  | "meal_intake"
  | "friend_battle"
  | "gameplay_event"
  | "health_snapshot"
  | "streak_event"
  | "acquisition_event"
  | "dungeon_progress"
  | "coin_entry"
  | "body_metric"
  | "scan_mint"
  | "case_grant"
  | "case_open"
  | "fainted_monster"
  | "battle_match_begin"
  | "owned_character"
  | "squad_snapshot"
  | "promo_redemption"
  | "account_created"
  | "session_event"
  | "profile_update"
  | "player_settings_update";

export interface QueuedMirror {
  id: number;
  kind: MirrorKind;
  payload: unknown;
  idempotencyKey: string;
  attempts: number;
}

/** Retry ceiling. Past this a row moves to mirror_outbox_dead, where it stays
 *  as evidence rather than disappearing. Nine attempts on the backoff below
 *  spans roughly a day, which covers a long outage without retrying forever. */
export const MAX_ATTEMPTS = 9;

/** Exponential with a ceiling: 2s, 4s, 8s ... capped at 30 minutes. */
export function backoffSeconds(attempts: number): number {
  return Math.min(2 ** Math.max(1, attempts), 1800);
}

/**
 * Queue one event for delivery.
 *
 * `idempotencyKey` must identify the *event*, not the attempt — a round id, a
 * drop id. Delivery is at-least-once, so every mirror target upserts on this
 * key and a redelivery is a no-op.
 *
 * Re-enqueueing a key that is already queued replaces its payload and makes it
 * due immediately: the newer state is the one worth sending (a round that has
 * since cashed out supersedes the same round mid-flight).
 */
export function enqueueMirror(
  kind: MirrorKind,
  idempotencyKey: string,
  payload: unknown
): void {
  db.prepare(
    `INSERT INTO mirror_outbox (kind, payload, idempotency_key, next_attempt_at)
     VALUES (?, ?, ?, 0)
     ON CONFLICT(kind, idempotency_key) DO UPDATE SET
       payload         = excluded.payload,
       next_attempt_at = 0,
       last_error      = NULL`
  ).run(kind, JSON.stringify(payload), idempotencyKey);
}

/** Due rows, oldest first. */
export function claimDue(limit: number): QueuedMirror[] {
  const now = Math.floor(Date.now() / 1000);
  const rows = db
    .prepare(
      `SELECT id, kind, payload, idempotency_key, attempts
         FROM mirror_outbox
        WHERE next_attempt_at <= ?
        ORDER BY id
        LIMIT ?`
    )
    .all(now, limit) as unknown as {
    id: number;
    kind: MirrorKind;
    payload: string;
    idempotency_key: string;
    attempts: number;
  }[];

  return rows.map((r) => ({
    id: r.id,
    kind: r.kind,
    payload: JSON.parse(r.payload) as unknown,
    idempotencyKey: r.idempotency_key,
    attempts: r.attempts,
  }));
}

/** Delivered. The row has done its job. */
export function markDelivered(id: number): void {
  db.prepare(`DELETE FROM mirror_outbox WHERE id = ?`).run(id);
}

/**
 * Delivery failed. Schedule a retry, or retire the row once it has had enough
 * chances — retired rows move to mirror_outbox_dead rather than vanishing, so
 * a payload Postgres will never accept is something you can go and read.
 */
export function markFailed(id: number, error: string): "retry" | "dead" {
  const row = db
    .prepare(`SELECT attempts FROM mirror_outbox WHERE id = ?`)
    .get(id) as unknown as { attempts: number } | undefined;
  if (!row) return "retry";

  const attempts = row.attempts + 1;
  if (attempts >= MAX_ATTEMPTS) {
    db.exec("BEGIN");
    try {
      db.prepare(
        `INSERT OR REPLACE INTO mirror_outbox_dead
           (id, kind, payload, idempotency_key, attempts, last_error, created_at)
         SELECT id, kind, payload, idempotency_key, ?, ?, created_at
           FROM mirror_outbox WHERE id = ?`
      ).run(attempts, error.slice(0, 2000), id);
      db.prepare(`DELETE FROM mirror_outbox WHERE id = ?`).run(id);
      db.exec("COMMIT");
    } catch (err) {
      db.exec("ROLLBACK");
      throw err;
    }
    return "dead";
  }

  const nextAt = Math.floor(Date.now() / 1000) + backoffSeconds(attempts);
  db.prepare(
    `UPDATE mirror_outbox
        SET attempts = ?, next_attempt_at = ?, last_error = ?
      WHERE id = ?`
  ).run(attempts, nextAt, error.slice(0, 2000), id);
  return "retry";
}

/** Queue depth, for the readiness probe and for tests. */
export function queueStats(): { pending: number; dead: number; oldestPendingId: number | null } {
  const pending = (
    db.prepare(`SELECT count(*) AS n FROM mirror_outbox`).get() as unknown as { n: number }
  ).n;
  const dead = (
    db.prepare(`SELECT count(*) AS n FROM mirror_outbox_dead`).get() as unknown as { n: number }
  ).n;
  const oldest = db.prepare(`SELECT min(id) AS id FROM mirror_outbox`).get() as unknown as {
    id: number | null;
  };
  return { pending, dead, oldestPendingId: oldest.id ?? null };
}
