// Tiger Cloud / PostgreSQL access layer (the target runtime store).
//
// Additive on purpose: this lives alongside the existing node:sqlite layer so
// the app keeps building and running on SQLite while routes are ported one at
// a time. Nothing here executes until DATABASE_URL is set and a caller uses it.
import { Pool, PoolClient, QueryResult, QueryResultRow } from "pg";

// Three roles, three pools. They are separate because they have different
// rights, and collapsing them is how RLS ends up enforced against nobody:
//
//   app      DATABASE_URL          nutriquest_app -- a non-owner, so every
//                                  player_isolation policy actually binds.
//                                  This is the one the request path uses.
//   admin    DATABASE_URL_ADMIN    the table owner. DDL only: migrations, the
//                                  CI schema checks, the invariants suite.
//                                  Bypasses RLS, which is why no route may
//                                  touch it.
//   replica  DATABASE_URL_REPLICA  a Tiger Cloud read replica, when one is
//                                  provisioned. Analytics reads go here so a
//                                  dashboard query never competes with the
//                                  write path for the primary's CPU.
//
// Every one of them falls back to DATABASE_URL, so a single-URL setup (local
// dev, CI, today's deployment) keeps working with no configuration at all.
let appPool: Pool | null = null;
let adminPool: Pool | null = null;
let replicaPool: Pool | null = null;

/** True when a Tiger Cloud connection string is configured. */
export function hasDatabaseUrl(): boolean {
  return Boolean(process.env.DATABASE_URL || process.env.DATABASE_URL_ADMIN);
}

function build(connectionString: string, max: number): Pool {
  return new Pool({
    connectionString,
    max,
    idleTimeoutMillis: 30_000,
    connectionTimeoutMillis: 10_000,
    // Tiger Cloud requires TLS. TODO(prod): pin the Tiger Cloud CA instead of
    // disabling verification; kept lenient here so dev/staging connect easily.
    ssl: /sslmode=require|ssl=true/.test(connectionString)
      ? { rejectUnauthorized: false }
      : undefined,
  });
}

/** The request path's pool: connects as the restricted role, so RLS applies.
 *  Throws if no URL is configured so callers (and the readiness probe) fail
 *  loudly rather than silently mis-connecting. */
export function getPool(): Pool {
  if (!appPool) {
    const connectionString = process.env.DATABASE_URL || process.env.DATABASE_URL_ADMIN;
    if (!connectionString) throw new Error("DATABASE_URL_NOT_SET");
    appPool = build(connectionString, Number(process.env.PG_POOL_MAX ?? 10));
  }
  return appPool;
}

/** The owner pool. Migrations and schema checks only -- it bypasses RLS. */
export function getAdminPool(): Pool {
  if (!adminPool) {
    const connectionString = process.env.DATABASE_URL_ADMIN || process.env.DATABASE_URL;
    if (!connectionString) throw new Error("DATABASE_URL_NOT_SET");
    adminPool = build(connectionString, Number(process.env.PG_ADMIN_POOL_MAX ?? 4));
  }
  return adminPool;
}

/** Read-only analytics pool. Falls back to the app pool when no replica is
 *  provisioned, so trend routes work identically either way. */
export function getReplicaPool(): Pool {
  const replicaUrl = process.env.DATABASE_URL_REPLICA;
  if (!replicaUrl) return getPool();
  if (!replicaPool) {
    replicaPool = build(replicaUrl, Number(process.env.PG_REPLICA_POOL_MAX ?? 5));
  }
  return replicaPool;
}

/** True when analytics reads are going somewhere other than the primary. */
export function hasReadReplica(): boolean {
  return Boolean(process.env.DATABASE_URL_REPLICA);
}

/** One-shot query on a pooled connection (no per-request player context). */
export function query<T extends QueryResultRow = QueryResultRow>(
  text: string,
  params?: unknown[]
): Promise<QueryResult<T>> {
  return getPool().query<T>(text, params as never);
}

/** Run `fn` inside a transaction with the RLS player context set for the whole
 *  transaction (SET LOCAL app.current_player). This is how row-level security
 *  (migration 0011) becomes real defense-in-depth: every player-scoped table is
 *  automatically confined to `playerId`. Use for all player-authenticated work. */
export async function withPlayer<T>(
  playerId: string,
  fn: (client: PoolClient) => Promise<T>
): Promise<T> {
  const client = await getPool().connect();
  try {
    await client.query("begin");
    await client.query("select set_config('app.current_player', $1, true)", [playerId]);
    const result = await fn(client);
    await client.query("commit");
    return result;
  } catch (err) {
    await client.query("rollback");
    throw err;
  } finally {
    client.release();
  }
}

/** Plain transaction helper (no player context) for system/admin work. */
export async function withTransaction<T>(fn: (client: PoolClient) => Promise<T>): Promise<T> {
  const client = await getPool().connect();
  try {
    await client.query("begin");
    const result = await fn(client);
    await client.query("commit");
    return result;
  } catch (err) {
    await client.query("rollback");
    throw err;
  } finally {
    client.release();
  }
}

export async function closePool(): Promise<void> {
  const pools = [appPool, adminPool, replicaPool];
  appPool = adminPool = replicaPool = null;
  for (const p of pools) {
    if (p) await p.end();
  }
}
