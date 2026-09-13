// Progression mirror -> TigerData (DB finalization pass).
//
// Covers the SQLite tables that had a matching app.* table scaffolded but no
// application-code writer: barcode-mint anti-cheat, granted/opened Cases,
// fainted monsters, parked interactive battle matches, owned-character
// ownership, and friend-squad snapshots. Same shape as gambleRepo.ts /
// healthRepo.ts: withPlayer for RLS, ensurePlayer first, idempotent writes.
import { PoolClient } from "pg";
import { withPlayer } from "../pg";
import { ensurePlayer } from "./players";

// --- Barcode-mint anti-cheat provenance ------------------------------------

export interface ScanMintMirror {
  playerId: string;
  barcode: string;
  dropId: string;
  characterId: string;
  nutrition: unknown;
  source: string;
}

export async function mirrorScanMint(p: ScanMintMirror): Promise<void> {
  await withPlayer(p.playerId, async (client: PoolClient) => {
    await ensurePlayer(client, p.playerId);
    await client.query(
      `insert into app.scan_mints (player_id, barcode, monster_id, character_id, nutrition, source)
       values ($1,$2,$3,$4,$5,$6)
       on conflict (player_id, barcode) do nothing`,
      [p.playerId, p.barcode, p.dropId, p.characterId, JSON.stringify(p.nutrition), p.source]
    );
  });
}

// --- Pending Cases ----------------------------------------------------------

export interface CaseGrantMirror {
  caseId: string;
  playerId: string;
  rarity: string;
  source: string;
  createdAt: string;
}

export async function mirrorCaseGrant(p: CaseGrantMirror): Promise<void> {
  await withPlayer(p.playerId, async (client: PoolClient) => {
    await ensurePlayer(client, p.playerId);
    await client.query(
      `insert into app.pending_cases (case_id, player_id, rarity, source, created_at)
       values ($1,$2,$3,$4,$5)
       on conflict (case_id) do nothing`,
      [p.caseId, p.playerId, p.rarity, p.source, p.createdAt]
    );
  });
}

export interface CaseOpenMirror {
  caseId: string;
  playerId: string;
}

export async function mirrorCaseOpen(p: CaseOpenMirror): Promise<void> {
  await withPlayer(p.playerId, async (client: PoolClient) => {
    await ensurePlayer(client, p.playerId);
    await client.query(`delete from app.pending_cases where case_id = $1 and player_id = $2`, [p.caseId, p.playerId]);
  });
}

// --- Fainted monsters --------------------------------------------------------

export interface FaintedMonsterMirror {
  playerId: string;
  action: "faint" | "revive";
  charIds: string[];
  /** 'YYYY-MM-DD' day key. Required for 'faint'; irrelevant for 'revive'. */
  day?: string;
}

export async function mirrorFaintedMonster(p: FaintedMonsterMirror): Promise<void> {
  await withPlayer(p.playerId, async (client: PoolClient) => {
    await ensurePlayer(client, p.playerId);
    for (const charId of p.charIds) {
      if (p.action === "faint") {
        await client.query(
          `insert into app.fainted_monsters (player_id, char_id, day) values ($1,$2,$3)
           on conflict (player_id, char_id) do nothing`,
          [p.playerId, charId, p.day]
        );
      } else {
        await client.query(`delete from app.fainted_monsters where player_id = $1 and char_id = $2`, [p.playerId, charId]);
      }
    }
  });
}

// --- Interactive battle match (begin) ---------------------------------------

export interface BattleMatchBeginMirror {
  matchId: string;
  playerId: string;
  mode: "ranked" | "friendly";
  ownSquad: unknown;
  oppSquad: unknown;
  opponentId: string | null;
  isBot: boolean;
  meta: unknown | null;
  seed: string;
  expiresAt: string;
}

export async function mirrorBattleMatchBegin(p: BattleMatchBeginMirror): Promise<void> {
  await withPlayer(p.playerId, async (client: PoolClient) => {
    await ensurePlayer(client, p.playerId);
    await client.query(
      `insert into app.battle_matches
         (id, player_id, mode, own_squad, opp_squad, opponent_id, is_bot, meta, seed, expires_at)
       values ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10)
       on conflict (id, player_id) do nothing`,
      [
        p.matchId, p.playerId, p.mode, JSON.stringify(p.ownSquad), JSON.stringify(p.oppSquad),
        p.opponentId, p.isBot, p.meta ? JSON.stringify(p.meta) : null, p.seed, p.expiresAt
      ]
    );
  });
}

// --- Owned characters (relational ownership) --------------------------------
//
// app.owned_characters has a live rarity-derivation trigger but, before this
// pass, no application-code writer. definition_id is the catalog slug
// (character.id in app code); definition_version is looked up rather than
// hardcoded, since app.character_definitions is versioned even though only
// version 1 exists for every character today.

export interface OwnedCharacterMirror {
  action: "grant" | "remove" | "lock" | "unlock";
  playerId: string;
  /** The dropId — StoredDrop.id / SQLite lootbox_drop.drop_id, always a UUID. */
  id: string;
  definitionId?: string;
  starLevel?: number;
  netWorth?: number;
  rarity?: string;
  imageKey?: string | null;
  lockedBy?: string | null;
}

export async function mirrorOwnedCharacter(p: OwnedCharacterMirror): Promise<void> {
  await withPlayer(p.playerId, async (client: PoolClient) => {
    await ensurePlayer(client, p.playerId);
    if (p.action === "grant") {
      const def = await client.query(
        `select max(version) as v from app.character_definitions where definition_id = $1`,
        [p.definitionId]
      );
      const version = (def.rows[0]?.v as number | null) ?? 1;
      await client.query(
        `insert into app.owned_characters
           (id, player_id, definition_id, definition_version, star_level, net_worth, rarity, image_key, status)
         values ($1,$2,$3,$4,$5,$6,$7,$8,'available')
         on conflict (id) do update set
           star_level = excluded.star_level, net_worth = excluded.net_worth,
           rarity = excluded.rarity, image_key = excluded.image_key`,
        [p.id, p.playerId, p.definitionId, version, p.starLevel, p.netWorth, p.rarity, p.imageKey ?? null]
      );
    } else if (p.action === "remove") {
      await client.query(`delete from app.owned_characters where id = $1 and player_id = $2`, [p.id, p.playerId]);
    } else if (p.action === "lock") {
      await client.query(
        `update app.owned_characters set locked_by = $1 where id = $2 and player_id = $3`,
        [p.lockedBy, p.id, p.playerId]
      );
    } else {
      await client.query(
        `update app.owned_characters set locked_by = null where id = $1 and player_id = $2`,
        [p.id, p.playerId]
      );
    }
  });
}

// --- Friend squad snapshot ----------------------------------------------------
//
// app.squads has no unique constraint on player_id (the schema allows several
// squads per player by name/mode), but SQLite's friend_squad is genuinely one
// row per player — so this looks up the player's 'default' squad rather than
// relying on ON CONFLICT. Members referencing a character not yet mirrored
// into app.owned_characters are dropped rather than failing the whole
// snapshot (the FK would otherwise dead-letter the entire mirror over one
// stale slot).

export interface SquadSnapshotMirror {
  playerId: string;
  /** Catalog character ids (battle.ts's TrustedUnit.id via resolveOwnUnit) --
   *  never an owned-character instance id. The app has no notion of "which
   *  specific copy is in the squad"; it re-derives stats live from whatever
   *  the player currently owns of that character type (see battle.ts's
   *  refreshStar/ownedStarLevel). */
  units: { id: string }[];
}

export async function mirrorSquadSnapshot(p: SquadSnapshotMirror): Promise<void> {
  await withPlayer(p.playerId, async (client: PoolClient) => {
    await ensurePlayer(client, p.playerId);
    const existing = await client.query(
      `select id from app.squads where player_id = $1 and mode = 'default' limit 1`,
      [p.playerId]
    );
    let squadId: string;
    if (existing.rowCount) {
      squadId = existing.rows[0].id as string;
      await client.query(`update app.squads set version = version + 1 where id = $1`, [squadId]);
    } else {
      const inserted = await client.query(
        `insert into app.squads (player_id, mode) values ($1, 'default') returning id`,
        [p.playerId]
      );
      squadId = inserted.rows[0].id as string;
    }
    await client.query(`delete from app.squad_members where squad_id = $1`, [squadId]);
    let slot = 0;
    for (const u of p.units) {
      // squad_members.character_id references one specific owned_characters
      // row, so a representative instance has to be picked for this
      // character type -- the same one the app itself would treat as "the"
      // copy: highest star, then highest net worth.
      const owned = await client.query(
        `select id from app.owned_characters
          where player_id = $1 and definition_id = $2
          order by star_level desc, net_worth desc
          limit 1`,
        [p.playerId, u.id]
      );
      if (owned.rowCount === 0) continue;
      await client.query(
        `insert into app.squad_members (squad_id, slot, character_id) values ($1,$2,$3)
         on conflict (squad_id, slot) do nothing`,
        [squadId, slot, owned.rows[0].id]
      );
      slot += 1;
    }
  });
}
