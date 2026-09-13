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

// --- Player settings ---------------------------------------------------------
//
// The other half of the user_profile -> TigerData mapping documented in
// db-documentation/10-schema-parity-audit.md (`user_profile` ->
// `app.profile_versions` + `app.player_settings`). profile_versions holds the
// append-only measurement/goal history; this holds the single mutable
// preferences row. Only the two fields the app actually has (colorMode as
// theme, activeCharacterId) are set -- preferred_squad_id/game_timezone/
// notification_prefs have no source in user_profile today, so they are left
// alone rather than overwritten with defaults on every update.

export interface PlayerSettingsMirror {
  playerId: string;
  theme: string | null;
  activeCharacterId: string | null;
}

export async function mirrorPlayerSettings(p: PlayerSettingsMirror): Promise<void> {
  await withPlayer(p.playerId, async (client: PoolClient) => {
    await ensurePlayer(client, p.playerId);
    // active_character_id is a strict FK to app.owned_characters(id); the
    // referenced drop may not have been mirrored yet (or may belong to
    // another player if the id is stale), so resolve it defensively rather
    // than let one bad reference fail the whole settings upsert.
    let activeCharacterId: string | null = null;
    if (p.activeCharacterId) {
      const owned = await client.query(
        `select 1 from app.owned_characters where id = $1 and player_id = $2`,
        [p.activeCharacterId, p.playerId]
      );
      if ((owned.rowCount ?? 0) > 0) activeCharacterId = p.activeCharacterId;
    }
    await client.query(
      `insert into app.player_settings (player_id, theme, active_character_id)
       values ($1, coalesce($2, 'system'), $3)
       on conflict (player_id) do update set
         theme = coalesce($2, app.player_settings.theme),
         active_character_id = $3,
         version = app.player_settings.version + 1,
         updated_at = now()`,
      [p.playerId, p.theme, activeCharacterId]
    );
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
