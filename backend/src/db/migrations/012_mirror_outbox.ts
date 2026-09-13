import type { Migration } from "../migrate";

/**
 * The mirror queue.
 *
 * Every write to TigerData used to be fire-and-forget:
 *
 *     void mirrorMinesRound(round).catch((err) => console.warn(...));
 *
 * If Postgres was unreachable — a restart, a network blip, a migration in
 * flight — the round was gone. Not delayed, not retried: gone, with a line in
 * a log nobody reads. Every casino round, every meal, every battle mirrored
 * that way had the same hole.
 *
 * This is the durable side of that. The route enqueues a row here (a single
 * synchronous SQLite insert), and `services/mirrorDrain.ts` delivers it,
 * retries it with backoff, and only deletes it once Postgres has accepted it.
 *
 * **What this is not:** a strictly atomic transactional outbox. The enqueue is
 * its own statement immediately after the game-state mutation, not inside the
 * same SQLite transaction, because the mutations live behind service functions
 * that own their own transactions. A crash in the microseconds between the two
 * still loses the enqueue. That window is enormously narrower than "Postgres
 * was down for a minute", which is what actually kept happening, and closing it
 * properly means threading a transaction handle through every service — worth
 * doing, not worth blocking this on.
 *
 * `ops.outbox` exists in the Postgres schema for downstream effects once
 * Postgres is authoritative. It is deliberately not this table: an outbox that
 * guards writes *to* Postgres cannot itself live in Postgres.
 */
export const migration: Migration = {
  version: 12,
  name: "mirror_outbox",
  sql: `
    CREATE TABLE IF NOT EXISTS mirror_outbox (
      id              INTEGER PRIMARY KEY AUTOINCREMENT,
      kind            TEXT NOT NULL CHECK(kind IN (
                        'mines_round','plinko_drop','portal_wheel_spin','cauldron_round',
                        'meal_intake','friend_battle','gameplay_event','health_snapshot',
                        'streak_event','acquisition_event','dungeon_progress','coin_entry',
                        'body_metric'
                      )),
      -- The full mirror payload. Stored rather than re-derived because by the
      -- time a retry runs, the live state it came from may have moved on: a
      -- cashed-out round, a sold monster.
      payload         TEXT NOT NULL CHECK(json_valid(payload)),
      -- Dedupe handle. Delivery is at-least-once, so every mirror target is an
      -- upsert keyed on this; a double-send is a no-op rather than a duplicate.
      idempotency_key TEXT NOT NULL,
      attempts        INTEGER NOT NULL DEFAULT 0,
      -- Unix seconds. A row is invisible to the drain until now() reaches this,
      -- which is how backoff is expressed without a scheduler.
      next_attempt_at INTEGER NOT NULL DEFAULT 0,
      last_error      TEXT,
      created_at      TEXT NOT NULL DEFAULT (datetime('now'))
    );

    -- The drain's only query: due rows, oldest first.
    CREATE INDEX IF NOT EXISTS idx_mirror_outbox_due
      ON mirror_outbox(next_attempt_at, id);

    -- Enqueueing the same event twice (a retried request, a double tap) must
    -- not queue two deliveries.
    CREATE UNIQUE INDEX IF NOT EXISTS idx_mirror_outbox_key
      ON mirror_outbox(kind, idempotency_key);

    -- Rows that have failed past the retry ceiling are moved here rather than
    -- deleted, so a bad payload is evidence instead of a silent gap. Nothing
    -- reads this automatically; it is for a human with a question.
    CREATE TABLE IF NOT EXISTS mirror_outbox_dead (
      id              INTEGER PRIMARY KEY,
      kind            TEXT NOT NULL,
      payload         TEXT NOT NULL,
      idempotency_key TEXT NOT NULL,
      attempts        INTEGER NOT NULL,
      last_error      TEXT,
      created_at      TEXT NOT NULL,
      died_at         TEXT NOT NULL DEFAULT (datetime('now'))
    );
  `
};
