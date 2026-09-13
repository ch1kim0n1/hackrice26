// SQLite persistence for all per-player game state (issue #23).
//
// Every player-scoped store (lootbox sessions, profiles, scan collections,
// vitals history) survives restarts and can be shared by multiple processes
// behind the same file. Stores keep their in-memory class interfaces and
// write through synchronously — route code never touches SQL.
//
// The database lives at data/nutriquest.db by default. Override with
// NUTRIQUEST_DB (use "memory" for an ephemeral in-memory database, which
// tests and throwaway demo sessions can set to avoid touching disk).
// node:sqlite is built into Node >= 22.5, so there is no native dependency.

import { DatabaseSync } from "node:sqlite";
import { mkdirSync } from "fs";
import path from "path";
import { applyMigrations } from "./db/migrate";
import { migrations } from "./db/migrations";

export const DEFAULT_DB_PATH = path.join("data", "nutriquest.db");

export function openDatabase(filePath: string): DatabaseSync {
  if (filePath !== ":memory:") {
    mkdirSync(path.dirname(filePath), { recursive: true });
  }
  const db = new DatabaseSync(filePath);
  if (filePath !== ":memory:") db.exec("PRAGMA journal_mode = WAL;");
  // WAL lets readers and a writer coexist, but two writers still contend. Wait
  // for the lock instead of failing the request outright (SQLITE_BUSY) — the
  // store is explicitly shared across processes behind one file.
  db.exec("PRAGMA busy_timeout = 5000;");
  applyMigrations(db, migrations);
  db.exec("PRAGMA foreign_keys = ON;");
  return db;
}

function resolvePath(): string {
  const configured = process.env.NUTRIQUEST_DB;
  if (configured === "memory") return ":memory:";
  if (!configured && (process.env.RAILWAY_ENVIRONMENT || process.env.RAILWAY_SERVICE_ID)) {
    console.warn(
      "[db] NUTRIQUEST_DB is not set and Railway filesystem is ephemeral. " +
        "Attach a persistent volume and set NUTRIQUEST_DB=/data/nutriquest.db."
    );
  }
  return configured || DEFAULT_DB_PATH;
}

/** Process-wide database. Stores import this directly; tests that need a
 *  fresh instance set NUTRIQUEST_DB before dynamically re-importing. */
export const db = openDatabase(resolvePath());

/** Close the process-wide handle explicitly (important on Windows and in tests). */
export function closeDatabase(): void {
  if (db.isOpen) db.close();
}
