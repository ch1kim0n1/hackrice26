// Identity mirror -> TigerData (DB finalization pass).
//
// auth/store.ts and the profile-save path had no Postgres awareness at all
// before this: app.players only ever got bare guest stubs via ensurePlayer,
// and app.credentials/app.sessions/app.profile_versions were never written.
// Passwords are never handled here in plaintext — only the hash the app
// already computed (scrypt, auth/store.ts) crosses to Postgres, the same as
// it already crosses into SQLite's own `account` table.
import { PoolClient } from "pg";
import { withPlayer } from "../pg";
import { ensurePlayer } from "./players";

const BODY_TYPES = new Set(["ectomorph", "mesomorph", "endomorph"]);

// --- Account creation ---------------------------------------------------------

export interface AccountCreatedMirror {
  playerId: string;
  username: string;
  displayName: string;
  passwordHash: string;
}

export async function mirrorAccountCreated(p: AccountCreatedMirror): Promise<void> {
  await withPlayer(p.playerId, async (client: PoolClient) => {
    // ensurePlayer's own on-conflict-do-nothing would leave a pre-existing
    // guest stub's name/kind untouched, so a real account is applied
    // explicitly right after.
    await ensurePlayer(client, p.playerId, p.displayName);
    await client.query(
      `update app.players set display_name = $2, kind = 'registered' where id = $1`,
      [p.playerId, p.displayName]
    );
    await client.query(
      `insert into app.credentials (player_id, username_norm, username_display, password_hash)
       values ($1,$2,$3,$4)
       on conflict (player_id) do update set
         username_norm = excluded.username_norm,
         username_display = excluded.username_display,
         password_hash = excluded.password_hash,
         updated_at = now()`,
      [p.playerId, p.username.toLowerCase(), p.username, p.passwordHash]
    );
  });
}

// --- Sessions ------------------------------------------------------------------

export interface SessionEventMirror {
  action: "create" | "revoke" | "revoke_all";
  playerId: string;
  /** sha256 hex digest — same hash auth/store.ts already computes for SQLite. */
  tokenHashHex?: string;
  expiresAt?: string;
}

export async function mirrorSessionEvent(p: SessionEventMirror): Promise<void> {
  await withPlayer(p.playerId, async (client: PoolClient) => {
    await ensurePlayer(client, p.playerId);
    if (p.action === "create") {
      await client.query(
        `insert into app.sessions (token_hash, player_id, expires_at) values ($1,$2,$3)
         on conflict (token_hash) do nothing`,
        [Buffer.from(p.tokenHashHex!, "hex"), p.playerId, p.expiresAt]
      );
    } else if (p.action === "revoke") {
      await client.query(`update app.sessions set revoked_at = now() where token_hash = $1`, [
        Buffer.from(p.tokenHashHex!, "hex")
      ]);
    } else {
      await client.query(
        `update app.sessions set revoked_at = now() where player_id = $1 and revoked_at is null`,
        [p.playerId]
      );
    }
  });
}

// --- Profile snapshot ------------------------------------------------------

export interface ProfileUpdateMirror {
  playerId: string;
  updatedAt: string;
  measurements: unknown;
  activityGoal: unknown;
  calculatedTargets: unknown;
  bodyType: string | null;
}

/** Appends one app.profile_versions revision. Idempotent on `updatedAt`,
 *  stamped into the measurements blob as `_syncedAt` — a redelivery of the
 *  same profile snapshot must not create a second revision. */
export async function mirrorProfileUpdate(p: ProfileUpdateMirror): Promise<void> {
  await withPlayer(p.playerId, async (client: PoolClient) => {
    await ensurePlayer(client, p.playerId);
    const seen = await client.query(
      `select 1 from app.profile_versions where player_id = $1 and (measurements->>'_syncedAt') = $2 limit 1`,
      [p.playerId, p.updatedAt]
    );
    if ((seen.rowCount ?? 0) > 0) return;

    const measurements = { ...((p.measurements as object) ?? {}), _syncedAt: p.updatedAt };
    const bodyType = p.bodyType && BODY_TYPES.has(p.bodyType) ? p.bodyType : null;
    await client.query(
      `insert into app.profile_versions
         (player_id, revision, measurements, activity_goal, calculated_targets, formula_version, body_type)
       select $1, coalesce(max(revision),0)+1, $2, $3, $4, $5, $6
       from app.profile_versions where player_id = $1`,
      [
        p.playerId,
        JSON.stringify(measurements),
        JSON.stringify(p.activityGoal ?? {}),
        JSON.stringify(p.calculatedTargets ?? {}),
        "app_profile_v1",
        bodyType
      ]
    );
  });
}
