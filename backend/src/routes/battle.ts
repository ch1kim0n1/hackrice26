import { Router } from "express";
import { createHash, randomBytes, randomUUID } from "crypto";
import { sampleCharacters } from "../data/sampleCharacters";
import { RARITY_ORDER, RARITY_TIERS } from "../data/lootTable";
import { Character, Rarity } from "../types";
import { requirePlayerId, PlayerRequest } from "../middleware/player";
import { rateLimitByPlayer } from "../middleware/security";
import {
  applyRankedToProfile,
  getOrCreate,
  recordBattle,
  saveProfile
} from "./user";
import { faintedIds, markFainted } from "../game/tasks";
import { db } from "../db";
import { roll } from "../services/lootboxEngine";
import { grantCase, stateFor } from "../services/lootboxState";
import { coinBalance, recordCoins } from "../services/coins";
import { hasDatabaseUrl } from "../db/pg";
import { BattleEventIn } from "../db/repositories/battleRepo";
import { attacksFor } from "../data/attacks";
import { fusionTierAsStar } from "../game/power";
import {
  Battle,
  BattleUnitSpec,
  MoveSpec,
  ScriptedAction,
  effectiveStat,
  simulateBattle
} from "../services/battleEngine";
import { asStarLevel } from "../game/rarityBands";
import {
  applyRankedResult,
  matchScore,
  rankForRR,
  rollRankedCaseRarity,
  RANK_LABELS,
  RankId
} from "../game/rr";
import { ROSTER, rosterCharacter } from "../data/roster";
import { battleCommitSchema } from "../schemas/gameSchemas";
import { enqueueMirror } from "../services/mirrorQueue";
import {
  DUNGEON_BOSS_EVERY,
  DUNGEON_BOSS_MULT,
  DUNGEON_BOSS_REWARD_MULT,
  DUNGEON_FLOOR_GROWTH,
  DUNGEON_FLOOR_REWARD_BASE,
  DUNGEON_FLOOR_REWARD_STEP,
  DUNGEON_TEAM_SIZE,
  SBMM_ATTACK_WEIGHT
} from "../game/spec";

export const battleRouter = Router();
battleRouter.use(requirePlayerId);

// ===== Deterministic battle simulation =====
// The engine lives in services/battleEngine.ts (spec §4: one active monster
// per side, alternating turns, no types, no tempo order, no global miss).
// This file owns the endpoints and the server-trusted squad resolution that
// hands the engine its locked battle-start snapshot. Same squads + seed
// produce the same outcome on device and server. Server is authoritative.

/**
 * Derived from the loot table rather than written out here.
 *
 * These were previously a hand-maintained list of four tiers while the loot
 * table dropped seven. The three missing tiers -- uncommon, mythic, secret,
 * about 16% of all crate pulls -- were rejected by squad validation, so a
 * character you had just pulled could not be taken into battle. Deriving the
 * map means adding a tier to the loot table cannot leave combat behind.
 */
export const RARITY_MULT: Record<Rarity, number> = Object.fromEntries(
  RARITY_ORDER.map((id) => [id, RARITY_TIERS[id].statMultiplier])
) as Record<Rarity, number>;

/**
 * A unit as the route layer sees it. `baseHealth`/`baseAttack` are
 * PRE-scaling bases — the engine applies rarity × star itself (spec §4).
 * There is no statType/element and no four-stat blob: the spec's combat
 * model is Health + Base Attack + Mana only.
 */
export interface SimUnit {
  id: string;
  name: string;
  baseHealth: number;
  baseAttack: number;
  /** 1...5 mastery stars (Secret clamps to ★2 inside the engine). */
  star?: number;
  /** @deprecated legacy alias: 0..5, mapped to star via fusionTierAsStar. */
  fusionTier?: number;
  rarity?: Rarity;
  /** Roster slug — drives attacksFor() when moves are not passed. */
  characterKey?: string;
  /** Resolved moveset for this instance (issue #107). */
  moves?: MoveSpec[];
  /** Authored Mana pool — meaningful only at Epic+ (spec §4). */
  baseMana?: number;
}

/** SimUnit -> the engine's locked snapshot spec. */
function specFor(u: SimUnit): BattleUnitSpec {
  const rarity = u.rarity ?? "common";
  return {
    id: u.id,
    name: u.name,
    baseHealth: u.baseHealth,
    baseAttack: u.baseAttack,
    rarity,
    star: u.star ?? fusionTierAsStar(u.fusionTier),
    moves: u.moves ?? attacksFor(u.characterKey ?? u.id, rarity),
    baseMana: u.baseMana
  };
}

/**
 * Whole-match resolution, auto-policy on both sides. Returns the legacy
 * response shape ({ winner, rounds, events, hpLeftA }) over the engine's
 * result so endpoint contracts hold while the engine moved on.
 */
export function simulate(
  squadA: SimUnit[],
  squadB: SimUnit[],
  seed: bigint,
  opts?: { carryHP?: number[] }
): { winner: string; rounds: number; events: object[]; hpLeftA: number[]; hpLeftB: number[]; faintedA: string[]; faintedB: string[] } {
  const result = simulateBattle(squadA.map(specFor), squadB.map(specFor), seed, {
    firstTurn: "coinFlip",
    carryHPA: opts?.carryHP
  });
  return {
    winner: result.winner,
    rounds: result.turns,
    events: result.events,
    hpLeftA: result.hpFractionsA,
    hpLeftB: result.hpFractionsB,
    faintedA: result.faintedA,
    faintedB: result.faintedB
  };
}

type SquadUnitIn = { id?: unknown; name?: unknown; statType?: unknown; rarity?: unknown; star?: unknown; starLevel?: unknown; fusionTier?: unknown; characterKey?: unknown; power?: unknown; guard?: unknown; vitality?: unknown; tempo?: unknown };

/** Shared squad validation for /simulate and /async/challenge. `statType` is
 *  still accepted (older clients send it) but no longer required — the type
 *  system is gone. */
function squadError(name: string, squad: SquadUnitIn[]): string | null {
  for (const [i, unit] of squad.entries()) {
    if (typeof unit?.id !== "string" || unit.id.length === 0 || unit.id.length > 64) {
      return `${name}[${i}].id must be a string of 1-64 characters`;
    }
    if (typeof unit?.name !== "string" || unit.name.length === 0 || unit.name.length > 64) {
      return `${name}[${i}].name must be a string of 1-64 characters`;
    }
    if (unit.statType !== undefined && typeof unit.statType !== "string") {
      return `${name}[${i}].statType must be a string when present`;
    }
    if (unit.rarity !== undefined && !(typeof unit.rarity === "string" && unit.rarity in RARITY_MULT)) {
      return `${name}[${i}].rarity must be one of: ${Object.keys(RARITY_MULT).join(", ")}`;
    }
    if (unit.fusionTier !== undefined && (!Number.isInteger(unit.fusionTier) || (unit.fusionTier as number) < 0 || (unit.fusionTier as number) > 5)) {
      return `${name}[${i}].fusionTier must be an integer between 0 and 5`;
    }
    const star = unit.star ?? unit.starLevel;
    if (star !== undefined && (!Number.isInteger(star) || (star as number) < 1 || (star as number) > 5)) {
      return `${name}[${i}].star must be an integer between 1 and 5`;
    }
    if (unit.characterKey !== undefined && (typeof unit.characterKey !== "string" || unit.characterKey.length > 64)) {
      return `${name}[${i}].characterKey must be a string of at most 64 characters`;
    }
    for (const stat of ["power", "guard", "vitality", "tempo"] as const) {
      const v = (unit as Record<string, unknown>)[stat];
      if (v !== undefined && (!Number.isFinite(v) || (v as number) < 0 || (v as number) > 500)) {
        return `${name}[${i}].${stat} must be a finite number between 0 and 500`;
      }
    }
  }
  return null;
}

// Base stats stay UNSCALED here — the engine applies rarity × star itself
// (spec §4). Roster ids resolve to the authored catalog (baseHealth /
// baseAttack / baseMana / moves); the legacy power/guard/vitality/tempo
// payload maps onto the two-stat model for callers that still send it.
// Legacy fusionTier maps through fusionTierAsStar so old clients keep working.
function toSim(c: {
  id: string; name: string;
  rarity?: string; star?: number; starLevel?: number; fusionTier?: number;
  characterKey?: string;
  power?: number; guard?: number; vitality?: number; tempo?: number;
}): SimUnit {
  // Squad validation already rejects unknown tiers, so an unrecognised value
  // here means rarity was simply omitted -- treat that as common rather than
  // silently scaling by an undefined multiplier.
  const rarity =
    c.rarity !== undefined && c.rarity in RARITY_MULT
      ? (c.rarity as Rarity)
      : ("common" as Rarity);
  const star = Math.min(
    5,
    Math.max(1, c.star ?? c.starLevel ?? fusionTierAsStar(c.fusionTier))
  );
  const catalog = rosterCharacter(c.characterKey ?? c.id);
  const unit: SimUnit = {
    id: c.id,
    name: c.name,
    baseHealth: catalog?.baseHealth ?? 55 + (c.vitality ?? 50) * 1.1,
    baseAttack: catalog?.baseAttack ?? c.power ?? 50,
    star,
    rarity,
    baseMana: catalog?.baseMana
  };
  if (catalog) {
    unit.characterKey = catalog.id;
    unit.moves = attacksFor(catalog.id, rarity);
  }
  return unit;
}

// ===== Server-trusted squads =================================================
//
// A request names WHICH units fight; the server decides WHAT they are.
// Rarity, star level, stats and moveset are resolved here from server-side
// data — the starter roster, the loot catalogue, the player's own scan
// records and owned drops — because the body used to carry `power`, `star`
// and `rarity` straight into the sim: a client could field a fabricated
// god-squad and cash out arena stakes, rank points and XP on it. The payload
// keeps its shape for compatibility, but every strength-bearing field is
// re-derived and the client's value is ignored.

const STARTER_BY_ID = new Map(
  sampleCharacters.filter((c) => !c.isLocked).map((c) => [c.id, c] as const)
);

export const BATTLE_ERRORS = { SQUAD_UNOWNED: "SQUAD_UNOWNED" } as const;

/** The server-known form of a unit: everything the sim needs, nothing the client supplied. */
interface TrustedUnit {
  id: string;
  name: string;
  rarity: Rarity;
  star: number;
  characterKey?: string;
  /** Per-instance combat base — scan mints can carry their own stats. */
  baseHealth?: number;
  baseAttack?: number;
  baseMana?: number;
}

/** A scanned/photographed character the player actually minted. */
function scannedCharacter(playerId: string, charId: string): Character | null {
  const row = db
    .prepare(`SELECT payload FROM scan_character WHERE player_id = ? AND char_id = ?`)
    .get(playerId, charId) as { payload: string } | undefined;
  if (!row) return null;
  try {
    return JSON.parse(row.payload) as Character;
  } catch {
    return null;
  }
}

/** Highest ★ among the player's owned drops of `characterId`; 0 if unowned. */
function ownedStarLevel(playerId: string, characterId: string): number {
  let best = 0;
  for (const drop of stateFor(playerId).inventory) {
    if (drop.character.id === characterId) best = Math.max(best, asStarLevel(drop.stars));
  }
  return best;
}

/**
 * Rarity of the player's best owned drop of `characterId` — the catalog
 * carries no rarity (a mint rolls it), so combat rarity comes from the
 * instance the player actually owns. Best = highest ★, then highest tier.
 */
function rarityForOwnedDrop(playerId: string, characterId: string): Rarity {
  let best: Rarity = "common";
  let bestStar = -1;
  let bestOrder = -1;
  for (const drop of stateFor(playerId).inventory) {
    if (drop.character.id !== characterId) continue;
    const star = asStarLevel(drop.stars);
    const order = RARITY_ORDER.indexOf(drop.character.rarity);
    if (star > bestStar || (star === bestStar && order > bestOrder)) {
      best = drop.character.rarity;
      bestStar = star;
      bestOrder = order;
    }
  }
  return best;
}

/** Authored-moveset slug when this id exists in the roster (issue #107). */
function characterKeyFor(id: string): string | undefined {
  return rosterCharacter(id) ? id : undefined;
}

function trustedUnit(
  id: string,
  name: string,
  rarity: Rarity,
  star: number,
  stats?: { baseHealth?: number; baseAttack?: number; baseMana?: number }
): TrustedUnit {
  return { id, name, rarity, star, characterKey: characterKeyFor(id), ...stats };
}

/**
 * Caller's side of a battle: the unit must be one the player can actually
 * field — a starter, a minted scan/dish character, or a catalogue monster the
 * player owns a drop of. Anything else is rejected outright, because an
 * unowned catalogue id would hand out its printed rarity for free.
 */
function resolveOwnUnit(playerId: string, unit: SquadUnitIn): TrustedUnit {
  const id = unit.id as string;
  const starter = STARTER_BY_ID.get(id);
  if (starter) {
    return trustedUnit(id, starter.name, starter.rarity, 1, {
      baseHealth: starter.baseHealth,
      baseAttack: starter.baseAttack
    });
  }
  const scanned = scannedCharacter(playerId, id);
  if (scanned) {
    return trustedUnit(id, scanned.name, scanned.rarity, 1, {
      baseHealth: scanned.baseHealth,
      baseAttack: scanned.baseAttack,
      baseMana: scanned.baseMana
    });
  }
  const catalogue = rosterCharacter(id);
  const star = catalogue ? ownedStarLevel(playerId, id) : 0;
  if (catalogue && star > 0) {
    return trustedUnit(id, catalogue.name, rarityForOwnedDrop(playerId, id), star, {
      baseHealth: catalogue.baseHealth,
      baseAttack: catalogue.baseAttack,
      baseMana: catalogue.baseMana
    });
  }
  throw new Error(`${BATTLE_ERRORS.SQUAD_UNOWNED}:${id}`);
}

/**
 * Enemy side of a battle. `ownerId` is the collection the unit claims to come
 * from — the caller for /simulate, the defender for stored snapshots. Known
 * units resolve to server truth (catalogue/starter/scan rarity, the owner's
 * current ★ for catalogue monsters); unknown ids degrade to a ★1 common —
 * enough for the sim to run, never an upgrade for whoever chose them.
 */
function resolveEnemyUnit(ownerId: string, unit: SquadUnitIn): TrustedUnit {
  const id = unit.id as string;
  const catalogue = rosterCharacter(id);
  if (catalogue) {
    return trustedUnit(id, catalogue.name, rarityForOwnedDrop(ownerId, id), Math.max(1, ownedStarLevel(ownerId, id)), {
      baseHealth: catalogue.baseHealth,
      baseAttack: catalogue.baseAttack,
      baseMana: catalogue.baseMana
    });
  }
  const starter = STARTER_BY_ID.get(id);
  if (starter) {
    return trustedUnit(id, starter.name, starter.rarity, 1, {
      baseHealth: starter.baseHealth,
      baseAttack: starter.baseAttack
    });
  }
  const scanned = scannedCharacter(ownerId, id);
  if (scanned) {
    return trustedUnit(id, scanned.name, scanned.rarity, 1, {
      baseHealth: scanned.baseHealth,
      baseAttack: scanned.baseAttack,
      baseMana: scanned.baseMana
    });
  }
  return { id, name: unit.name as string, rarity: "common", star: 1 };
}

/** Resolved unit -> SimUnit: flat base stats; the engine applies rarity × ★. */
function trustedToSim(u: TrustedUnit): SimUnit {
  const catalog = rosterCharacter(u.characterKey ?? u.id);
  const sim: SimUnit = {
    id: u.id,
    name: u.name,
    baseHealth: u.baseHealth ?? catalog?.baseHealth ?? 110,
    baseAttack: u.baseAttack ?? catalog?.baseAttack ?? 50,
    star: u.star,
    rarity: u.rarity,
    baseMana: u.baseMana ?? catalog?.baseMana
  };
  if (u.characterKey ?? catalog?.id) {
    sim.characterKey = u.characterKey ?? catalog?.id;
    sim.moves = attacksFor(sim.characterKey!, u.rarity);
  }
  return sim;
}

/** Resolve the caller's squad; returns an error string instead of throwing. */
function resolveOwnSquad(playerId: string, squad: SquadUnitIn[]): TrustedUnit[] | { error: string } {
  try {
    return squad.map((u) => resolveOwnUnit(playerId, u));
  } catch (err) {
    const message = err instanceof Error ? err.message : String(err);
    const id = message.startsWith(BATTLE_ERRORS.SQUAD_UNOWNED) ? message.split(":").pop() : "?";
    return {
      error: `Unit '${id}' is not in your collection; squads are built from starters, scanned characters, and monsters you own.`
    };
  }
}

/** Persist the caller's RESOLVED squad as the snapshot friends can challenge.
 *  `v: 2` marks a server-trusted payload; legacy rows were client-authored and
 *  are re-resolved at load time. */
function saveSquadSnapshot(playerId: string, units: TrustedUnit[]): void {
  db.prepare(
    `INSERT INTO friend_squad (player_id, payload, updated_at) VALUES (?, ?, datetime('now'))
     ON CONFLICT(player_id) DO UPDATE SET payload = excluded.payload, updated_at = excluded.updated_at`
  ).run(playerId, JSON.stringify({ v: 2, units }));
}

/**
 * The defender's stored squad, resolved against THEIR collection at load time.
 * v2 payloads are already server-trusted but catalogue ★ is re-derived from
 * the owner's current inventory, so a snapshot cannot fight with monsters that
 * were sold or merged away. Legacy payloads were client-authored, so each unit
 * is re-resolved the lenient (enemy) way and the squad is dropped if invalid.
 */
function loadSquadSnapshot(ownerId: string): SimUnit[] | null {
  const snap = db
    .prepare(`SELECT payload FROM friend_squad WHERE player_id = ?`)
    .get(ownerId) as { payload: string } | undefined;
  if (!snap) return null;
  let parsed: unknown;
  try {
    parsed = JSON.parse(snap.payload);
  } catch {
    return null;
  }

  const refreshStar = (u: TrustedUnit): TrustedUnit =>
    rosterCharacter(u.id) ? { ...u, star: Math.max(1, ownedStarLevel(ownerId, u.id)) } : u;

  if (parsed && typeof parsed === "object" && !Array.isArray(parsed)) {
    const units = (parsed as { units?: unknown }).units;
    if (!Array.isArray(units) || units.length < 1) return null;
    const trusted = units.filter(
      (u): u is TrustedUnit =>
        typeof (u as TrustedUnit)?.id === "string" &&
        typeof (u as TrustedUnit)?.name === "string" &&
        typeof (u as TrustedUnit)?.rarity === "string" &&
        (u as TrustedUnit).rarity in RARITY_MULT &&
        Number.isInteger((u as TrustedUnit).star)
    );
    return trusted.length ? trusted.map((u) => trustedToSim(refreshStar(u))) : null;
  }

  if (Array.isArray(parsed)) {
    const raw = parsed as SquadUnitIn[];
    if (raw.length < 1 || raw.length > 5 || squadError("opponentSquad", raw)) return null;
    return raw.map((u) => trustedToSim(resolveEnemyUnit(ownerId, u)));
  }
  return null;
}

/** Matchmaking power estimate — spec §5: MonsterPower = EffectiveHealth +
 *  EffectiveAttack (AttackWeight 1 until real ranges land). */
function simPower(units: SimUnit[]): number {
  if (!units.length) return 0;
  return (
    units.reduce(
      (s, u) =>
        s +
        effectiveStat(u.baseHealth, u.rarity ?? "common", u.star ?? 1) +
        effectiveStat(u.baseAttack, u.rarity ?? "common", u.star ?? 1),
      0
    ) / units.length
  );
}

// ===== Interactive matches (begin / commit) =================================
//
// Spec §4 battles are player-driven. The flow is two-phase so the server
// stays authoritative without a socket:
//
//   begin  — resolve the caller's squad to server truth, pick the opponent
//            (SBMM / stored snapshot / bot), draw the seed, and park the
//            whole locked matchup in battle_match. The response carries the
//            full resolved specs both sides, so the client runs the same
//            deterministic engine the server will.
//   commit — the client submits the decisions it made (move/switch per own
//            turn, choose for faint replacements). The server replays them
//            through runScripted: every entry must be legal, the seed and
//            squads are the parked ones, and the opponent is the engine's
//            auto policy — so a client cannot fake an outcome, only choose
//            its own line of play. The match row is single-use and expires.
//
// A commit that fails script validation still consumes the match: retrying
// with a "fixed" script would let a client probe outcomes consequence-free.

const MATCH_TTL_MS = 15 * 60_000;

interface MatchRow {
  id: string;
  player_id: string;
  mode: string;
  own_squad: string;
  opp_squad: string;
  opponent_id: string | null;
  is_bot: number;
  meta: string | null;
  seed: string;
  consumed_at: string | null;
  expires_at: string;
}

function parkMatch(
  playerId: string,
  mode: "ranked" | "friendly",
  own: SimUnit[],
  opp: SimUnit[],
  extra: { opponentId?: string | null; isBot?: boolean; meta?: object } = {}
): { matchId: string; seed: string } {
  const matchId = randomUUID();
  const seed = BigInt(`0x${randomBytes(8).toString("hex")}`).toString();
  const expires = new Date(Date.now() + MATCH_TTL_MS).toISOString();
  db.prepare(
    `INSERT INTO battle_match
       (id, player_id, mode, own_squad, opp_squad, opponent_id, is_bot, meta, seed, expires_at)
     VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`
  ).run(
    matchId, playerId, mode,
    JSON.stringify(own), JSON.stringify(opp),
    extra.opponentId ?? null, extra.isBot ? 1 : 0,
    extra.meta ? JSON.stringify(extra.meta) : null,
    seed, expires
  );
  // Cheap hygiene: drop rows that can never be committed again.
  db.prepare(`DELETE FROM battle_match WHERE expires_at < ? OR consumed_at IS NOT NULL`)
    .run(new Date(Date.now() - MATCH_TTL_MS).toISOString());
  return { matchId, seed };
}

/**
 * Atomically consume a pending match. Returns the row, or null when the id
 * is unknown, belongs to another player/mode, already used, or expired —
 * the UPDATE itself is the single-use guard, so a double-commit races
 * safely.
 */
function takeMatch(playerId: string, matchId: string, mode: "ranked" | "friendly"): MatchRow | null {
  const changed = db
    .prepare(
      `UPDATE battle_match SET consumed_at = datetime('now')
       WHERE id = ? AND player_id = ? AND mode = ?
         AND consumed_at IS NULL AND expires_at > datetime('now')`
    )
    .run(matchId, playerId, mode).changes;
  if (!changed) return null;
  return db.prepare(`SELECT * FROM battle_match WHERE id = ?`).get(matchId) as unknown as MatchRow;
}

/** Full resolved spec for the wire — the client builds its local engine
 *  and its presentation from exactly what the server will replay. */
function specDTO(u: SimUnit) {
  return {
    id: u.id,
    name: u.name,
    baseHealth: u.baseHealth,
    baseAttack: u.baseAttack,
    star: u.star ?? 1,
    rarity: u.rarity ?? "common",
    baseMana: u.baseMana,
    moves: u.moves ?? attacksFor(u.characterKey ?? u.id, u.rarity ?? "common")
  };
}

/** Replay a committed script against a parked match. */
function replayMatch(row: MatchRow, actions: ScriptedAction[]) {
  const own = JSON.parse(row.own_squad) as SimUnit[];
  const opp = JSON.parse(row.opp_squad) as SimUnit[];
  const battle = new Battle(own.map(specFor), opp.map(specFor), BigInt(row.seed), {
    firstTurn: "coinFlip",
    manualReplacement: 0
  });
  return battle.runScripted(actions);
}

// POST /battle/simulate { yourSquad, opponentSquad, seed? } -- deterministic,
// server-authoritative resolution. Seed = HMAC(matchId) in production;
// body seed accepted for demo.
battleRouter.post("/simulate", rateLimitByPlayer({ windowMs: 60_000, max: 60, keyPrefix: "battle", message: "Too many battles. Try again later." }), (req: PlayerRequest, res) => {
  const { yourSquad, opponentSquad, seed } = req.body as {
    yourSquad?: SquadUnitIn[];
    opponentSquad?: SquadUnitIn[];
    seed?: number | string | null;
  };
  if (!Array.isArray(yourSquad) || !Array.isArray(opponentSquad)) {
    return res.status(400).json({ error: "yourSquad and opponentSquad must be arrays" });
  }
  if (yourSquad.length < 1 || yourSquad.length > 3 || opponentSquad.length < 1 || opponentSquad.length > 3) {
    return res.status(400).json({ error: "squads must contain 1-3 units each" });
  }

  const yourError = squadError("yourSquad", yourSquad);
  if (yourError) return res.status(400).json({ error: yourError });
  const oppError = squadError("opponentSquad", opponentSquad);
  if (oppError) return res.status(400).json({ error: oppError });

  // Resolve seed: accept number, numeric string, or null/undefined (default).
  // Strings preserve precision for integers > Number.MAX_SAFE_INTEGER,
  // which the Swift engine accepts as UInt64.
  let seedBigInt: bigint;
  if (seed === undefined || seed === null) {
    seedBigInt = BigInt(Date.now());
  } else if (typeof seed === "string") {
    if (!/^\d+$/.test(seed)) {
      return res.status(400).json({ error: "seed string must be non-negative decimal digits" });
    }
    seedBigInt = BigInt(seed);
  } else if (typeof seed === "number") {
    if (!Number.isFinite(seed) || seed < 0) {
      return res.status(400).json({ error: "seed must be a non-negative finite number" });
    }
    seedBigInt = BigInt(Math.floor(seed));
  } else {
    return res.status(400).json({ error: "seed must be a number, numeric string, or null" });
  }

  // Server-side resolution: the request picks which units fight; what they
  // are is re-derived from the player's collection. Nothing about a unit's
  // strength is taken from the body.
  const yourTrusted = resolveOwnSquad(req.playerId!, yourSquad);
  if ("error" in yourTrusted) return res.status(400).json({ error: yourTrusted.error });
  const yourUnits = yourTrusted.map(trustedToSim);
  const oppUnits = opponentSquad.map((u) => trustedToSim(resolveEnemyUnit(req.playerId!, u)));

  // The caller's squad becomes the snapshot friends can challenge offline.
  saveSquadSnapshot(req.playerId!, yourTrusted);

  const result = simulate(yourUnits, oppUnits, seedBigInt);

  // Friendly mode (spec §5): the caller names BOTH squads, so the result
  // moves no RR and no leaderboard position — it is recorded in battle
  // history with rrDelta 0, nothing more. /battle/ranked pays because the
  // opponent there is server-controlled.

  const youWon = result.winner === "A";
  markFainted(req.playerId!, result.faintedA);
  recordBattle(req.playerId!, "friendly", youWon ? "win" : "loss", {
    opponent: "custom",
    squad: yourUnits.map((u) => ({ id: u.id, name: u.name })),
    detail: { rounds: result.rounds, events: result.events }
  });

  res.json({
    ...result,
    // Snapshot now carries each unit's resolved moveset (issue #103) with
    // full move defs so clients can render power/accuracy/mana costs.
    movesets: [...yourUnits, ...oppUnits].map((u) => ({
      id: u.id,
      moves: u.moves ?? attacksFor(u.characterKey ?? u.id, u.rarity ?? "common")
    }))
  });
});

// ===== Friendly PvP =========================================================
//
// Fight another player's stored squad snapshot. Friendly battles land in
// battle history for BOTH players but never move RR (spec §5/§6).

interface FriendlySetup {
  yourUnits: SimUnit[];
  oppUnits: SimUnit[];
}

/** Shared validation+resolution for the friendly endpoints. */
function setupFriendly(playerId: string, opponentId: unknown, squad: unknown): FriendlySetup | { status: number; body: object } {
  if (typeof opponentId !== "string" || opponentId.length < 1 || opponentId.length > 64) {
    return { status: 400, body: { error: "opponentId must be a string of 1-64 characters" } };
  }
  if (opponentId === playerId) {
    return { status: 400, body: { error: "You cannot battle yourself." } };
  }
  if (!Array.isArray(squad) || squad.length !== DUNGEON_TEAM_SIZE) {
    return { status: 400, body: { error: "squad must contain exactly 3 units" } };
  }
  const yourError = squadError("yourSquad", squad);
  if (yourError) return { status: 400, body: { error: yourError } };

  const oppUnits = loadSquadSnapshot(opponentId);
  if (!oppUnits) {
    return { status: 404, body: { error: { code: "NO_SNAPSHOT", message: "That player has no battle squad yet." } } };
  }

  const yourTrusted = resolveOwnSquad(playerId, squad);
  if ("error" in yourTrusted) return { status: 400, body: { error: yourTrusted.error } };
  saveSquadSnapshot(playerId, yourTrusted);
  return { yourUnits: yourTrusted.map(trustedToSim), oppUnits };
}

/** Record + mirror a resolved friendly result. No RR moves, ever. */
function applyFriendlyOutcome(playerId: string, opponentId: string, seed: string, result: { winner: string; rounds: number; events: object[]; faintedA: string[] }, yourUnits: SimUnit[], oppUnits: SimUnit[]): void {
  const youWon = result.winner === "A";
  markFainted(playerId, result.faintedA);
  recordBattle(playerId, "friendly", youWon ? "win" : "loss", {
    opponent: opponentId,
    squad: yourUnits.map((u) => ({ id: u.id, name: u.name })),
    detail: { rounds: result.rounds, events: result.events }
  });
  // The defender's history is complete too — a friendly defense is a result.
  recordBattle(opponentId, "friendly", youWon ? "loss" : "win", {
    opponent: playerId,
    squad: oppUnits.map((u) => ({ id: u.id, name: u.name })),
    detail: { rounds: result.rounds, events: result.events, defended: true }
  });

  // Best-effort mirror into TigerData: relational battle + event/metric hypertables.
  if (hasDatabaseUrl()) {
    // Keyed on the pairing plus the moment it resolved: a retried request
    // must not mirror the same fight twice, but a rematch is a new battle.
    enqueueMirror("friend_battle", `${playerId}:${opponentId}:${seed}`, {
      challengerId: playerId,
      defenderId: opponentId,
      winnerSide: youWon ? 0 : 1,
      rounds: result.rounds,
      events: result.events as BattleEventIn[],
    });
  }
}

// POST /battle/friendly { opponentId, squad } — legacy auto-resolve.
battleRouter.post("/friendly", rateLimitByPlayer({ windowMs: 60_000, max: 20, keyPrefix: "friendly", message: "Too many friendly battles. Try again later." }), (req: PlayerRequest, res) => {
  const { opponentId, squad } = req.body as { opponentId?: string; squad?: SquadUnitIn[] };
  const setup = setupFriendly(req.playerId!, opponentId, squad);
  if ("status" in setup) return res.status(setup.status).json(setup.body);

  const seed = BigInt(`0x${randomBytes(8).toString("hex")}`);
  const result = simulate(setup.yourUnits, setup.oppUnits, seed);
  applyFriendlyOutcome(req.playerId!, opponentId as string, seed.toString(), result, setup.yourUnits, setup.oppUnits);

  res.json({
    ...result,
    opponentId,
    opponentSquad: setup.oppUnits.map((u) => ({ id: u.id, name: u.name, star: u.star, rarity: u.rarity, baseHealth: u.baseHealth, baseAttack: u.baseAttack, baseMana: u.baseMana }))
  });
});

// POST /battle/friendly/begin { opponentId, squad } — park an interactive
// friendly against a stored snapshot; returns resolved specs + the seed.
battleRouter.post("/friendly/begin", rateLimitByPlayer({ windowMs: 60_000, max: 20, keyPrefix: "friendly", message: "Too many friendly battles. Try again later." }), (req: PlayerRequest, res) => {
  const { opponentId, squad } = req.body as { opponentId?: string; squad?: SquadUnitIn[] };
  const setup = setupFriendly(req.playerId!, opponentId, squad);
  if ("status" in setup) return res.status(setup.status).json(setup.body);

  const { matchId, seed } = parkMatch(req.playerId!, "friendly", setup.yourUnits, setup.oppUnits, {
    opponentId: opponentId as string
  });
  res.json({
    matchId,
    seed,
    opponentId,
    yourSquad: setup.yourUnits.map(specDTO),
    opponentSquad: setup.oppUnits.map(specDTO)
  });
});

// POST /battle/friendly/commit { matchId, actions } — replay the script.
battleRouter.post("/friendly/commit", rateLimitByPlayer({ windowMs: 60_000, max: 20, keyPrefix: "friendly", message: "Too many friendly battles. Try again later." }), (req: PlayerRequest, res) => {
  const parsed = battleCommitSchema.safeParse(req.body);
  if (!parsed.success) return res.status(400).json({ error: parsed.error.issues[0]?.message ?? "invalid body" });

  const row = takeMatch(req.playerId!, parsed.data.matchId, "friendly");
  if (!row) return res.status(410).json({ error: { code: "MATCH_GONE", message: "Match is unknown, already resolved, or expired." } });

  const replay = replayMatch(row, parsed.data.actions);
  if (!replay.ok) return res.status(400).json({ error: { code: "ILLEGAL_SCRIPT", message: replay.error } });
  const result = replay.result;

  const oppUnits = JSON.parse(row.opp_squad) as SimUnit[];
  const yourUnits = JSON.parse(row.own_squad) as SimUnit[];
  applyFriendlyOutcome(req.playerId!, row.opponent_id!, row.seed, {
    winner: result.winner, rounds: result.turns, events: result.events,
    faintedA: result.faintedA
  }, yourUnits, oppUnits);

  res.json({
    winner: result.winner,
    rounds: result.turns,
    events: result.events,
    hpLeftA: result.hpFractionsA,
    hpLeftB: result.hpFractionsB,
    faintedA: result.faintedA,
    faintedB: result.faintedB,
    opponentId: row.opponent_id,
    opponentSquad: oppUnits.map((u) => ({ id: u.id, name: u.name, star: u.star, rarity: u.rarity, baseHealth: u.baseHealth, baseAttack: u.baseAttack, baseMana: u.baseMana }))
  });
});

// ===== Endless dungeon ======================================================
//
// Field exactly 3 monsters; they fight floor after floor of escalating
// squads until wiped. HP persists between floors (real per-unit fractions
// from simulate), every 5th floor is a boss. Floors pay coins on clear —
// earned coins are kept even on wipe. Run-scoped faints clear when the run
// ends; there is no idle income.

/** Compute bound for a run — the spec mode is endless, a request is not.
 *  A party still alive at this floor ends the run as "complete". */
export const DUNGEON_SAFETY_CAP = 500;

interface DungeonRow {
  best_floor: number;
  last_run_at: string | null;
}

function dungeonStateFor(playerId: string): DungeonRow {
  let row = db
    .prepare(`SELECT best_floor, last_run_at FROM dungeon_state WHERE player_id = ?`)
    .get(playerId) as DungeonRow | undefined;
  if (!row) {
    db.prepare(`INSERT INTO dungeon_state (player_id, best_floor, last_claim_at) VALUES (?, 0, datetime('now'))`).run(playerId);
    row = { best_floor: 0, last_run_at: null };
  }
  return row;
}

/** Coins one cleared floor pays (spec §5): 100 + 25×(floor−1), ×3 on bosses. */
export function dungeonFloorReward(floor: number): number {
  const boss = floor % DUNGEON_BOSS_EVERY === 0;
  return (DUNGEON_FLOOR_REWARD_BASE + DUNGEON_FLOOR_REWARD_STEP * (floor - 1)) * (boss ? DUNGEON_BOSS_REWARD_MULT : 1);
}

/** Enemy stat scaling (spec §5): base × (1 + 0.05×(floor−1)) × boss 1.25. */
export function dungeonFloorMultiplier(floor: number): number {
  const boss = floor % DUNGEON_BOSS_EVERY === 0;
  return (1 + DUNGEON_FLOOR_GROWTH * (floor - 1)) * (boss ? DUNGEON_BOSS_MULT : 1);
}

/**
 * One floor's defending squad, deterministic from runSeed+floor. Enemies are
 * emitted as common/★1 so the engine's rarity×star scaling leaves the spec's
 * floor formula untouched — the multiplier lives in baseHealth/baseAttack.
 */
function dungeonFloor(floor: number, runSeed: string): { units: SimUnit[]; boss: boolean } {
  const boss = floor % DUNGEON_BOSS_EVERY === 0;
  const statMult = dungeonFloorMultiplier(floor);

  const units: SimUnit[] = [];
  for (let i = 0; i < DUNGEON_TEAM_SIZE; i++) {
    const c = ROSTER[Math.floor(roll(runSeed, "unit", floor, i) * ROSTER.length)];
    units.push({
      id: `${c.id}-f${floor}`,
      name: c.name,
      baseHealth: c.baseHealth * statMult,
      baseAttack: c.baseAttack * statMult,
      star: 1,
      rarity: "common",
      characterKey: c.id,
      moves: attacksFor(c.id, "common")
    });
  }
  return { units, boss };
}

/** One full run: floors until the party wipes (or the safety cap stands).
 *  Deterministic given runSeed. HP persists between floors via carryHP; a
 *  unit at 0 HP stays out for the rest of the run (run-scoped faints). */
export function runDungeonFloors(party: SimUnit[], runSeed: string) {
  const hp = party.map(() => 1);
  const feed: { floor: number; boss: boolean; won: boolean; rounds: number; enemies: string[]; events: object[]; reward: number }[] = [];
  let floorsCleared = 0;

  for (let floor = 1; floor <= DUNGEON_SAFETY_CAP; floor++) {
    const aliveIdx = party.map((_, i) => i).filter((i) => hp[i] > 0);
    if (aliveIdx.length === 0) break;
    const { units: enemies, boss } = dungeonFloor(floor, runSeed);
    const sim = simulate(
      aliveIdx.map((i) => party[i]),
      enemies,
      BigInt(`0x${createHash("sha256").update(`${runSeed}:${floor}`).digest("hex").slice(0, 16)}`),
      { carryHP: aliveIdx.map((i) => hp[i]) }
    );
    sim.hpLeftA.forEach((f, j) => { hp[aliveIdx[j]] = f; });
    const won = sim.winner === "A";
    feed.push({ floor, boss, won, rounds: sim.rounds, enemies: enemies.map((e) => e.name), events: sim.events, reward: won ? dungeonFloorReward(floor) : 0 });
    if (won) floorsCleared = floor; else break;
  }
  return { floorsCleared, feed, completed: floorsCleared >= DUNGEON_SAFETY_CAP };
}

// POST /battle/dungeon/run { squad } -- auto-resolve floors until the party
// wipes. Server-side: the whole run is one deterministic chain off runSeed.
battleRouter.post("/dungeon/run", rateLimitByPlayer({ windowMs: 60_000, max: 10, keyPrefix: "dungeon", message: "Too many dungeon runs. Try again later." }), (req: PlayerRequest, res) => {
  const { squad } = req.body as { squad?: SquadUnitIn[] };
  if (!Array.isArray(squad) || squad.length !== DUNGEON_TEAM_SIZE) {
    return res.status(400).json({ error: "squad must contain exactly 3 units" });
  }
  const err = squadError("squad", squad);
  if (err) return res.status(400).json({ error: err });

  const trusted = resolveOwnSquad(req.playerId!, squad);
  if ("error" in trusted) return res.status(400).json({ error: trusted.error });
  const party = trusted.map(trustedToSim);

  // A fainted monster stays fainted (spec §4): it cannot be fielded in a run.
  const fainted = new Set(faintedIds(req.playerId!));
  const downed = party.filter((u) => fainted.has(u.id));
  if (downed.length) {
    return res.status(409).json({
      error: {
        code: "MONSTER_FAINTED",
        message: `Fainted monsters cannot fight until daily reset or a nutrition task revives them: ${downed.map((u) => u.name).join(", ")}`
      }
    });
  }

  const runSeed = randomBytes(8).toString("hex");
  const { floorsCleared, feed } = runDungeonFloors(party, runSeed);

  // Floors pay on clear; coins earned before the wipe are kept (spec §5).
  const coinsEarned = feed.reduce((sum, f) => sum + f.reward, 0);
  if (coinsEarned > 0) recordCoins(req.playerId!, coinsEarned, "dungeon", runSeed);

  const row = dungeonStateFor(req.playerId!);
  const bestFloor = Math.max(row.best_floor, floorsCleared);
  db.prepare(`UPDATE dungeon_state SET best_floor = ?, last_run_at = ? WHERE player_id = ?`)
    .run(bestFloor, new Date().toISOString(), req.playerId!);

  recordBattle(req.playerId!, "dungeon", floorsCleared > 0 ? "win" : "loss", {
    opponent: "dungeon",
    squad: party.map((u) => ({ id: u.id, name: u.name })),
    detail: { floorsCleared, bestFloor, coinsEarned, feed }
  });

  if (hasDatabaseUrl()) {
    enqueueMirror("gameplay_event", `dungeon:${req.playerId!}:${runSeed}`, {
      playerId: req.playerId!,
      type: "dungeon",
      detail: { floorsCleared, bestFloor, coinsEarned },
    });
    // Depth over time, for analytics.dungeon_daily. The run seed identifies
    // the run, so a retry collapses.
    enqueueMirror("dungeon_progress", `${runSeed}:${floorsCleared}`, {
      playerId: req.playerId!,
      runRef: String(runSeed),
      floor: floorsCleared,
      outcome: floorsCleared > 0 ? "cleared" : "failed",
    });
  }

  res.json({
    runSeed,
    floorsCleared,
    bestFloor,
    coinsEarned,
    coins: coinBalance(req.playerId!),
    feed
  });
});

// GET /battle/dungeon/state -- personal best + last run. No idle income.
battleRouter.get("/dungeon/state", (req: PlayerRequest, res) => {
  const row = dungeonStateFor(req.playerId!);
  res.json({ bestFloor: row.best_floor, lastRunAt: row.last_run_at });
});

// ===== Ranked matchmaking ===================================================
//
// SBMM (spec §5): candidates are other players' stored squad snapshots.
//   MatchScore = |ΔRR|/100 + TeamGap%   — lower is better; bot fallback when
// the queue is empty. The result moves RR via applyRankedResult; a win also
// rolls a rank-odds Case onto the player's pending-case pile.

/** Bot squad for a rank: roster units at a rank-appropriate rarity/star. */
const BOT_TIER: Record<RankId, { rarity: Rarity; star: number }> = {
  iron: { rarity: "common", star: 1 },
  bronze: { rarity: "uncommon", star: 2 },
  silver: { rarity: "rare", star: 2 },
  gold: { rarity: "rare", star: 3 },
  platinum: { rarity: "epic", star: 3 },
  diamond: { rarity: "legendary", star: 4 }
};

function botSquadForRank(rank: RankId): SimUnit[] {
  const { rarity, star } = BOT_TIER[rank];
  return ROSTER.slice(0, DUNGEON_TEAM_SIZE).map((r, i) =>
    toSim({
      id: `bot-${rank}-${i}`,
      name: r.name,
      rarity,
      star,
      characterKey: r.id
    })
  );
}

/** SBMM team power: Σ (EffectiveHealth + EffectiveAttack × AttackWeight). */
function teamPower(units: SimUnit[]): number {
  return units.reduce(
    (s, u) =>
      s +
      effectiveStat(u.baseHealth, u.rarity ?? "common", u.star ?? 1) +
      effectiveStat(u.baseAttack, u.rarity ?? "common", u.star ?? 1) * SBMM_ATTACK_WEIGHT,
    0
  );
}

interface RankedSetup {
  yourUnits: SimUnit[];
  yourTrusted: TrustedUnit[];
  opponentId: string | null;
  oppUnits: SimUnit[];
  opponentRR: number;
  isBot: boolean;
  bestScore: number;
  myRR: number;
  myRank: RankId;
}

/** Validate + resolve the caller's squad and matchmake an opponent (SBMM). */
function setupRanked(playerId: string, squad: unknown): RankedSetup | { status: number; body: object } {
  if (!Array.isArray(squad) || squad.length !== DUNGEON_TEAM_SIZE) {
    return { status: 400, body: { error: "squad must contain exactly 3 units" } };
  }
  const err = squadError("squad", squad);
  if (err) return { status: 400, body: { error: err } };

  const yourTrusted = resolveOwnSquad(playerId, squad);
  if ("error" in yourTrusted) return { status: 400, body: { error: yourTrusted.error } };
  const yourUnits = yourTrusted.map(trustedToSim);

  // Fainted monsters cannot be fielded (spec §4).
  const fainted = new Set(faintedIds(playerId));
  const downed = yourUnits.filter((u) => fainted.has(u.id));
  if (downed.length) {
    return {
      status: 409,
      body: {
        error: {
          code: "MONSTER_FAINTED",
          message: `Fainted monsters cannot fight until daily reset or a nutrition task revives them: ${downed.map((u) => u.name).join(", ")}`
        }
      }
    };
  }

  const profile = getOrCreate(playerId);
  const myRR = profile.rr ?? 0;
  const myRank = rankForRR(myRR);

  // SBMM: score every candidate snapshot on |ΔRR|/100 + TeamGap%; lowest
  // score wins. Snapshots resolve against the DEFENDER's collection, never
  // the stored client claims.
  const candidates = db
    .prepare(`SELECT player_id FROM friend_squad WHERE player_id != ? ORDER BY updated_at DESC LIMIT 50`)
    .all(playerId) as { player_id: string }[];
  const myPower = teamPower(yourUnits);
  let opponentId: string | null = null;
  let opponentUnits: SimUnit[] | null = null;
  let opponentRR = myRR;
  let bestScore = Infinity;
  for (const row of candidates) {
    const resolved = loadSquadSnapshot(row.player_id);
    if (!resolved) continue;
    const rr = getOrCreate(row.player_id).rr ?? 0;
    const score = matchScore(myRR, rr, myPower, teamPower(resolved));
    if (score < bestScore) {
      bestScore = score;
      opponentId = row.player_id;
      opponentUnits = resolved;
      opponentRR = rr;
    }
  }

  // Bot fallback: the queue stands even when empty. Bots are rated at the
  // player's RR so the adjustment is 0 — the floor fight of the rank.
  const isBot = opponentUnits === null;
  const oppUnits: SimUnit[] = opponentUnits ?? botSquadForRank(myRank);
  if (isBot) opponentRR = myRR;
  saveSquadSnapshot(playerId, yourTrusted);

  return { yourUnits, yourTrusted, opponentId, oppUnits, opponentRR, isBot, bestScore, myRR, myRank };
}

interface RankedResultShape {
  winner: string;
  rounds: number;
  events: object[];
  faintedA: string[];
}

/** Apply a resolved ranked result: RR, faints, case reward, history, mirror. */
function applyRankedOutcome(playerId: string, setup: RankedSetup, seed: string, result: RankedResultShape) {
  const youWon = result.winner === "A";

  // RR: win +20 / loss −15, adjusted by clamp(round(ΔRR/25), ±5).
  const ranked = applyRankedResult(setup.myRR, setup.opponentRR, youWon);
  const updated = applyRankedToProfile(playerId, ranked, youWon);
  markFainted(playerId, result.faintedA);

  // A ranked win rolls a Case off the player's rank table (spec §5); it
  // waits on pending_case until opened — losses pay RR only.
  let caseReward: { rarity: string } | null = null;
  if (youWon) {
    const v = roll(`ranked:${playerId}`, "case", 0, Number(BigInt(seed) & 0xffffffffn));
    const rarity = rollRankedCaseRarity(ranked.rankBefore, v);
    const pending = grantCase(playerId, rarity, `ranked:${ranked.rankBefore}`);
    caseReward = { rarity: pending.rarity };
  }

  recordBattle(playerId, "ranked", youWon ? "win" : "loss", {
    opponent: setup.isBot ? "bot" : setup.opponentId ?? "bot",
    rrDelta: ranked.delta,
    squad: setup.yourUnits.map((u) => ({ id: u.id, name: u.name })),
    detail: { rounds: result.rounds, events: result.events, matchScore: setup.isBot ? null : setup.bestScore, case: caseReward?.rarity ?? null }
  });
  if (!setup.isBot && setup.opponentId) {
    recordBattle(setup.opponentId, "ranked", youWon ? "loss" : "win", {
      opponent: playerId,
      squad: setup.oppUnits.map((u) => ({ id: u.id, name: u.name })),
      detail: { rounds: result.rounds, events: result.events, defended: true }
    });
  }

  // Mirror ranked PvP the same way friendly battles land — bots have no
  // defender row to attach, so only real pairings go to TigerData.
  if (hasDatabaseUrl() && !setup.isBot && setup.opponentId) {
    enqueueMirror("friend_battle", `ranked:${playerId}:${setup.opponentId}:${seed}`, {
      challengerId: playerId,
      defenderId: setup.opponentId,
      winnerSide: youWon ? 0 : 1,
      rounds: result.rounds,
      mode: "ranked",
      events: result.events as BattleEventIn[]
    });
  }

  return {
    rank: {
      rr: ranked.rr,
      delta: ranked.delta,
      rank: ranked.rankAfter,
      rankLabel: RANK_LABELS[ranked.rankAfter],
      promoted: ranked.promoted,
      record: {
        rankedWins: updated.rankedWins ?? 0,
        rankedLosses: updated.rankedLosses ?? 0
      }
    },
    caseReward
  };
}

// POST /battle/ranked { squad } -- matchmake via SBMM and fight. Exactly 3.
// Legacy auto-resolve: kept for older clients; new clients use begin/commit.
battleRouter.post("/ranked", rateLimitByPlayer({ windowMs: 60_000, max: 20, keyPrefix: "ranked", message: "Too many ranked battles. Try again later." }), (req: PlayerRequest, res) => {
  const { squad } = req.body as { squad?: SquadUnitIn[] };
  const setup = setupRanked(req.playerId!, squad);
  if ("status" in setup) return res.status(setup.status).json(setup.body);

  const seed = BigInt(`0x${randomBytes(8).toString("hex")}`);
  const result = simulate(setup.yourUnits, setup.oppUnits, seed);
  const outcome = applyRankedOutcome(req.playerId!, setup, seed.toString(), {
    winner: result.winner, rounds: result.rounds, events: result.events, faintedA: result.faintedA
  });

  res.json({
    ...result,
    ...outcome,
    opponent: setup.isBot ? { bot: true } : { bot: false, playerId: setup.opponentId },
    opponentSquad: setup.oppUnits.map((u) => ({ id: u.id, name: u.name, star: u.star, rarity: u.rarity, baseHealth: u.baseHealth, baseAttack: u.baseAttack, baseMana: u.baseMana })),
    movesets: setup.yourUnits.map((u) => ({ id: u.id, moves: u.moves ?? attacksFor(u.characterKey ?? u.id, u.rarity ?? "common") }))
  });
});

// POST /battle/ranked/begin { squad } — matchmake + park an interactive
// ranked match; the response carries the locked specs and the seed.
battleRouter.post("/ranked/begin", rateLimitByPlayer({ windowMs: 60_000, max: 20, keyPrefix: "ranked", message: "Too many ranked battles. Try again later." }), (req: PlayerRequest, res) => {
  const { squad } = req.body as { squad?: SquadUnitIn[] };
  const setup = setupRanked(req.playerId!, squad);
  if ("status" in setup) return res.status(setup.status).json(setup.body);

  const { matchId, seed } = parkMatch(req.playerId!, "ranked", setup.yourUnits, setup.oppUnits, {
    opponentId: setup.opponentId,
    isBot: setup.isBot,
    meta: { opponentRR: setup.opponentRR, bestScore: setup.bestScore, myRR: setup.myRR, myRank: setup.myRank }
  });
  res.json({
    matchId,
    seed,
    opponent: setup.isBot ? { bot: true } : { bot: false, playerId: setup.opponentId },
    yourSquad: setup.yourUnits.map(specDTO),
    opponentSquad: setup.oppUnits.map(specDTO)
  });
});

// POST /battle/ranked/commit { matchId, actions } — replay the player's
// script; the result is whatever the rules produce, never what was claimed.
battleRouter.post("/ranked/commit", rateLimitByPlayer({ windowMs: 60_000, max: 20, keyPrefix: "ranked", message: "Too many ranked battles. Try again later." }), (req: PlayerRequest, res) => {
  const parsed = battleCommitSchema.safeParse(req.body);
  if (!parsed.success) return res.status(400).json({ error: parsed.error.issues[0]?.message ?? "invalid body" });

  const row = takeMatch(req.playerId!, parsed.data.matchId, "ranked");
  if (!row) return res.status(410).json({ error: { code: "MATCH_GONE", message: "Match is unknown, already resolved, or expired." } });

  const replay = replayMatch(row, parsed.data.actions);
  if (!replay.ok) return res.status(400).json({ error: { code: "ILLEGAL_SCRIPT", message: replay.error } });
  const result = replay.result;

  const meta = row.meta ? (JSON.parse(row.meta) as { opponentRR: number; bestScore: number; myRR: number; myRank: RankId }) : null;
  const yourUnits = JSON.parse(row.own_squad) as SimUnit[];
  const oppUnits = JSON.parse(row.opp_squad) as SimUnit[];
  const setup: RankedSetup = {
    yourUnits,
    yourTrusted: [],
    opponentId: row.opponent_id,
    oppUnits,
    opponentRR: meta?.opponentRR ?? 0,
    isBot: row.is_bot === 1,
    bestScore: meta?.bestScore ?? 0,
    myRR: meta?.myRR ?? 0,
    myRank: meta?.myRank ?? "iron"
  };
  const outcome = applyRankedOutcome(req.playerId!, setup, row.seed, {
    winner: result.winner, rounds: result.turns, events: result.events, faintedA: result.faintedA
  });

  res.json({
    winner: result.winner,
    rounds: result.turns,
    events: result.events,
    hpLeftA: result.hpFractionsA,
    hpLeftB: result.hpFractionsB,
    faintedA: result.faintedA,
    faintedB: result.faintedB,
    ...outcome,
    opponent: setup.isBot ? { bot: true } : { bot: false, playerId: setup.opponentId },
    opponentSquad: oppUnits.map((u) => ({ id: u.id, name: u.name, star: u.star, rarity: u.rarity, baseHealth: u.baseHealth, baseAttack: u.baseAttack, baseMana: u.baseMana }))
  });
});
