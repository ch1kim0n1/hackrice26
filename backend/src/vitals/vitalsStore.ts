// Snapshot history, scoped per player and persisted to SQLite (issue #23).
//
// Health data stays out of Git and out of sight by living in the local
// database file (data/nutriquest.db, override with NUTRIQUEST_DB); a restart
// no longer wipes a player's history. Each player (X-Player-Id header) gets
// an isolated history — one client can never read another's snapshots.

import { StoredSnapshot } from "../types";
import { db } from "../db";

export const MAX_SNAPSHOTS = Number(process.env.MAX_SNAPSHOTS ?? 100);

class VitalsStore {
  constructor(private readonly playerId: string) {}

  add(entry: StoredSnapshot): void {
    db.prepare(`INSERT INTO vitals_snapshot (player_id, payload) VALUES (?, ?)`).run(
      this.playerId,
      JSON.stringify(entry)
    );
    // Keep only the newest MAX_SNAPSHOTS rows per player.
    db.prepare(
      `DELETE FROM vitals_snapshot WHERE player_id = ? AND seq NOT IN (
         SELECT seq FROM vitals_snapshot WHERE player_id = ? ORDER BY seq DESC LIMIT ?
       )`
    ).run(this.playerId, this.playerId, MAX_SNAPSHOTS);
  }

  get count(): number {
    return Number(
      (db.prepare(`SELECT COUNT(*) AS n FROM vitals_snapshot WHERE player_id = ?`)
        .get(this.playerId) as any).n
    );
  }

  latest(): StoredSnapshot | undefined {
    const row = db
      .prepare(`SELECT payload FROM vitals_snapshot WHERE player_id = ? ORDER BY seq DESC LIMIT 1`)
      .get(this.playerId) as { payload: string } | undefined;
    return row ? (JSON.parse(row.payload) as StoredSnapshot) : undefined;
  }

  /** Oldest first, capped at `limit`. */
  recent(limit: number): StoredSnapshot[] {
    return (db
      .prepare(`SELECT payload FROM vitals_snapshot WHERE player_id = ? ORDER BY seq DESC LIMIT ?`)
      .all(this.playerId, limit) as any[])
      .map((r) => JSON.parse(r.payload) as StoredSnapshot)
      .reverse();
  }

  /** Clears in place -- callers hold this reference from import time. */
  reset(): void {
    db.prepare(`DELETE FROM vitals_snapshot WHERE player_id = ?`).run(this.playerId);
  }
}

/** Per-player store. Cheap to construct; state lives in SQLite. */
export function vitalsStoreFor(playerId: string): VitalsStore {
  return new VitalsStore(playerId);
}

export function vitalsPlayerCount(): number {
  return Number(
    (db.prepare(`SELECT COUNT(DISTINCT player_id) AS n FROM vitals_snapshot`).get() as any).n
  );
}
