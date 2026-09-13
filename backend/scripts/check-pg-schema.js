#!/usr/bin/env node
// Post-migration acceptance checks for the TigerData schema.
//
// Runs against whatever DATABASE_URL points at, straight after
// `node dist/db/migrate-pg.js`. Plain JS on purpose: no build step stands
// between a broken schema and this failing.
//
// The counting smoke test this replaces asserted ">= 6 hypertables, >= 4
// continuous aggregates" and had been true-but-stale since 0012; it would not
// have caught any of the three drifts that actually happened:
//   * a migration file present in the repo but never applied (0016),
//   * a table applied to the live service with no migration file (0013/0014),
//   * a player-owned table shipped without row-level security (0012).
const { Pool } = require("pg");
const { readdirSync } = require("fs");
const { join } = require("path");

const MIGRATIONS_DIR = join(__dirname, "..", "migrations");
const failures = [];
const check = (ok, label, detail) => {
  if (ok) return console.log(`  ok   ${label}`);
  failures.push(label);
  console.error(`  FAIL ${label}${detail ? ` -- ${detail}` : ""}`);
};

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

  // 1. Every migration file on disk is recorded as applied, and nothing is
  //    recorded that has no file. Either direction means the repo and the
  //    database have stopped describing each other.
  const onDisk = readdirSync(MIGRATIONS_DIR).filter((f) => f.endsWith(".sql")).sort();
  const { rows: ledger } = await pool.query("select version, name from ops.schema_migrations");
  const applied = new Set(ledger.map((r) => r.version));
  const versions = onDisk.map((f) => f.slice(0, 4));

  const unapplied = onDisk.filter((f) => !applied.has(f.slice(0, 4)));
  check(unapplied.length === 0, "every migration file is applied", unapplied.join(", "));

  const orphaned = ledger.filter((r) => !versions.includes(r.version));
  check(orphaned.length === 0, "every applied version has a migration file",
    orphaned.map((r) => `${r.version} (${r.name})`).join(", "));

  // Contiguous from 0001: a gap is how 0013/0014 went missing unnoticed.
  const gaps = versions.filter((v, i) => Number(v) !== i + 1);
  check(gaps.length === 0, "migration versions are contiguous from 0001", gaps.join(", "));

  // 2. Row-level security on every player-owned table. Columnstore hypertables
  //    are exempt -- Timescale does not support RLS there, and 0011 documents it.
  const { rows: leaky } = await pool.query(`
    select n.nspname || '.' || c.relname as tbl
      from pg_class c
      join pg_namespace n on n.oid = c.relnamespace
      join information_schema.columns col
        on col.table_schema = n.nspname
       and col.table_name   = c.relname
       and col.column_name  = 'player_id'
      left join timescaledb_information.hypertables h
        on h.hypertable_schema = n.nspname
       and h.hypertable_name   = c.relname
     where c.relkind in ('r', 'p')
       and n.nspname in ('app', 'telemetry')
       and c.relrowsecurity = false
       and coalesce(h.compression_enabled, false) = false
     order by 1`);
  check(leaky.length === 0, "every uncompressed player-owned table has RLS",
    leaky.map((r) => r.tbl).join(", "));

  // 3. Every RLS-enabled table actually carries a policy. Enabled with no policy
  //    is default-deny, which fails closed but silently.
  const { rows: policyless } = await pool.query(`
    select n.nspname || '.' || c.relname as tbl
      from pg_class c
      join pg_namespace n on n.oid = c.relnamespace
     where c.relkind in ('r', 'p')
       and n.nspname in ('app', 'telemetry')
       and c.relrowsecurity
       and not exists (select 1 from pg_policy p where p.polrelid = c.oid)
     order by 1`);
  check(policyless.length === 0, "every RLS-enabled table has a policy",
    policyless.map((r) => r.tbl).join(", "));

  // 4. The restricted runtime role can write everything the app writes. A revoke
  //    that is never followed by a re-grant (0015 on app.mines_rounds) is
  //    invisible until production, because the mirror only console.warn's.
  //
  //    has_any_column_privilege, not has_table_privilege: app.mines_rounds is
  //    granted per column on purpose, and a column-level grant does not register
  //    as a table-level one. A table-wide grant satisfies this too, so the same
  //    test is correct for every row below.
  const writable = [
    ["app.cauldron_rounds", "INSERT"], ["app.cauldron_rounds", "UPDATE"],
    ["app.mines_rounds", "INSERT"], ["app.mines_rounds", "UPDATE"],
    ["app.plinko_drops", "INSERT"],
    ["app.portal_wheel_spins", "INSERT"],
    ["telemetry.gamble_events", "INSERT"],
    ["telemetry.body_metrics", "INSERT"],
    ["telemetry.streak_events", "INSERT"],
    ["telemetry.acquisition_events", "INSERT"],
    ["telemetry.dungeon_progress", "INSERT"],
  ];
  for (const [table, priv] of writable) {
    const { rows } = await pool.query(
      "select has_any_column_privilege('nutriquest_app', $1, $2) as ok", [table, priv]);
    check(rows[0].ok === true, `nutriquest_app may ${priv} ${table}`);
  }

  // 5. Kitchen Mines is server-authoritative: the board is written once, at the
  //    start of the round, and is never readable or rewritable by the app role.
  const layoutPrivs = [["INSERT", true], ["SELECT", false], ["UPDATE", false]];
  for (const [priv, want] of layoutPrivs) {
    const { rows } = await pool.query(
      "select has_column_privilege('nutriquest_app', 'app.mines_rounds', 'layout', $1) as ok",
      [priv]);
    check(rows[0].ok === want,
      `app.mines_rounds.layout ${want ? "is" : "is not"} ${priv}-able by nutriquest_app`);
  }

  // 6. One economy ladder. docs/NET-WORTH.md and CLAUDE.md make
  //    backend/src/game/rarityBands.ts the single source of truth for what a
  //    monster is worth; app.rarity_bands (0014) is a second copy of the same
  //    floors. They agree today. This keeps them
  //    agreeing, because a silent divergence reprices the whole collection.
  {
    const { RARITY_BANDS } = require(join(__dirname, "..", "dist", "game", "rarityBands.js"));
    const canonical = Object.values(RARITY_BANDS);
    const { rows } = await pool.query("select rarity, min_net_worth from app.rarity_bands");
    const live = new Map(rows.map((r) => [r.rarity, Number(r.min_net_worth)]));
    const drift = canonical
      .filter((b) => live.get(b.rarity) !== b.min)
      .map((b) => `${b.rarity}: code=${b.min} db=${live.get(b.rarity) ?? "missing"}`);
    check(canonical.length === live.size && drift.length === 0,
      "app.rarity_bands matches game/rarityBands.ts",
      drift.length ? drift.join("; ") : `${canonical.length} bands in code, ${live.size} in db`);
  }

  // 6b. The other ladder. game/rankTiers.ts owns points -> tier and 0018 stores
  //     the same floors in app.rank_bands so SQL can derive a badge. Same
  //     reasoning as the rarity bands above: two copies, one truth.
  {
    const { RANK_THRESHOLDS } = require(join(__dirname, "..", "dist", "game", "rankTiers.js"));
    const { rows } = await pool.query("select tier, min_points from app.rank_bands");
    const live = new Map(rows.map((r) => [r.tier, Number(r.min_points)]));
    const codeTiers = Object.keys(RANK_THRESHOLDS);
    const drift = codeTiers
      .filter((t) => live.get(t) !== RANK_THRESHOLDS[t])
      .map((t) => `${t}: code=${RANK_THRESHOLDS[t]} db=${live.get(t) ?? "missing"}`);
    check(codeTiers.length === live.size && drift.length === 0,
      "app.rank_bands matches game/rankTiers.ts",
      drift.length ? drift.join("; ") : `${codeTiers.length} tiers in code, ${live.size} in db`);
  }

  // 5b. Every hypertable has an explicit lifecycle DECISION.
  //
  //     Not "every hypertable has a policy" -- some correctly have none. The
  //     failure this catches is the one that already happened twice: a
  //     migration adds a hypertable, the lifecycle sweep that would have
  //     enrolled it ran three migrations ago, and nobody notices for months.
  //     A new hypertable fails this check until it is listed here with a
  //     stated intent, which forces the decision to be made once, on purpose.
  //
  //     compress:false on a player-owned stream is usually not an oversight:
  //     RLS is unsupported on columnstore chunks, so compressing a table with
  //     a player_isolation policy would silently drop the policy. See 0019.
  const LIFECYCLE = {
    "telemetry.health_samples":       { compress: false, retention: true,  why: "raw 7d; analytics.health_hourly keeps the year" },
    "telemetry.activity_observations":{ compress: false, retention: true,  why: "raw 7d; cumulative rings summarised hourly" },
    "telemetry.nutrition_deltas":     { compress: true,  retention: false, why: "account-lifetime history, compressed for space (no RLS: columnstore)" },
    "telemetry.battle_events":        { compress: true,  retention: false, why: "bulkiest stream; deletion must be a guarded job, not an age policy" },
    "telemetry.battle_metrics":       { compress: true,  retention: true,  why: "365d, compressed after 7 (no RLS: columnstore)" },
    "telemetry.gameplay_events":      { compress: false, retention: true,  why: "30d raw; gameplay_hourly keeps the trend" },
    "telemetry.body_metrics":         { compress: false, retention: false, why: "weigh-in history IS the feature; tiny, and RLS beats compression" },
    "telemetry.gamble_events":        { compress: false, retention: true,  why: "90d for wager disputes; RLS beats compression" },
    "telemetry.streak_events":        { compress: false, retention: false, why: "one row per player per day; a streak history with holes is useless" },
    "telemetry.acquisition_events":   { compress: false, retention: true,  why: "365d raw; acquisition_hourly keeps the rarity mix" },
    "telemetry.dungeon_progress":     { compress: false, retention: true,  why: "90d raw; dungeon_daily keeps the depth curve" },
  };

  const { rows: lifecycleRows } = await pool.query(`
    select h.hypertable_schema || '.' || h.hypertable_name as tbl,
           h.compression_enabled as compress,
           exists (
             select 1 from timescaledb_information.jobs j
              where j.proc_name = 'policy_retention'
                and j.hypertable_schema = h.hypertable_schema
                and j.hypertable_name   = h.hypertable_name
           ) as retention
      from timescaledb_information.hypertables h
     order by 1`);

  const undeclared = lifecycleRows.filter((r) => !LIFECYCLE[r.tbl]).map((r) => r.tbl);
  check(undeclared.length === 0,
    "every hypertable has a declared lifecycle intent",
    undeclared.length ? `${undeclared.join(", ")} -- add to LIFECYCLE in this file with a reason` : "");

  const lifecycleDrift = lifecycleRows
    .filter((r) => LIFECYCLE[r.tbl])
    .filter((r) => LIFECYCLE[r.tbl].compress !== r.compress || LIFECYCLE[r.tbl].retention !== r.retention)
    .map((r) => {
      const want = LIFECYCLE[r.tbl];
      return `${r.tbl}: want compress=${want.compress}/retention=${want.retention}, got compress=${r.compress}/retention=${r.retention}`;
    });
  check(lifecycleDrift.length === 0, "hypertable lifecycle matches its declared intent", lifecycleDrift.join("; "));

  // RLS and columnstore are mutually exclusive -- assert we never shipped a
  // table claiming both, which would mean the policy silently stopped applying.
  const { rows: rlsCompressed } = await pool.query(`
    select h.hypertable_schema || '.' || h.hypertable_name as tbl
      from timescaledb_information.hypertables h
      join pg_class c on c.relname = h.hypertable_name
      join pg_namespace n on n.oid = c.relnamespace and n.nspname = h.hypertable_schema
     where h.compression_enabled and c.relrowsecurity
     order by 1`);
  check(rlsCompressed.length === 0,
    "no hypertable has both RLS and columnstore",
    rlsCompressed.map((r) => r.tbl).join(", "));

  // 6. Time-series surface, stated exactly rather than as a floor, so adding a
  //    hypertable without its rollup (or vice versa) is a conversation.
  const { rows: h } = await pool.query(
    "select count(*)::int n from timescaledb_information.hypertables");
  const { rows: c } = await pool.query(
    "select count(*)::int n from timescaledb_information.continuous_aggregates");
  check(h[0].n === 11, "11 hypertables", `found ${h[0].n}`);
  check(c[0].n === 8, "8 continuous aggregates", `found ${c[0].n}`);

  await pool.end();
  if (failures.length) {
    console.error(`\n${failures.length} schema check(s) failed.`);
    process.exit(1);
  }
  console.log("\nall schema checks passed.");
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
