#!/usr/bin/env node
// Applies every .sql file in a directory to DATABASE_URL, in filename order.
//
// Used for backend/seed, which the migration runner deliberately does not touch:
// seeds are fixtures, not schema, and carry no ledger row. Each file goes in as
// one statement batch, so a file that opens its own transaction still behaves.
//
// Through `pg` rather than psql, for the same reason as the other scripts here:
// the CI runner has no postgres-client, and neither does a typical dev machine.
//
//   node scripts/apply-sql-dir.js seed
const { Pool } = require("pg");
const { readdirSync, readFileSync, statSync } = require("fs");
const { join, isAbsolute } = require("path");

async function main() {
  const arg = process.argv[2];
  if (!arg) throw new Error("usage: apply-sql-dir.js <directory>");
  const dir = isAbsolute(arg) ? arg : join(__dirname, "..", arg);
  if (!statSync(dir).isDirectory()) throw new Error(`${dir} is not a directory`);

  // The owner URL: these run DDL, read pg_catalog, and must bypass RLS.
  const connectionString = process.env.DATABASE_URL_ADMIN || process.env.DATABASE_URL;
  if (!connectionString) throw new Error("DATABASE_URL_NOT_SET");

  const pool = new Pool({
    connectionString,
    ssl: /sslmode=require|ssl=true/.test(connectionString)
      ? { rejectUnauthorized: false }
      : undefined,
  });

  const files = readdirSync(dir).filter((f) => f.endsWith(".sql")).sort();
  if (files.length === 0) throw new Error(`no .sql files in ${dir}`);

  for (const file of files) {
    try {
      await pool.query(readFileSync(join(dir, file), "utf8"));
      console.log(`  ok   ${file}`);
    } catch (err) {
      console.error(`  FAIL ${file} -- ${(err && err.message) || err}`);
      await pool.end();
      process.exit(1);
    }
  }

  await pool.end();
  console.log(`\napplied ${files.length} file(s) from ${arg}.`);
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
