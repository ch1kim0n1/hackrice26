// SQLite migration runner.
//
// Versions live in `PRAGMA user_version`, a 32-bit integer SQLite stores in the
// file header. No bookkeeping table, nothing to bootstrap, and it is already
// set on databases that predate this runner (to 0), which is exactly where the
// first migration expects to start.
//
// Each migration runs in its own transaction and the version bumps inside it,
// so a crash mid-migration rolls back to a consistent, still-labelled state.
// Migrations are append-only: an applied migration is history. Correct it with
// a new one rather than editing it, or databases in the field will skip the fix.

import type { DatabaseSync } from "node:sqlite";

export interface Migration {
  /** 1-based, contiguous, and never reordered once shipped. */
  version: number;
  name: string;
  /** One or more statements; run with db.exec inside a transaction. */
  sql?: string;
  /**
   * Escape hatch for what SQL cannot express here: SQLite has no `IF`, so
   * anything conditional on the existing shape (does this column exist?) or
   * any row-by-row backfill needs JavaScript. Runs after `sql`, same
   * transaction.
   */
  run?: (db: DatabaseSync) => void;
}

/** Thrown with the migration identified, because "SQLITE_ERROR" alone is useless. */
export class MigrationError extends Error {
  cause: unknown;

  constructor(migration: Migration, cause: unknown) {
    const reason = cause instanceof Error ? cause.message : String(cause);
    super(`migration ${migration.version} (${migration.name}) failed: ${reason}`);
    this.name = "MigrationError";
    this.cause = cause;
  }
}

function assertWellFormed(migrations: Migration[]): void {
  migrations.forEach((m, i) => {
    if (!Number.isInteger(m.version) || m.version < 1) {
      throw new Error(`migration "${m.name}" has a non-positive-integer version: ${m.version}`);
    }
    // Contiguous from 1: a gap means a migration was dropped from the list, and
    // a database that already applied it would silently never run the rest.
    if (m.version !== i + 1) {
      throw new Error(
        `migrations must be contiguous from 1: expected version ${i + 1} at index ${i}, got ${m.version} ("${m.name}")`
      );
    }
    if (!m.sql && !m.run) {
      throw new Error(`migration ${m.version} ("${m.name}") does nothing: give it sql, run, or both`);
    }
  });
}

export function currentVersion(db: DatabaseSync): number {
  const row = db.prepare("PRAGMA user_version").get() as { user_version: number } | undefined;
  return row?.user_version ?? 0;
}

/**
 * Applies every migration newer than the database's recorded version and
 * returns the version it ends on.
 *
 * Foreign keys are forced off for the duration. SQLite cannot add a constraint
 * to an existing table, so migrations rebuild tables (create / copy / drop /
 * rename), and the intermediate states legitimately violate the very keys being
 * installed. `PRAGMA foreign_key_check` runs before each commit to prove the
 * end state is sound, and the caller turns enforcement back on afterwards.
 */
export function applyMigrations(db: DatabaseSync, migrations: Migration[]): number {
  assertWellFormed(migrations);

  // Cannot be changed inside a transaction, hence out here.
  db.exec("PRAGMA foreign_keys = OFF;");
  try {
    let version = currentVersion(db);
    for (const migration of migrations) {
      if (migration.version <= version) continue;

      db.exec("BEGIN");
      try {
        if (migration.sql) db.exec(migration.sql);
        if (migration.run) migration.run(db);

        const violations = db.prepare("PRAGMA foreign_key_check").all();
        if (violations.length > 0) {
          throw new Error(
            `left ${violations.length} foreign key violation(s): ${JSON.stringify(violations.slice(0, 5))}`
          );
        }

        // PRAGMA will not take a bound parameter, so this is interpolated --
        // safe only because assertWellFormed proved it is an integer.
        db.exec(`PRAGMA user_version = ${migration.version}`);
        db.exec("COMMIT");
        version = migration.version;
      } catch (err) {
        try {
          db.exec("ROLLBACK");
        } catch {
          // A failed BEGIN leaves nothing to roll back; report the real error.
        }
        throw new MigrationError(migration, err);
      }
    }
    return version;
  } finally {
    db.exec("PRAGMA foreign_keys = ON;");
  }
}
