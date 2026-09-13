// Per-player lootbox state: fairness seeds, key balance, inventory.
//
// State is kept in memory for cheap synchronous access and written through
// to SQLite (see db.ts) on every mutation, so a restart or redeploy keeps
// every player's keys, seeds, and history (issue #23). The in-memory copy
// is a cache; the database is the source of truth.

import { randomBytes, randomUUID } from "crypto";
import { Character, Fairness, LootDrop } from "../types";
import { hashSeed, newServerSeed } from "./lootboxEngine";
import { db } from "../db";
import { sampleCharacters } from "../data/sampleCharacters";
import { dropNetWorth } from "../game/rarityBands";

export const STARTING_KEYS = 25;
const MAX_HISTORY = 200;

/** The starting six are minted at the "Steady" band — the baseline power
 *  roll (data/lootTable.ts POWER_BANDS), never the floor or the ceiling. */
const STARTER_POWER = 55;
const STARTER_POWER_LABEL = "Steady";
const STARTER_POWER_MULTIPLIER = 1.0;

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
}

class GameState {
  keys = STARTING_KEYS;
  current: SeedPair = createSeedPair();
  retired: SeedPair[] = [];
  inventory: StoredDrop[] = [];
  /** Opens since the last Epic-or-better / Legendary-or-better pull. */
  sinceEpic = 0;
  sinceLegendary = 0;

  /** Set once by attach(); identifies the rows this session owns. */
  private playerId = "legacy";

  /** Hydrates this session from the database (no-op for a brand-new player). */
  attach(id: string): void {
    this.playerId = id;
    const row = db
      .prepare(
        `SELECT keys, server_seed, server_seed_hash, client_seed, nonce, created_at, since_epic, since_legendary, collection_seeded
         FROM lootbox_session WHERE player_id = ?`
      )
      .get(id) as
      | { keys: number; server_seed: string; server_seed_hash: string; client_seed: string; nonce: number; created_at: string; since_epic: number; since_legendary: number; collection_seeded: number }
      | undefined;

    if (row) {
      this.keys = row.keys;
      this.sinceEpic = row.since_epic ?? 0;
      this.sinceLegendary = row.since_legendary ?? 0;
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
      this.inventory = (db
        .prepare(
          `SELECT drop_id, payload, locked_by FROM lootbox_drop WHERE player_id = ? ORDER BY seq DESC LIMIT ?`
        )
        .all(id, MAX_HISTORY) as any[])
        // The columns, not the payload, are the authority on a drop's id and
        // lock state: rows written before ids existed were backfilled there.
        .map((r) => ({
          ...(JSON.parse(r.payload) as StoredDrop),
          id: r.drop_id as string,
          lockedBy: (r.locked_by as string | null) ?? null
        }))
        .reverse();
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
   * crate — the starter six, a barcode scan, a dish photo. Same value ladder
   * as crate drops (dropNetWorth), placeholder rolls since nothing was
   * gambled on the outcome.
   */
  mintOwnedDrop(character: Character, crateId: string): StoredDrop {
    return this.record({
      crateId,
      character,
      stars: 1,
      power: STARTER_POWER,
      powerLabel: STARTER_POWER_LABEL,
      shiny: false,
      value: dropNetWorth(character.rarity, STARTER_POWER_MULTIPLIER, false),
      // Not a gambling roll — there's nothing here to verify fairness
      // against, so these are placeholders, not a real commit-reveal.
      rolls: { rarity: 0, character: 0, power: 0.5, shiny: 0 },
      pityForced: null,
      fairness: { serverSeedHash: this.current.serverSeedHash, clientSeed: this.current.clientSeed, nonce: -1 },
      openedAt: new Date().toISOString()
    });
  }

  /**
   * One-shot backfill for sessions created before starter monsters and
   * scanned characters were real drops: mint whatever the collection says
   * the player owns but the inventory does not. Runs under the
   * `collection_seeded` flag, so it can never resurrect a sold monster.
   */
  private backfillCollectionDrops(): void {
    const ownedIds = new Set(this.inventory.map((d) => d.character.id));
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
      `INSERT INTO lootbox_session (player_id, keys, server_seed, server_seed_hash, client_seed, nonce, created_at, since_epic, since_legendary)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
       ON CONFLICT(player_id) DO UPDATE SET
         keys = excluded.keys,
         server_seed = excluded.server_seed,
         server_seed_hash = excluded.server_seed_hash,
         client_seed = excluded.client_seed,
         nonce = excluded.nonce,
         since_epic = excluded.since_epic,
         since_legendary = excluded.since_legendary`
    ).run(
      this.playerId,
      this.keys,
      this.current.serverSeed,
      this.current.serverSeedHash,
      this.current.clientSeed,
      this.current.nonce,
      this.current.createdAt,
      this.sinceEpic,
      this.sinceLegendary
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

  // -- economy --------------------------------------------------------------

  spendKeys(amount: number): boolean {
    // Reject zero/negative/non-integer amounts: `keys < amount` alone lets
    // spendKeys(0) "succeed" and spendKeys(-n) INCREASE the balance (QA M-001).
    if (!Number.isInteger(amount) || amount <= 0) return false;
    if (this.keys < amount) return false;
    this.keys -= amount;
    this.persistSession();
    return true;
  }

  grantKeys(amount: number): number {
    this.keys += amount;
    this.persistSession();
    return this.keys;
  }

  // -- inventory ------------------------------------------------------------

  record(drop: StoredDrop | Omit<StoredDrop, "id">): StoredDrop {
    const stored: StoredDrop = "id" in drop && drop.id ? drop : { ...drop, id: randomUUID() };
    this.inventory.push(stored);
    db.prepare(`INSERT INTO lootbox_drop (player_id, drop_id, payload) VALUES (?, ?, ?)`).run(
      this.playerId,
      stored.id,
      JSON.stringify(stored)
    );
    // The session row stays in step with every inventory write: nonce and
    // pity counters mutated by the caller are durable by the time the drop
    // exists, so a restart cannot rewind into used nonces or lost pity.
    this.persistSession();
    // Keep only the newest MAX_HISTORY unlocked rows per player. Locked
    // (escrowed/staked) monsters are never evicted — deleting one would
    // strand the round or arena battle that references it.
    db.prepare(
      `DELETE FROM lootbox_drop WHERE player_id = ? AND locked_by IS NULL AND seq NOT IN (
         SELECT seq FROM lootbox_drop WHERE player_id = ? AND locked_by IS NULL ORDER BY seq DESC LIMIT ?
       )`
    ).run(this.playerId, this.playerId, MAX_HISTORY);
    let excess = this.inventory.filter((d) => !d.lockedBy).length - MAX_HISTORY;
    for (let i = 0; excess > 0 && i < this.inventory.length; ) {
      if (this.inventory[i].lockedBy) {
        i++;
      } else {
        this.inventory.splice(i, 1);
        excess--;
      }
    }
    return stored;
  }

  /** One owned monster by its instance id. */
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
    this.keys = STARTING_KEYS;
    this.current = createSeedPair();
    this.retired = [];
    this.inventory = [];
    this.sinceEpic = 0;
    this.sinceLegendary = 0;
    db.prepare(`DELETE FROM lootbox_session WHERE player_id = ?`).run(this.playerId);
    db.prepare(`DELETE FROM lootbox_retired WHERE player_id = ?`).run(this.playerId);
    db.prepare(`DELETE FROM lootbox_drop WHERE player_id = ?`).run(this.playerId);
    this.persistSession();
  }
}

/**
 * Per-player registry. Every player gets an isolated GameState (keys, seeds,
 * inventory) keyed by the X-Player-Id header, hydrated from SQLite on first
 * access so state survives restarts (issue #23).
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
 * Mint an owned drop for a character that never came out of a crate — a
 * barcode scan, a dish photo. This is what makes "sell or gamble any
 * character" true for monsters the app minted outside the lootbox path.
 */
export function mintCollectionDrop(playerId: string, character: Character, crateId: string): StoredDrop {
  return stateFor(playerId).mintOwnedDrop(character, crateId);
}

/** Legacy single-session export — kept only so old imports keep compiling.
 *  New code must use stateFor(playerId). */
export const state = new GameState();
state.attach("legacy");

/** Clears one player's session (used by POST /lootbox/reset with a header). */
export function resetPlayer(playerId: string): void {
  stateFor(playerId).reset();
}
