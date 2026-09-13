// Per-player lootbox state: fairness seeds, inventory, mailbox, granted cases.
//
// State is kept in memory for cheap synchronous access and written through
// to SQLite (see db.ts) on every mutation, so a restart or redeploy keeps
// every player's seeds, monsters, and mailbox (issue #23). The in-memory copy
// is a cache; the database is the source of truth.
//
// The spec removed keys and pity — a session is now just a seed pair plus an
// inventory. When the 200-slot inventory is full, mints route to the mailbox
// instead of evicting anything: no reward is ever silently discarded.

import { randomBytes, randomUUID } from "crypto";
import { Character, Fairness, LootDrop, Rarity } from "../types";
import { hashSeed, newServerSeed } from "./lootboxEngine";
import { db } from "../db";
import { sampleCharacters } from "../data/sampleCharacters";
import { mintValue } from "../game/rarityBands";
import { baseValueOf } from "../game/revaluation";
import { INVENTORY_CAP } from "../game/spec";

const MAX_MAILBOX = 500;

/** Where a starter/scan mint sits inside its band — deterministic, mid-segment. */
const STARTER_SEGMENT_UNIT = 0.5;
const STARTER_POSITION_UNIT = 0.55;

/**
 * One commit-reveal round.
 *
 * The server publishes `serverSeedHash` up front and discloses `serverSeed` only
 * when the pair is retired. Until then it cannot change the seed without
 * breaking the hash it already published, which is the entire point.
 */
export interface SeedPair {
  serverSeed: string;
  serverSeedHash: string;
  clientSeed: string;
  nonce: number;
  createdAt: string;
  retiredAt: string | null;
}

export function createSeedPair(clientSeed?: string): SeedPair {
  const serverSeed = newServerSeed();
  return {
    serverSeed,
    serverSeedHash: hashSeed(serverSeed),
    clientSeed: clientSeed ?? randomBytes(8).toString("hex"),
    nonce: 0,
    createdAt: new Date().toISOString(),
    retiredAt: null
  };
}

/** Seed pair with the server seed withheld unless explicitly revealed. */
export function publicSeedPair(pair: SeedPair, reveal = false) {
  const base = {
    serverSeedHash: pair.serverSeedHash,
    clientSeed: pair.clientSeed,
    nonce: pair.nonce,
    createdAt: pair.createdAt,
    retiredAt: pair.retiredAt
  };
  return reveal ? { ...base, serverSeed: pair.serverSeed } : base;
}

export interface StoredDrop extends Omit<LootDrop, "rolls"> {
  rolls: LootDrop["rolls"];
  /**
   * Stable per-instance id.
   *
   * Two pulls of the same character are two different monsters, and Cauldron
   * Crash destroys one specific monster — so the inventory needs an identity
   * finer than the character id it used to be addressed by.
   */
  id: string;
  /**
   * What currently holds this monster, if anything — an arena stake, an
   * escrow. A locked monster cannot be sold, gambled or fused. null is free.
   */
  lockedBy?: string | null;
  /** The open consumed a Cookbook Boost — the rarity was rolled on the ×1.15
   *  Rare+ table, not the book's published odds. Verification needs this. */
  boosted?: boolean;
}

/** What record() hands back: the stored drop plus whether it bypassed a full
 *  inventory into the mailbox (spec checklist: overflow, never evict). */
export interface RecordResult {
  drop: StoredDrop;
  overflowed: boolean;
}

class GameState {
  current: SeedPair = createSeedPair();
  retired: SeedPair[] = [];
  inventory: StoredDrop[] = [];
  /** Rewards that arrived while the inventory was full. Claimable on demand. */
  mailbox: StoredDrop[] = [];

  /** Set once by attach(); identifies the rows this session owns. */
  private playerId = "legacy";

  /** Hydrates this session from the database (no-op for a brand-new player). */
  attach(id: string): void {
    this.playerId = id;
    const row = db
      .prepare(
        `SELECT server_seed, server_seed_hash, client_seed, nonce, created_at, collection_seeded
         FROM lootbox_session WHERE player_id = ?`
      )
      .get(id) as
      | { server_seed: string; server_seed_hash: string; client_seed: string; nonce: number; created_at: string; collection_seeded: number }
      | undefined;

    if (row) {
      this.current = {
        serverSeed: row.server_seed,
        serverSeedHash: row.server_seed_hash,
        clientSeed: row.client_seed,
        nonce: row.nonce,
        createdAt: row.created_at,
        retiredAt: null
      };
      this.retired = (db
        .prepare(
          `SELECT server_seed, server_seed_hash, client_seed, nonce, created_at, retired_at
           FROM lootbox_retired WHERE player_id = ? ORDER BY rowid`
        )
        .all(id) as any[])
        .map((r) => ({
          serverSeed: r.server_seed,
          serverSeedHash: r.server_seed_hash,
          clientSeed: r.client_seed,
          nonce: r.nonce,
          createdAt: r.created_at,
          retiredAt: r.retired_at
        }));

      const loadDrops = (overflow: number) =>
        (db
          .prepare(
            `SELECT drop_id, payload, locked_by FROM lootbox_drop
             WHERE player_id = ? AND overflow = ? ORDER BY seq DESC LIMIT ?`
          )
          .all(id, overflow, overflow ? MAX_MAILBOX : INVENTORY_CAP * 2) as any[])
          // The columns, not the payload, are the authority on a drop's id and
          // lock state: rows written before ids existed were backfilled there.
          // Rows written before baseMintValue existed get it recovered from
          // their total minus the star bonus they already carry.
          .map((r) => {
            const stored = {
              ...(JSON.parse(r.payload) as StoredDrop),
              id: r.drop_id as string,
              lockedBy: (r.locked_by as string | null) ?? null
            };
            if (stored.baseMintValue === undefined) {
              stored.baseMintValue = baseValueOf(stored.value, stored.character.rarity, stored.stars);
            }
            return stored;
          })
          .reverse();
      this.inventory = loadDrops(0);
      this.mailbox = loadDrops(1);
      // Players whose session predates real starter drops (or who scanned
      // before scans minted drops) get their collection backfilled exactly
      // once — the flag is what stops a sold monster being re-minted for
      // free on every subsequent attach.
      if (!row.collection_seeded) {
        this.backfillCollectionDrops();
        db.prepare(`UPDATE lootbox_session SET collection_seeded = 1 WHERE player_id = ?`).run(id);
      }
    } else {
      this.persistSession();
      this.seedStarterRoster();
      db.prepare(`UPDATE lootbox_session SET collection_seeded = 1 WHERE player_id = ?`).run(id);
    }
  }

  /**
   * A brand-new player's starting six are real owned monsters, not display
   * filler — every one of them gets its own dropId and a net worth off the
   * same rarityBands ladder every other monster uses, the instant the
   * session is created. Sell, Cauldron Crash, Mines, Plinko and the Wheel
   * all key off `dropId` alone, so this is what actually makes "sell or
   * gamble any character, not just ones from a case" true, instead of the
   * starter roster being cosmetic-only forever.
   *
   * Runs exactly once — only from the brand-new-session branch of attach(),
   * never on an existing player's every reconnect.
   */
  private seedStarterRoster(): void {
    for (const character of sampleCharacters) {
      this.mintOwnedDrop(character, "starter-roster");
    }
  }

  /**
   * Mint one owned, sellable drop for a character that never came out of a
   * cookbook — the starter six, a barcode scan. Same band ladder as cookbook
   * drops, deterministic mid-band placement since nothing was gambled on the
   * outcome.
   */
  mintOwnedDrop(
    character: Character,
    crateId: string,
    mint?: { value: number; rolls: LootDrop["rolls"] }
  ): StoredDrop {
    // Callers that rolled their own mint (barcode scans roll segment+position
    // off the NutritionScore path) pass it through; the default is the
    // deterministic mid-band placement used for grants nobody gambled on.
    const baseMintValue =
      mint?.value ?? mintValue(character.rarity, STARTER_SEGMENT_UNIT, STARTER_POSITION_UNIT);
    return this.record({
      crateId,
      character,
      stars: 1,
      baseMintValue,
      value: baseMintValue,
      rolls: mint?.rolls ?? {
        rarity: 0,
        character: 0,
        mintSegment: STARTER_SEGMENT_UNIT,
        mintPosition: STARTER_POSITION_UNIT
      },
      fairness: { serverSeedHash: this.current.serverSeedHash, clientSeed: this.current.clientSeed, nonce: -1 },
      openedAt: new Date().toISOString()
    }).drop;
  }

  /**
   * One-shot backfill for sessions created before starter monsters and
   * scanned characters were real drops: mint whatever the collection says
   * the player owns but the inventory does not. Runs under the
   * `collection_seeded` flag, so it can never resurrect a sold monster.
   */
  private backfillCollectionDrops(): void {
    const ownedIds = new Set(
      [...this.inventory, ...this.mailbox].map((d) => d.character.id)
    );
    for (const character of sampleCharacters) {
      if (!ownedIds.has(character.id)) this.mintOwnedDrop(character, "starter-roster");
    }
    const scanned = db
      .prepare(`SELECT payload FROM scan_character WHERE player_id = ?`)
      .all(this.playerId) as { payload: string }[];
    for (const row of scanned) {
      const character = JSON.parse(row.payload) as Character;
      if (!ownedIds.has(character.id)) this.mintOwnedDrop(character, "scan");
    }
  }

  // -- persistence ----------------------------------------------------------

  private persistSession(): void {
    db.prepare(
      `INSERT INTO lootbox_session (player_id, server_seed, server_seed_hash, client_seed, nonce, created_at)
       VALUES (?, ?, ?, ?, ?, ?)
       ON CONFLICT(player_id) DO UPDATE SET
         server_seed = excluded.server_seed,
         server_seed_hash = excluded.server_seed_hash,
         client_seed = excluded.client_seed,
         nonce = excluded.nonce`
    ).run(
      this.playerId,
      this.current.serverSeed,
      this.current.serverSeedHash,
      this.current.clientSeed,
      this.current.nonce,
      this.current.createdAt
    );
  }

  // -- seeds ----------------------------------------------------------------

  /** Players pick their own client seed so the server alone cannot determine an
   *  outcome. Changing it restarts the nonce, purely for legibility. */
  setClientSeed(clientSeed: string): void {
    this.current.clientSeed = clientSeed;
    this.current.nonce = 0;
    this.persistSession();
  }

  /** Retire the active pair, revealing its seed, and commit to a fresh one.
   *  Every open made under the old seed becomes independently checkable. */
  rotateSeed(): SeedPair {
    const retired = this.current;
    retired.retiredAt = new Date().toISOString();
    this.retired.push(retired);
    this.current = createSeedPair(retired.clientSeed);

    db.prepare(
      `INSERT INTO lootbox_retired (player_id, server_seed, server_seed_hash, client_seed, nonce, created_at, retired_at)
       VALUES (?, ?, ?, ?, ?, ?, ?)`
    ).run(
      this.playerId,
      retired.serverSeed,
      retired.serverSeedHash,
      retired.clientSeed,
      retired.nonce,
      retired.createdAt,
      retired.retiredAt!
    );
    this.persistSession();
    return retired;
  }

  /**
   * Claim the next nonce for an outcome, and write it through.
   *
   * Returns the nonce the caller should roll with, having already advanced the
   * counter — two rounds can never share a digest, and a restart cannot rewind
   * into nonces that have already been used.
   */
  consumeNonce(): number {
    const nonce = this.current.nonce;
    this.current.nonce = nonce + 1;
    this.persistSession();
    return nonce;
  }

  /**
   * The seed pair a round committed to, looked up by the hash it disclosed.
   * A round can outlive a rotation — cash-out rewards must roll under the
   * seed pair the round started with, not whatever pair is current now, or
   * the disclosed fairness values stop matching the roll.
   */
  pairForHash(serverSeedHash: string): SeedPair {
    if (this.current.serverSeedHash === serverSeedHash) return this.current;
    return this.retired.find((p) => p.serverSeedHash === serverSeedHash) ?? this.current;
  }

  fairnessFor(pair: SeedPair, nonce: number): Fairness {
    return {
      serverSeedHash: pair.serverSeedHash,
      clientSeed: pair.clientSeed,
      nonce
    };
  }

  // -- inventory ------------------------------------------------------------

  /**
   * Store a minted drop. If the player's unlocked inventory is already at the
   * 200-monster cap, the drop goes to the mailbox instead — the spec's
   * checklist forbids silently discarding a reward, and the old "delete the
   * oldest unlocked row" behaviour did exactly that.
   */
  record(drop: StoredDrop | Omit<StoredDrop, "id">): RecordResult {
    const stored: StoredDrop = "id" in drop && drop.id ? drop : { ...drop, id: randomUUID() };
    const overflowed = this.availableDrops().length >= INVENTORY_CAP;
    if (overflowed) {
      this.mailbox.push(stored);
    } else {
      this.inventory.push(stored);
    }
    db.prepare(`INSERT INTO lootbox_drop (player_id, drop_id, payload, overflow) VALUES (?, ?, ?, ?)`).run(
      this.playerId,
      stored.id,
      JSON.stringify(stored),
      overflowed ? 1 : 0
    );
    // The session row stays in step with every inventory write: the nonce the
    // caller consumed is durable by the time the drop exists, so a restart
    // cannot rewind into a used nonce.
    this.persistSession();
    return { drop: stored, overflowed };
  }

  /**
   * Move mailbox monsters into the inventory, up to the free space. Returns
   * the ids that actually moved — the caller answers with those, not with a
   * promise.
   */
  claimMailbox(ids: string[]): { claimed: string[]; remaining: number } {
    const free = INVENTORY_CAP - this.availableDrops().length;
    const claimable = ids.filter((id) => this.mailbox.some((d) => d.id === id)).slice(0, Math.max(0, free));
    const statement = db.prepare(
      `UPDATE lootbox_drop SET overflow = 0 WHERE player_id = ? AND drop_id = ? AND overflow = 1`
    );
    for (const id of claimable) {
      const index = this.mailbox.findIndex((d) => d.id === id);
      statement.run(this.playerId, id);
      this.inventory.push(this.mailbox[index]);
      this.mailbox.splice(index, 1);
    }
    return { claimed: claimable, remaining: this.mailbox.length };
  }

  /** One owned monster by its instance id — inventory only, not the mailbox. */
  dropById(id: string): StoredDrop | undefined {
    return this.inventory.find((drop) => drop.id === id);
  }

  /**
   * Destroy monsters permanently — the Cauldron Crash wager.
   *
   * All-or-nothing: if any id is unknown (already wagered, already destroyed,
   * or never owned) nothing is removed and the caller gets `null`, so a
   * half-applied wager cannot exist. Duplicate ids in one call are rejected
   * for the same reason — the same monster must not be able to fill two slots.
   */
  consumeDrops(ids: string[]): StoredDrop[] | null {
    if (new Set(ids).size !== ids.length) return null;
    const found = ids.map((id) => this.dropById(id));
    if (found.some((drop) => drop === undefined)) return null;
    // A monster committed elsewhere -- staked on a battle, held in escrow --
    // is not available to spend. Checked here rather than in each game, so a
    // new mode cannot forget to ask.
    if (found.some((drop) => drop?.lockedBy)) return null;
    const removed = found as StoredDrop[];
    this.removeDrops(removed.map((d) => d.id));
    return removed;
  }

  /**
   * Bulk escrow lock (issue #116): flag monsters as held by `heldBy`. They
   * remain in the inventory — visible, still owned — but `consumeDrops`
   * refuses them until `unlockDrops` or `removeDrops` runs at settlement.
   *
   * All-or-nothing like consumeDrops: if any id is missing or already held,
   * nothing changes.
   */
  lockDrops(ids: string[], heldBy: string): StoredDrop[] | null {
    if (new Set(ids).size !== ids.length) return null;
    const found = ids.map((id) => this.dropById(id));
    if (found.some((drop) => drop === undefined || drop.lockedBy)) return null;
    const drops = found as StoredDrop[];
    for (const drop of drops) this.lockDrop(drop.id, heldBy);
    return drops;
  }

  /** Release escrow without consuming: the monsters are spendable again. */
  unlockDrops(ids: string[]): StoredDrop[] {
    const released: StoredDrop[] = [];
    for (const id of ids) {
      const drop = this.dropById(id);
      if (!drop) continue;
      this.unlockDrop(id);
      released.push(drop);
    }
    return released;
  }

  /**
   * Remove drops unconditionally — settlement internals only. Unlike
   * consumeDrops this WILL take a locked row, because releasing escrow and
   * removing the monster is exactly what a lost stake is.
   */
  removeDrops(ids: string[]): StoredDrop[] {
    const statement = db.prepare(`DELETE FROM lootbox_drop WHERE player_id = ? AND drop_id = ?`);
    const removed: StoredDrop[] = [];
    for (const id of ids) {
      const drop = this.dropById(id);
      if (!drop) continue;
      statement.run(this.playerId, id);
      const index = this.inventory.findIndex((candidate) => candidate.id === id);
      if (index >= 0) this.inventory.splice(index, 1);
      removed.push({ ...drop, lockedBy: null });
    }
    return removed;
  }

  /**
   * Commit a monster to something outside the inventory.
   *
   * Returns false if it does not exist or is already held, so a caller can
   * never end up believing it locked something it did not.
   */
  lockDrop(id: string, heldBy: string): boolean {
    const drop = this.dropById(id);
    if (!drop || drop.lockedBy) return false;
    drop.lockedBy = heldBy;
    // `locked` is 004's boolean, kept in step so the two never disagree.
    db.prepare(`UPDATE lootbox_drop SET locked_by = ?, locked = 1 WHERE player_id = ? AND drop_id = ?`)
      .run(heldBy, this.playerId, id);
    return true;
  }

  /** Release a lock. Safe to call on an already-free monster. */
  unlockDrop(id: string): void {
    const drop = this.dropById(id);
    if (drop) drop.lockedBy = null;
    db.prepare(`UPDATE lootbox_drop SET locked_by = NULL, locked = 0 WHERE player_id = ? AND drop_id = ?`)
      .run(this.playerId, id);
  }

  /** Monsters free to sell, gamble or fuse. */
  availableDrops(): StoredDrop[] {
    return this.inventory.filter((drop) => !drop.lockedBy);
  }

  /**
   * Clear the session in place.
   *
   * Mutates rather than replacing the instance: callers import `state` directly,
   * which binds the reference once. Reassigning would leave every one of them
   * holding the old object, so a reset would appear to succeed while changing
   * nothing at all.
   */
  reset(): void {
    this.current = createSeedPair();
    this.retired = [];
    this.inventory = [];
    this.mailbox = [];
    db.prepare(`DELETE FROM lootbox_session WHERE player_id = ?`).run(this.playerId);
    db.prepare(`DELETE FROM lootbox_retired WHERE player_id = ?`).run(this.playerId);
    db.prepare(`DELETE FROM lootbox_drop WHERE player_id = ?`).run(this.playerId);
    db.prepare(`DELETE FROM pending_case WHERE player_id = ?`).run(this.playerId);
    this.persistSession();
  }
}

/**
 * Per-player registry. Every player gets an isolated GameState (seeds,
 * inventory, mailbox) keyed by the X-Player-Id header, hydrated from SQLite
 * on first access so state survives restarts (issue #23).
 */
const sessions = new Map<string, GameState>();
const MAX_PLAYERS = Number(process.env.MAX_PLAYERS ?? 10_000);

export function stateFor(playerId: string): GameState {
  let session = sessions.get(playerId);
  if (!session) {
    if (sessions.size >= MAX_PLAYERS) {
      // Crude backstop for the demo: refuse new players rather than grow
      // unbounded. Real auth + quotas replace this later.
      throw new Error("PLAYER_CAPACITY");
    }
    session = new GameState();
    session.attach(playerId);
    sessions.set(playerId, session);
  }
  return session;
}

export function playerCount(): number {
  return sessions.size;
}

/**
 * Mint an owned drop for a character that never came out of a cookbook — a
 * barcode scan. This is what makes "sell or gamble any character" true for
 * monsters the app minted outside the lootbox path.
 */
export function mintCollectionDrop(
  playerId: string,
  character: Character,
  crateId: string,
  mint?: { value: number; rolls: LootDrop["rolls"] }
): StoredDrop {
  return stateFor(playerId).mintOwnedDrop(character, crateId, mint);
}

/** Legacy single-session export — kept only so old imports keep compiling.
 *  New code must use stateFor(playerId). */
export const state = new GameState();
state.attach("legacy");

/** Clears one player's session (used by POST /lootbox/reset with a header). */
export function resetPlayer(playerId: string): void {
  sessions.get(playerId)?.reset();
}

// ---------------------------------------------------------------------------
// Granted Cases (spec §3/§5)
//
// A Case is a promise of a monster of one rarity — ranked wins grant them,
// promos can grant them, and a Cookbook open is conceptually "buy a random
// Case, open it immediately". Persisted rows keep a granted Case durable
// across restarts and un-openable twice.
// ---------------------------------------------------------------------------

export interface PendingCase {
  caseId: string;
  rarity: Rarity;
  /** Who granted it: 'ranked_win', 'promo', ... */
  source: string;
  createdAt: string;
}

/**
 * Grant a Case of a fixed rarity. Called inside the granter's transaction so
 * a failed battle/promo never leaves a case behind.
 */
export function grantCase(playerId: string, rarity: Rarity, source: string): PendingCase {
  const row: PendingCase = {
    caseId: randomUUID(),
    rarity,
    source,
    createdAt: new Date().toISOString()
  };
  db.prepare(
    `INSERT INTO pending_case (case_id, player_id, rarity, source, created_at)
     VALUES (?, ?, ?, ?, ?)`
  ).run(row.caseId, playerId, rarity, source, row.createdAt);
  return row;
}

/** Cases waiting to be opened, oldest first. */
export function pendingCases(playerId: string): PendingCase[] {
  return (db
    .prepare(`SELECT case_id, rarity, source, created_at FROM pending_case WHERE player_id = ? ORDER BY created_at`)
    .all(playerId) as { case_id: string; rarity: string; source: string; created_at: string }[])
    .map((r) => ({ caseId: r.case_id, rarity: r.rarity as Rarity, source: r.source, createdAt: r.created_at }));
}

/**
 * Consume a pending case for opening. Returns the row and deletes it — a
 * delete inside the opener's transaction is what makes a double-open
 * impossible: the second call sees no row.
 */
export function consumeCase(playerId: string, caseId: string): PendingCase | null {
  const row = db
    .prepare(`SELECT case_id, rarity, source, created_at FROM pending_case WHERE player_id = ? AND case_id = ?`)
    .get(playerId, caseId) as { case_id: string; rarity: string; source: string; created_at: string } | undefined;
  if (!row) return null;
  db.prepare(`DELETE FROM pending_case WHERE player_id = ? AND case_id = ?`).run(playerId, caseId);
  return { caseId: row.case_id, rarity: row.rarity as Rarity, source: row.source, createdAt: row.created_at };
}
