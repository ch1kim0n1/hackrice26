// Postgres migration runner with a version ledger (ops.schema_migrations).
//
// Applies backend/migrations/*.sql in filename order, each exactly once, inside
// its own transaction. This is what makes 0008 (non-idempotent continuous
// aggregates) safe to ship: a file that has already run is skipped by version.
//
// For the already-provisioned service db-19576, the ledger was backfilled so
// these runs are no-ops (see db-documentation/08 and CI).
import { readdirSync, readFileSync } from "fs";
import { join } from "path";
import { getAdminPool } from "./pg";

// dist/db -> ../../migrations = backend/migrations (also correct under ts-node).
const MIGRATIONS_DIR = join(__dirname, "..", "..", "migrations");

export async function runMigrations(dir: string = MIGRATIONS_DIR): Promise<string[]> {
  const pool = getAdminPool();
  await pool.query("create schema if not exists ops");
  await pool.query(`
    create table if not exists ops.schema_migrations (
      version    text primary key,
      name       text not null,
      applied_at timestamptz not null default now()
    )`);

  const appliedRows = await pool.query<{ version: string }>(
    "select version from ops.schema_migrations"
  );
  const applied = new Set(appliedRows.rows.map((r) => r.version));

  const files = readdirSync(dir)
    .filter((f) => f.endsWith(".sql"))
    .sort();

  const ran: string[] = [];
  for (const file of files) {
    const version = file.slice(0, 4); // 0001, 0002, ...
    if (applied.has(version)) continue;

    const sql = readFileSync(join(dir, file), "utf8");
    const client = await pool.connect();
    try {
      await client.query("begin");
      await client.query(sql);
      // Some early migrations (0012, 0015) write their own ledger row before
      // this runs. They are applied in the field and migrations are
      // append-only, so they cannot be corrected -- and without the conflict
      // clause their duplicate key aborts the whole migration, which means a
      // database created from empty can never get past 0012.
      await client.query(
        `insert into ops.schema_migrations(version, name) values ($1, $2)
         on conflict (version) do nothing`,
        [version, file]
      );
      await client.query("commit");
      ran.push(file);
    } catch (err) {
      await client.query("rollback");
      throw new Error(`migration ${file} failed: ${(err as Error).message}`);
    } finally {
      client.release();
    }
  }
  return ran;
}

// Allow `node dist/db/migrate-pg.js` (or ts-node) to run migrations directly.
if (require.main === module) {
  runMigrations()
    .then((ran) => {
      console.log(ran.length ? `applied: ${ran.join(", ")}` : "no pending migrations");
      process.exit(0);
    })
    .catch((err) => {
      console.error(err);
      process.exit(1);
    });
}
