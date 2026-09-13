#!/usr/bin/env node
// Runs backend/tests/db/invariants.sql against DATABASE_URL and reports what it
// asserted.
//
// Goes through `pg` rather than psql so the one dependency is the one the app
// already has: the CI runner has no postgres-client installed, and neither does
// a typical dev machine on Windows.
//
// The SQL file raises on the first failed assertion and rolls back at the end,
// so a clean exit means every invariant held and nothing was left behind.
const { Pool } = require("pg");
const { readFileSync } = require("fs");
const { join } = require("path");

const SQL_FILE = join(__dirname, "..", "tests", "db", "invariants.sql");

async function main() {
  // The owner URL: these run DDL, read pg_catalog, and must bypass RLS.
  const connectionString = process.env.DATABASE_URL_ADMIN || process.env.DATABASE_URL;
  if (!connectionString) throw new Error("DATABASE_URL_NOT_SET");

  const pool = new Pool({
    connectionString,
    ssl: /sslmode=require|ssl=true/.test(connectionString)
      ? { rejectUnauthorized: false }
      : undefined,
  });

  const client = await pool.connect();
  let asserted = 0;

  // The assertions report themselves as NOTICEs; without this the run is silent
  // and a passing suite is indistinguishable from an empty one.
  client.on("notice", (msg) => {
    const text = (msg.message || "").trim();
    if (!text) return;
    if (/^ok(\s|:|\()/i.test(text)) asserted += 1;
    console.log(`  ${text}`);
  });

  try {
    await client.query(readFileSync(SQL_FILE, "utf8"));
  } catch (err) {
    console.error(`\n${(err && err.message) || err}`);
    // The file opens a transaction; a mid-file failure leaves it aborted.
    try {
      await client.query("rollback");
    } catch {
      /* already rolled back */
    }
    client.release();
    await pool.end();
    process.exit(1);
  }

  client.release();
  await pool.end();

  if (asserted === 0) {
    console.error("\nno assertions ran -- the suite is not doing anything.");
    process.exit(1);
  }
  console.log(`\n${asserted} invariants held.`);
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
