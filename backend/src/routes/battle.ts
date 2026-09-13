import { Router } from "express";
import { createHash, randomBytes, randomUUID } from "crypto";
import { sampleCharacters } from "../data/sampleCharacters";
import { CHARACTERS, RARITY_ORDER, RARITY_TIERS } from "../data/lootTable";
import { BattleState, Character, Rarity, StatType } from "../types";
import { requirePlayerId, PlayerRequest } from "../middleware/player";
import { rateLimitByPlayer } from "../middleware/security";
import { awardXP, awardRankPoints, getOrCreate, saveProfile, fatigueBlock } from "./user";
import { isFatigued, fatigueUntil } from "../game/fatigue";
import { db } from "../db";
import { roll } from "../services/lootboxEngine";
import { stateFor } from "../services/lootboxState";
import { hasDatabaseUrl } from "../db/pg";
import { BattleEventIn } from "../db/repositories/battleRepo";
import { ATTACKS_BY_ID, attacksFor, AttackDef } from "../data/attacks";
import { fusionTierAsStar, starMult, rarityMult } from "../game/power";
import { asStarLevel } from "../game/rarityBands";
import { tierForPoints, RankTier, RANK_ORDER } from "../game/rankTiers";
import { RP_RANKED_WIN, RP_RANKED_LOSS } from "../game/rankPoints";
import { ROSTER, rosterCharacter } from "../data/roster";
import { MUTATION_ERRORS, refundArena, refundStaleArenaStakes, settleArena, stakeDrops } from "../services/characterMutations";
import { enqueueMirror } from "../services/mirrorQueue";

export const battleRouter = Router();
battleRouter.use(requirePlayerId);

// ===== Deterministic battle simulation =====
// Port of BattleKit BattleEngine (ios/Sources/BattleKit). Same squads + seed
// produce the same outcome on device and server. Server is authoritative.

const MAX_ROUNDS = 12;
const CRIT_CHANCE = 0.06;
const CRIT_MULTIPLIER = 1.6;
const MISS_CHANCE = 0.04;
const DEFENSE_CONSTANT = 90;

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

/** SplitMix64 — mirrors BattleKit SeededRNG. */
function makeRng(seed: bigint) {
  let state = seed;
  return () => {
    state = (state + 0x9e3779b97f4a7c15n) & 0xffffffffffffffffn;
    let z = state;
    z = ((z ^ (z >> 30n)) * 0xbf58476d1ce4e5b9n) & 0xffffffffffffffffn;
    z = ((z ^ (z >> 27n)) * 0x94d049bb133111ebn) & 0xffffffffffffffffn;
    const v = z ^ (z >> 31n);
    return Number(v >> 11n) / Number(1n << 53n);
  };
}

const ADVANTAGE: Record<StatType, StatType | null> = {
  protein: "fiber",
  fiber: "hydration",
  hydration: "protein",
  vitamin: null
};

function typeMod(attacker: StatType, defender: StatType): number {
  if (ADVANTAGE[attacker] === defender) return 1.25;
  if (ADVANTAGE[defender] === attacker) return 0.8;
  return 1.0;
}

export interface SimUnit {
  id: string;
  name: string;
  element: StatType;
  power: number;
  guard: number;
  vitality: number;
  tempo: number;
  /** 1...5 mastery stars — boosts the signature move power at >= 3. */
  star?: number;
  /** @deprecated legacy alias: 0..5, mapped to star via fusionTierAsStar. */
  fusionTier?: number;
  /** Resolved moveset for this instance (issue #107). */
  moves?: AttackDef[];
  rarity?: Rarity;
  /** Roster slug — drives attacksFor() when moves are not passed. */
  characterKey?: string;
}

// --- Moves (mirror BattleKit BattleMove) ---

interface SimMove {
  name: string;
  power: number;
  usesStat: "power" | "guard" | "vitality" | "tempo";
}

function basicMove(): SimMove {
  return { name: "Strike", power: 1.0, usesStat: "power" };
}

/// Signature move uses the character's dominant stat; ★3 boosts it.
/// Ties resolve to the first kind in power/guard/vitality/tempo order,
/// matching BattleStats.highest's `max(by: <)`.
function signatureMove(unit: SimUnit): SimMove {
  let highest: SimMove["usesStat"] = "power";
  let best = -Infinity;
  for (const [kind, value] of [["power", unit.power], ["guard", unit.guard], ["vitality", unit.vitality], ["tempo", unit.tempo]] as [SimMove["usesStat"], number][]) {
    if (value > best) {
      best = value;
      highest = kind;
    }
  }
  const star = unit.star ?? fusionTierAsStar(unit.fusionTier);
  return {
    name: `${unit.name} Special`,
    power: star >= 3 ? 1.45 * 1.25 : 1.45,
    usesStat: highest
  };
}

/**
 * The unit's usable moves (issue #107): its authored moveset filtered by
 * rarity, or null when the unit carries no authored data — in which case the
 * sim keeps the legacy basic/signature behaviour bit-for-bit (Swift parity).
 */
function movesFor(unit: SimUnit): AttackDef[] | null {
  if (unit.moves?.length) return unit.moves;
  if (unit.characterKey && unit.rarity) return attacksFor(unit.characterKey, unit.rarity);
  return null;
}

/** Seeded move pick: signature ~50%, special (when unlocked) ~15%, else strike. */
function pickMove(unit: SimUnit, rng: () => number): SimMove {
  const moves = movesFor(unit);
  const rollFor = rng();
  if (!moves) {
    // Un-authored unit: legacy 50/50, single draw — Swift parity depends on it.
    return rollFor < 0.5 ? signatureMove(unit) : basicMove();
  }
  const signature = moves.find((m) => m.kind === "signature");
  const specials = moves.filter((m) => m.kind === "special");
  let picked: AttackDef | undefined;
  if (specials.length && rollFor < 0.15) {
    picked = specials[Math.floor(rng() * specials.length)];
  } else if (signature && rollFor < 0.5) {
    picked = signature;
  } else {
    picked = moves.find((m) => m.kind === "basic") ?? signature;
  }
  if (!picked) return rollFor < 0.5 ? signatureMove(unit) : basicMove();
  const power =
    picked.kind === "signature" && (unit.star ?? 1) >= 3 ? picked.power * 1.25 : picked.power;
  return { name: picked.name, power, usesStat: picked.usesStat };
}

function statOf(unit: SimUnit, kind: SimMove["usesStat"]): number {
  return unit[kind];
}

/// Swift's `_insertionSort` — the stdlib uses insertion sort for small
/// arrays, and the comparator draws from the shared RNG, so the exact
/// comparison sequence (and therefore the draw sequence) must match.
/// Comparator: less(a, b) returns true when a comes first.
function swiftInsertionSort<T>(arr: T[], less: (a: T, b: T) => boolean): void {
  for (let start = 1; start < arr.length; start++) {
    if (less(arr[start], arr[start - 1])) {
      const elem = arr[start];
      arr[start] = arr[start - 1];
      let current = start;
      while (true) {
        if (current === 1) {
          arr[0] = elem;
          break;
        }
        if (!less(elem, arr[current - 2])) {
          arr[current - 1] = elem;
          break;
        }
        arr[current - 1] = arr[current - 2];
        current -= 1;
      }
    }
  }
}

export function simulate(
  squadA: SimUnit[],
  squadB: SimUnit[],
  seed: bigint,
  opts?: { carryHP?: number[] }
): { winner: string; rounds: number; events: object[]; hpLeftA: number[] } {
  const rng = makeRng(seed);
  const multA = 1.2;
  const multB = 1.0; // party multipliers from daily state (server-computed)

  // Squad bonus: +5% per distinct element beyond the first, cap +10%
  // (mirror BattleSquad.squadBonus).
  const squadBonus = (squad: SimUnit[]): number =>
    1.0 + 0.05 * Math.max(0, new Set(squad.map((u) => u.element)).size - 1);
  const bonusA = squadBonus(squadA);
  const bonusB = squadBonus(squadB);

  const maxHP = (u: SimUnit, mult: number): number => (55 + u.vitality * 1.1) * mult;
  const slots = [
    ...squadA.map((u, i) => ({
      unit: u,
      side: 0,
      // carryHP: fraction of maxHP this unit starts with (dungeon floors).
      hp: maxHP(u, multA) * bonusA * (opts?.carryHP?.[i] ?? 1),
      maxHP: maxHP(u, multA)
    })),
    ...squadB.map((u) => ({ unit: u, side: 1, hp: maxHP(u, multB) * bonusB, maxHP: maxHP(u, multB) }))
  ];

  const events: object[] = [{ event: "battleStart", seed: seed.toString() }];
  let round = 1;

  while (round <= MAX_ROUNDS) {
    events.push({ event: "roundStart", round });

    // Turn order: tempo with seeded jitter, exactly as BattleEngine does —
    // the comparator draws from the shared RNG twice per comparison, so the
    // sort implementation itself is part of the determinism contract.
    const order = slots
      .map((s, i) => ({ slot: s, index: i }))
      .filter((x) => x.slot.hp > 0);
    swiftInsertionSort(order, (a, b) => {
      const l = a.slot.unit.tempo + rng() * 0.5;
      const r = b.slot.unit.tempo + rng() * 0.5;
      return l === r ? a.index < b.index : l > r;
    });

    for (const { index: attackerIndex } of order) {
      const attacker = slots[attackerIndex];
      if (attacker.hp <= 0) continue;
      const defender = slots.find((s) => s.side !== attacker.side && s.hp > 0);
      if (!defender) continue;

      if (rng() < MISS_CHANCE) {
        events.push({ event: "miss", attacker: attacker.unit.id, defender: defender.unit.id });
        continue;
      }

      // Move comes from the unit's authored moveset when it has one.
      const move = pickMove(attacker.unit, rng);
      const atkStat = statOf(attacker.unit, move.usesStat);

      const mod = typeMod(attacker.unit.element, defender.unit.element);
      const crit = rng() < CRIT_CHANCE;
      const variance = 0.92 + rng() * 0.16;
      const partyMult = attacker.side === 0 ? multA : multB;
      const raw = move.power * atkStat * mod * (crit ? CRIT_MULTIPLIER : 1) * variance * partyMult;
      const mitigation = 1 - defender.unit.guard / (defender.unit.guard + DEFENSE_CONSTANT);
      const damage = Math.round(raw * mitigation);

      defender.hp = Math.max(0, defender.hp - damage);
      events.push({
        event: "attack",
        attacker: attacker.unit.id,
        defender: defender.unit.id,
        move: move.name,
        damage,
        crit,
        typeMod: mod
      });
      if (defender.hp <= 0) events.push({ event: "faint", unit: defender.unit.id });
    }

    events.push({ event: "roundEnd", round });

    const aAlive = slots.some((s) => s.side === 0 && s.hp > 0);
    const bAlive = slots.some((s) => s.side === 1 && s.hp > 0);
    if (!bAlive || !aAlive) {
      const winnerSide = !bAlive ? 0 : 1;
      const winner = winnerSide === 0 ? "A" : "B";
      events.push({ event: "victory", winner, rounds: round });
      return { winner, rounds: round, events, hpLeftA: sideAFractions(slots) };
    }
    round++;
  }

  // Timeout: higher remaining HP *share* wins (mirror BattleEngine.hpShare —
  // shares, not raw sums, so squad-size asymmetries don't skew the result).
  const hpShare = (side: number): number => {
    const own = slots.filter((s) => s.side === side);
    const current = own.reduce((sum, s) => sum + Math.max(0, s.hp), 0);
    const total = own.reduce((sum, s) => sum + s.maxHP, 0);
    return total > 0 ? current / total : 0;
  };
  const winnerSide = hpShare(0) >= hpShare(1) ? 0 : 1;
  const winner = winnerSide === 0 ? "A" : "B";
  events.push({ event: "victory", winner, rounds: round });
  return { winner, rounds: round, events, hpLeftA: sideAFractions(slots) };
}

/** Side-A end-of-battle HP as maxHP fractions, in squad order. */
function sideAFractions(slots: { unit: SimUnit; side: number; hp: number; maxHP: number }[]): number[] {
  return slots.filter((s) => s.side === 0).map((s) => Math.max(0, s.hp) / s.maxHP);
}

const VALID_TYPES: StatType[] = ["protein", "fiber", "vitamin", "hydration"];

type SquadUnitIn = { id?: unknown; name?: unknown; statType?: unknown; rarity?: unknown; star?: unknown; starLevel?: unknown; fusionTier?: unknown; characterKey?: unknown; power?: unknown; guard?: unknown; vitality?: unknown; tempo?: unknown };

/** Shared squad validation for /simulate and /async/challenge. */
function squadError(name: string, squad: SquadUnitIn[]): string | null {
  for (const [i, unit] of squad.entries()) {
    if (typeof unit?.id !== "string" || unit.id.length === 0 || unit.id.length > 64) {
      return `${name}[${i}].id must be a string of 1-64 characters`;
    }
    if (typeof unit?.name !== "string" || unit.name.length === 0 || unit.name.length > 64) {
      return `${name}[${i}].name must be a string of 1-64 characters`;
    }
    if (typeof unit?.statType !== "string" || !VALID_TYPES.includes(unit.statType as StatType)) {
      return `${name}[${i}].statType must be one of: ${VALID_TYPES.join(", ")}`;
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

// Rarity/star scaling — mirror FoodCharacter.stats (QA B-001). Star uses the
// #131 curve (STAR_STEP=10% per star over ★1); legacy fusionTier maps through
// fusionTierAsStar so old clients keep working.
function toSim(c: {
  id: string; name: string; statType: StatType;
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
  const m = rarityMult(rarity) * starMult(star);
  const unit: SimUnit = {
    id: c.id,
    name: c.name,
    element: c.statType,
    power: (c.power ?? 50) * m,
    guard: (c.guard ?? 50) * m,
    vitality: (c.vitality ?? 50) * m,
    tempo: (c.tempo ?? 50) * m,
    star,
    rarity
  };
  if (c.characterKey) {
    unit.characterKey = c.characterKey;
    unit.moves = attacksFor(c.characterKey, rarity);
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
  statType: StatType;
  rarity: Rarity;
  star: number;
  characterKey?: string;
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

/** Authored-moveset slug when this id exists in the roster (issue #107). */
function characterKeyFor(id: string): string | undefined {
  return rosterCharacter(id) ? id : undefined;
}

function trustedUnit(id: string, name: string, statType: StatType, rarity: Rarity, star: number): TrustedUnit {
  return { id, name, statType, rarity, star, characterKey: characterKeyFor(id) };
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
  if (starter) return trustedUnit(id, starter.name, starter.statType, starter.rarity, 1);
  const scanned = scannedCharacter(playerId, id);
  if (scanned) return trustedUnit(id, scanned.name, scanned.statType, scanned.rarity, 1);
  const catalogue = CHARACTERS[id];
  const star = catalogue ? ownedStarLevel(playerId, id) : 0;
  if (catalogue && star > 0) {
    return trustedUnit(id, catalogue.name, catalogue.statType, catalogue.rarity, star);
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
  const catalogue = CHARACTERS[id];
  if (catalogue) {
    return trustedUnit(id, catalogue.name, catalogue.statType, catalogue.rarity, Math.max(1, ownedStarLevel(ownerId, id)));
  }
  const starter = STARTER_BY_ID.get(id);
  if (starter) return trustedUnit(id, starter.name, starter.statType, starter.rarity, 1);
  const scanned = scannedCharacter(ownerId, id);
  if (scanned) return trustedUnit(id, scanned.name, scanned.statType, scanned.rarity, 1);
  return { id, name: unit.name as string, statType: unit.statType as StatType, rarity: "common", star: 1 };
}

/** Resolved unit -> SimUnit: flat base-50 stats scaled by server rarity and ★. */
function trustedToSim(u: TrustedUnit): SimUnit {
  const m = rarityMult(u.rarity) * starMult(u.star);
  const sim: SimUnit = {
    id: u.id,
    name: u.name,
    element: u.statType,
    power: 50 * m,
    guard: 50 * m,
    vitality: 50 * m,
    tempo: 50 * m,
    star: u.star,
    rarity: u.rarity
  };
  if (u.characterKey) {
    sim.characterKey = u.characterKey;
    sim.moves = attacksFor(u.characterKey, u.rarity);
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
      error: `Unit '${id}' is not in your collection — squads are built from starters, scanned characters, and monsters you own.`
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
    CHARACTERS[u.id] ? { ...u, star: Math.max(1, ownedStarLevel(ownerId, u.id)) } : u;

  if (parsed && typeof parsed === "object" && !Array.isArray(parsed)) {
    const units = (parsed as { units?: unknown }).units;
    if (!Array.isArray(units) || units.length < 1) return null;
    const trusted = units.filter(
      (u): u is TrustedUnit =>
        typeof (u as TrustedUnit)?.id === "string" &&
        typeof (u as TrustedUnit)?.name === "string" &&
        typeof (u as TrustedUnit)?.statType === "string" &&
        VALID_TYPES.includes((u as TrustedUnit).statType) &&
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

/** Mean of a resolved squad's four stats — the matchmaking power score. */
function simPower(units: SimUnit[]): number {
  if (!units.length) return 0;
  return units.reduce((s, u) => s + (u.power + u.guard + u.vitality + u.tempo) / 4, 0) / units.length;
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

  // No progression here: the caller names BOTH squads, so a win proves
  // nothing and must not mint XP or leaderboard wins — a deliberately weak
  // opponent is free to construct. /battle/ranked, /async and /arena are the
  // modes that pay, because the opponent there is server-controlled.

  res.json({
    ...result,
    // Snapshot now carries each unit's resolved moveset (issue #103).
    movesets: [...yourUnits, ...oppUnits].map((u) => ({
      id: u.id,
      moves: (movesFor(u) ?? []).map((m) => m.id)
    }))
  });
});

// ===== Async friend battles ================================================
//
// Challenge a friend's stored squad snapshot — they don't need to be online.
// The result is recorded and surfaces as a "you were challenged" notice the
// next time the defender polls. Challenger is side A, defender snapshot B.

// POST /battle/async/challenge { opponentId, yourSquad } -- resolve vs the
// defender's stored snapshot, record the outcome for their notices feed.
battleRouter.post("/async/challenge", rateLimitByPlayer({ windowMs: 60_000, max: 20, keyPrefix: "async", message: "Too many challenges. Try again later." }), (req: PlayerRequest, res) => {
  const { opponentId, yourSquad } = req.body as {
    opponentId?: string;
    yourSquad?: SquadUnitIn[];
  };
  if (typeof opponentId !== "string" || opponentId.length < 1 || opponentId.length > 64) {
    return res.status(400).json({ error: "opponentId must be a string of 1-64 characters" });
  }
  if (opponentId === req.playerId) {
    return res.status(400).json({ error: "You cannot challenge yourself." });
  }
  if (!Array.isArray(yourSquad) || yourSquad.length < 1 || yourSquad.length > 3) {
    return res.status(400).json({ error: "yourSquad must contain 1-3 units" });
  }
  const yourError = squadError("yourSquad", yourSquad);
  if (yourError) return res.status(400).json({ error: yourError });

  const oppUnits = loadSquadSnapshot(opponentId);
  if (!oppUnits) {
    return res.status(404).json({ error: { code: "NO_SNAPSHOT", message: "That player has no battle squad yet." } });
  }

  const yourTrusted = resolveOwnSquad(req.playerId!, yourSquad);
  if ("error" in yourTrusted) return res.status(400).json({ error: yourTrusted.error });
  saveSquadSnapshot(req.playerId!, yourTrusted);
  const yourUnits = yourTrusted.map(trustedToSim);

  const seed = BigInt(`0x${randomBytes(8).toString("hex")}`);
  const result = simulate(yourUnits, oppUnits, seed);

  const youWon = result.winner === "A";
  db.prepare(
    `INSERT INTO async_battle (challenger_id, defender_id, winner_side, rounds) VALUES (?, ?, ?, ?)`
  ).run(req.playerId!, opponentId, youWon ? 0 : 1, result.rounds);

  awardXP(req.playerId!, youWon ? 100 : 20, youWon ? "battle-win" : "battle-loss");
  const profile = getOrCreate(req.playerId!);
  profile.battlesWon = (profile.battlesWon ?? 0) + (youWon ? 1 : 0);
  profile.updatedAt = new Date().toISOString();
  saveProfile(req.playerId!, profile);

  // Best-effort mirror into TigerData: relational battle + event/metric hypertables.
  if (hasDatabaseUrl()) {
    // Keyed on the pairing plus the moment it resolved: a retried request
    // must not mirror the same fight twice, but a rematch is a new battle.
    enqueueMirror("friend_battle", `${req.playerId!}:${opponentId}:${seed}`, {
      challengerId: req.playerId!,
      defenderId: opponentId,
      winnerSide: youWon ? 0 : 1,
      rounds: result.rounds,
      events: result.events as BattleEventIn[],
    });
  }

  res.json({
    ...result,
    opponentId,
    opponentSquad: oppUnits.map((u) => ({ id: u.id, name: u.name, statType: u.element, star: u.star, rarity: u.rarity }))
  });
});

// GET /battle/async/notices -- battles where your stored squad was attacked.
// Marks them seen on read; the defeat banner is a one-time moment.
battleRouter.get("/async/notices", (req: PlayerRequest, res) => {
  const rows = db
    .prepare(
      `SELECT seq, challenger_id, winner_side, rounds, created_at
       FROM async_battle WHERE defender_id = ? AND seen_by_defender = 0
       ORDER BY seq DESC LIMIT 20`
    )
    .all(req.playerId!) as { seq: number; challenger_id: string; winner_side: number; rounds: number; created_at: string }[];

  const nameFor = (id: string) => (getOrCreate(id).displayName ?? id.slice(0, 12));
  db.prepare(`UPDATE async_battle SET seen_by_defender = 1 WHERE defender_id = ? AND seen_by_defender = 0`)
    .run(req.playerId!);

  res.json({
    notices: rows.map((r) => ({
      challengerId: r.challenger_id,
      challengerName: nameFor(r.challenger_id),
      defendedWin: r.winner_side === 1,
      rounds: r.rounds,
      at: r.created_at
    }))
  });
});

// ===== Infinite dungeon =====================================================
//
// Pick your top 5; they fight floor after floor of escalating squads until
// wiped. HP carries between floors (real per-unit fractions from simulate),
// every 5th floor is a boss. Depth becomes the idle-income rate: keys tick
// up while you're away, claimed when you come back.

export const DUNGEON_MAX_FLOOR = 50;
/** Keys per minute per best-floor cleared. Floor 10 ≈ 1 key / 24min. */
const DUNGEON_INCOME_RATE = 1 / 240;
const DUNGEON_INCOME_CAP_KEYS = 24;
const DUNGEON_INCOME_CAP_MS = 24 * 60 * 60 * 1000;

interface DungeonRow {
  best_floor: number;
  last_claim_at: string;
  last_run_at: string | null;
}

function dungeonStateFor(playerId: string): DungeonRow {
  let row = db
    .prepare(`SELECT best_floor, last_claim_at, last_run_at FROM dungeon_state WHERE player_id = ?`)
    .get(playerId) as DungeonRow | undefined;
  if (!row) {
    // ISO with Z — `datetime('now')` writes "YYYY-MM-DD HH:MM:SS" which
    // new Date() parses as LOCAL time, skewing the income clock by the
    // timezone offset.
    const now = new Date().toISOString();
    db.prepare(`INSERT INTO dungeon_state (player_id, best_floor, last_claim_at) VALUES (?, 0, ?)`).run(playerId, now);
    row = { best_floor: 0, last_claim_at: now, last_run_at: null };
  }
  return row;
}

/** Keys accrued since last claim, before the claim commits. */
function pendingDungeonKeys(row: DungeonRow): number {
  // last_claim_at may hold a timezone-naive UTC stamp written by an older
  // build — append Z so it parses as UTC, and never let elapsed go negative.
  const stamp = row.last_claim_at.includes("T") ? row.last_claim_at : row.last_claim_at.replace(" ", "T") + "Z";
  const elapsed = Math.max(0, Math.min(Date.now() - new Date(stamp).getTime(), DUNGEON_INCOME_CAP_MS));
  return Math.min(Math.floor(row.best_floor * (elapsed / 60_000) * DUNGEON_INCOME_RATE), DUNGEON_INCOME_CAP_KEYS);
}

/**
 * One floor's defending squad, deterministic from runSeed+floor.
 * Boss floors (every 5th) field epic-or-better units with a fat stat mult;
 * regular floors scale gradually and stay mostly low-tier early on.
 */
function dungeonFloor(floor: number, runSeed: string): { units: SimUnit[]; boss: boolean } {
  const boss = floor % 5 === 0;
  const count = boss ? 3 : floor < 4 ? 2 : 3;
  const statMult = 0.8 + floor * 0.08 + (boss ? 0.35 : 0);

  const band: Rarity[] = boss
    ? ["epic", "legendary", "mythic", "secret"]
    : floor < 10
      ? ["common", "common", "uncommon", "rare"]
      : floor < 20
        ? ["uncommon", "rare", "rare", "epic"]
        : ["rare", "epic", "epic", "legendary"];

  const units: SimUnit[] = [];
  for (let i = 0; i < count; i++) {
    const rarity = band[Math.floor(roll(runSeed, "floor", floor, i) * band.length)];
    const pool = Object.values(CHARACTERS).filter((c) => c.rarity === rarity);
    const fallback = Object.values(CHARACTERS);
    const c = (pool.length ? pool : fallback)[Math.floor(roll(runSeed, "unit", floor, i) * (pool.length ? pool.length : fallback.length))];
    units.push({
      id: `${c.id}-f${floor}`,
      name: c.name,
      element: c.statType,
      power: 45 * statMult,
      guard: 45 * statMult,
      vitality: 45 * statMult,
      tempo: 45 * statMult,
      star: boss ? 3 : 1
    });
  }
  return { units, boss };
}

/** One full run: floors until the party wipes. Deterministic given runSeed. */
export function runDungeonFloors(party: SimUnit[], runSeed: string) {
  const hp = party.map(() => 1);
  const feed: { floor: number; boss: boolean; won: boolean; rounds: number; enemies: string[] }[] = [];
  let floorsCleared = 0;

  for (let floor = 1; floor <= DUNGEON_MAX_FLOOR; floor++) {
    const aliveIdx = party.map((_, i) => i).filter((i) => hp[i] > 0.02);
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
    feed.push({ floor, boss, won, rounds: sim.rounds, enemies: enemies.map((e) => e.name) });
    if (won) floorsCleared = floor; else break;
  }
  return { floorsCleared, feed };
}

// POST /battle/dungeon/run { squad } -- auto-resolve floors until the party
// wipes. Server-side: the whole run is one deterministic chain off runSeed.
battleRouter.post("/dungeon/run", rateLimitByPlayer({ windowMs: 60_000, max: 10, keyPrefix: "dungeon", message: "Too many dungeon runs. Try again later." }), (req: PlayerRequest, res) => {
  const { squad } = req.body as { squad?: SquadUnitIn[] };
  if (!Array.isArray(squad) || squad.length < 1 || squad.length > 5) {
    return res.status(400).json({ error: "squad must contain 1-5 units" });
  }
  const err = squadError("squad", squad);
  if (err) return res.status(400).json({ error: err });

  const trusted = resolveOwnSquad(req.playerId!, squad);
  if ("error" in trusted) return res.status(400).json({ error: trusted.error });

  const runSeed = randomBytes(8).toString("hex");
  const { floorsCleared, feed } = runDungeonFloors(trusted.map(trustedToSim), runSeed);

  // Depth pays: 1 key per 3 floors cleared, plus a run XP award.
  const keysEarned = Math.floor(floorsCleared / 3);
  if (keysEarned > 0) stateFor(req.playerId!).grantKeys(keysEarned);
  awardXP(req.playerId!, 10 * floorsCleared, "dungeon-run");

  const row = dungeonStateFor(req.playerId!);
  const bestFloor = Math.max(row.best_floor, floorsCleared);
  db.prepare(`UPDATE dungeon_state SET best_floor = ?, last_run_at = ? WHERE player_id = ?`)
    .run(bestFloor, new Date().toISOString(), req.playerId!);

  if (hasDatabaseUrl()) {
    enqueueMirror("gameplay_event", `dungeon:${req.playerId!}:${runSeed}`, {
      playerId: req.playerId!,
      type: "dungeon",
      detail: { floorsCleared, bestFloor, keysEarned },
    });
    // Depth over time, for analytics.dungeon_daily. "How deep did this run
    // get" is a different question from "a run happened", and only this one
    // can be charted. The run seed identifies the run, so a retry collapses.
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
    keysEarned,
    keys: stateFor(req.playerId!).keys,
    pendingIdleKeys: pendingDungeonKeys({ ...row, best_floor: bestFloor }),
    feed
  });
});

// GET /battle/dungeon/state -- best floor + idle keys waiting.
battleRouter.get("/dungeon/state", (req: PlayerRequest, res) => {
  const row = dungeonStateFor(req.playerId!);
  res.json({
    bestFloor: row.best_floor,
    lastRunAt: row.last_run_at,
    pendingIdleKeys: pendingDungeonKeys(row),
    incomeNote: "Keys accrue at your best-floor rate while you're away, capped at 24."
  });
});

// POST /battle/dungeon/claim -- collect accrued idle keys.
battleRouter.post("/dungeon/claim", (req: PlayerRequest, res) => {
  const playerId = req.playerId!;
  // One transaction: the claim timestamp and the key grant commit together,
  // so a failed write can never double-pay or silently lose the accrued keys.
  const result = (() => {
    db.exec("BEGIN IMMEDIATE");
    try {
      const row = dungeonStateFor(playerId);
      const keys = pendingDungeonKeys(row);
      db.prepare(`UPDATE dungeon_state SET last_claim_at = ? WHERE player_id = ?`)
        .run(new Date().toISOString(), playerId);
      const balance = keys > 0 ? stateFor(playerId).grantKeys(keys) : stateFor(playerId).keys;
      db.exec("COMMIT");
      return { claimed: keys, keys: balance };
    } catch (err) {
      db.exec("ROLLBACK");
      throw err;
    }
  })();
  res.json(result);
});

// ===== Ranked matchmaking ===================================================
//
// Exact-tier queue (issue #85): look for another player's stored squad whose
// consistency rank_tier equals yours; if none, field a tier-appropriate bot.
// Result moves rank_points via awardRankPoints — never the Elo ladder, which
// stays reserved for competitive rating.

/** Bot squad for a tier: roster units at the tier's floor rarity, ★ = rank index. */
function botSquadForTier(tier: RankTier): SimUnit[] {
  const idx = RANK_ORDER.indexOf(tier);
  const rarity = (["common", "uncommon", "rare", "epic"] as Rarity[])[idx] ?? "epic";
  const pool = ROSTER.filter((r) => r.rarity === rarity);
  const picks = (pool.length >= 3 ? pool : ROSTER).slice(0, 3);
  return picks.map((r, i) =>
    toSim({
      id: `bot-${tier}-${i}`,
      name: r.name,
      statType: r.element,
      rarity: r.rarity,
      star: Math.min(5, idx + 1),
      characterKey: r.id,
      ...r.baseStats
    })
  );
}

// POST /battle/ranked { squad } -- matchmake at your exact rank tier and fight.
battleRouter.post("/ranked", rateLimitByPlayer({ windowMs: 60_000, max: 20, keyPrefix: "ranked", message: "Too many ranked battles. Try again later." }), (req: PlayerRequest, res) => {
  const { squad } = req.body as { squad?: SquadUnitIn[] };
  if (!Array.isArray(squad) || squad.length < 1 || squad.length > 3) {
    return res.status(400).json({ error: "squad must contain 1-3 units" });
  }
  const err = squadError("squad", squad);
  if (err) return res.status(400).json({ error: err });

  const yourTrusted = resolveOwnSquad(req.playerId!, squad);
  if ("error" in yourTrusted) return res.status(400).json({ error: yourTrusted.error });
  const yourUnits = yourTrusted.map(trustedToSim);

  const profile = getOrCreate(req.playerId!);
  const tier = tierForPoints(profile.rankPoints ?? 0);

  if (isFatigued(profile.squadFatigueUntil, Date.now())) {
    return res.status(409).json({
      error: {
        code: "SQUAD_FATIGUED",
        message: "Your squad is fatigued from a ranked loss. Claim a daily quest to recover early, or wait it out."
      },
      fatigue: fatigueBlock(profile)
    });
  }

  // Exact-tier matchmaking: squads are stored without tier, so pull candidate
  // snapshots and filter by the owner's current rank tier. Among the legal
  // candidates, pick the closest power score (#131) — the fairest fight the
  // queue can offer rather than the most recent snapshot. Snapshots resolve
  // against the DEFENDER's collection, never the stored client claims.
  const candidates = db
    .prepare(`SELECT player_id FROM friend_squad WHERE player_id != ? ORDER BY updated_at DESC LIMIT 50`)
    .all(req.playerId!) as { player_id: string }[];
  const myPower = simPower(yourUnits);
  let opponentId: string | null = null;
  let opponentUnits: SimUnit[] | null = null;
  let bestGap = Infinity;
  for (const row of candidates) {
    if (tierForPoints(getOrCreate(row.player_id).rankPoints ?? 0) !== tier) continue;
    const resolved = loadSquadSnapshot(row.player_id);
    if (!resolved) continue;
    const gap = Math.abs(simPower(resolved) - myPower);
    if (gap < bestGap) {
      bestGap = gap;
      opponentId = row.player_id;
      opponentUnits = resolved;
    }
  }

  const isBot = opponentUnits === null;
  const oppUnits: SimUnit[] = opponentUnits ?? botSquadForTier(tier);
  saveSquadSnapshot(req.playerId!, yourTrusted);

  const seed = BigInt(`0x${randomBytes(8).toString("hex")}`);
  const result = simulate(yourUnits, oppUnits, seed);
  const youWon = result.winner === "A";

  const rank = awardRankPoints(req.playerId!, youWon ? RP_RANKED_WIN : RP_RANKED_LOSS, "ranked");
  awardXP(req.playerId!, youWon ? 100 : 20, youWon ? "battle-win" : "battle-loss");

  // Re-fetch rather than reuse `profile`: awardRankPoints/awardXP already
  // persisted their own updates against the current row, and `profile` was
  // read before the battle, so saving it here would silently overwrite
  // those awards with the pre-battle values (as it previously did — this
  // object is only used for battlesWon + fatigue from here on).
  const updated = getOrCreate(req.playerId!);
  updated.battlesWon = (updated.battlesWon ?? 0) + (youWon ? 1 : 0);
  if (!youWon) {
    updated.squadFatigueUntil = fatigueUntil(Date.now());
  }
  updated.updatedAt = new Date().toISOString();
  saveProfile(req.playerId!, updated);

  res.json({
    ...result,
    tier,
    opponent: isBot ? { bot: true } : { bot: false, playerId: opponentId },
    opponentSquad: oppUnits.map((u) => ({ id: u.id, name: u.name, element: u.element, star: u.star, rarity: u.rarity })),
    movesets: yourUnits.map((u) => ({ id: u.id, moves: (movesFor(u) ?? []).map((m) => m.id) })),
    rank,
    fatigue: fatigueBlock(updated)
  });
});

// ===== Arena stakes (issue #116) ============================================
//
// Challenge a friend's snapshot with monsters on the line. The challenger's
// stake locks in escrow before the sim runs; settlement is one transaction —
// win and the stake comes back plus the coin equivalent (keys, minus the 5%
// arena burn), lose and the defender takes the monsters.

// POST /battle/arena/challenge { opponentId, yourSquad, stakeDropIds }
battleRouter.post("/arena/challenge", rateLimitByPlayer({ windowMs: 60_000, max: 10, keyPrefix: "arena", message: "Too many arena challenges. Try again later." }), (req: PlayerRequest, res) => {
  const { opponentId, yourSquad, stakeDropIds } = req.body as {
    opponentId?: string;
    yourSquad?: SquadUnitIn[];
    stakeDropIds?: string[];
  };
  if (typeof opponentId !== "string" || opponentId.length < 1 || opponentId.length > 64) {
    return res.status(400).json({ error: "opponentId must be a string of 1-64 characters" });
  }
  if (opponentId === req.playerId) {
    return res.status(400).json({ error: "You cannot stake a battle against yourself." });
  }
  if (!Array.isArray(yourSquad) || yourSquad.length < 1 || yourSquad.length > 3) {
    return res.status(400).json({ error: "yourSquad must contain 1-3 units" });
  }
  const yourError = squadError("yourSquad", yourSquad);
  if (yourError) return res.status(400).json({ error: yourError });
  if (!Array.isArray(stakeDropIds) || stakeDropIds.length < 1 || stakeDropIds.length > 3 || !stakeDropIds.every((id) => typeof id === "string")) {
    return res.status(400).json({ error: "stakeDropIds must be 1-3 owned monster ids" });
  }

  const oppUnits = loadSquadSnapshot(opponentId);
  if (!oppUnits) {
    return res.status(404).json({ error: { code: "NO_SNAPSHOT", message: "That player has no battle squad yet." } });
  }

  const yourTrusted = resolveOwnSquad(req.playerId!, yourSquad);
  if ("error" in yourTrusted) return res.status(400).json({ error: yourTrusted.error });

  // Self-heal escrows stranded by a crashed settlement: a stake can only
  // outlive its request if the process died mid-battle, so anything old is
  // refunded before a new challenge is priced.
  refundStaleArenaStakes(req.playerId!);

  const battleId = randomUUID();
  let staked;
  try {
    staked = stakeDrops(req.playerId!, stakeDropIds, battleId);
  } catch (err) {
    const code = err instanceof Error ? err.message : "INTERNAL";
    const status = code === MUTATION_ERRORS.NOT_OWNED || code === MUTATION_ERRORS.LOCKED ? 409 : 400;
    return res.status(status).json({
      error: { code, message: "Stake refused: every id must be a monster you own that is not already staked." }
    });
  }

  const seed = BigInt(`0x${randomBytes(8).toString("hex")}`);
  let result;
  try {
    result = simulate(yourTrusted.map(trustedToSim), oppUnits, seed);
  } catch (err) {
    // The sim failed after escrow locked: release the stake so a broken
    // fight can never strand monsters.
    refundArena(battleId);
    throw err;
  }
  const youWon = result.winner === "A";

  const settlement = youWon
    ? settleArena(battleId, req.playerId!, opponentId)
    : settleArena(battleId, opponentId, req.playerId!);

  db.prepare(
    `INSERT INTO async_battle (challenger_id, defender_id, winner_side, rounds) VALUES (?, ?, ?, ?)`
  ).run(req.playerId!, opponentId, youWon ? 0 : 1, result.rounds);

  awardXP(req.playerId!, youWon ? 150 : 20, youWon ? "arena-win" : "arena-loss");
  const profile = getOrCreate(req.playerId!);
  profile.battlesWon = (profile.battlesWon ?? 0) + (youWon ? 1 : 0);
  profile.updatedAt = new Date().toISOString();
  saveProfile(req.playerId!, profile);

  res.json({
    ...result,
    battleId,
    staked: staked.map((d) => ({ id: d.id, name: d.character.name, value: d.value })),
    settlement: youWon
      ? { outcome: "won", stakeReturned: true, coinsPaid: settlement.coinsPaid, monstersWon: settlement.transferred.map((d) => d.id) }
      : { outcome: "lost", transferredTo: opponentId, monsters: settlement.transferred.map((d) => d.id) }
  });
});

// GET /battle/:userId -- current battle state against a matchmade opponent.
battleRouter.get("/:userId", (_req, res) => {
  const state: BattleState = {
    yourSquad: sampleCharacters.slice(0, 3),
    opponentSquad: sampleCharacters.slice(3, 6),
    fatigued: false,
    turn: "you",
    moves: [
      { name: "Protein Punch", statType: "protein", description: "+12 ATK" },
      { name: "Fiber Whirl", statType: "fiber", description: "+8 DEF" },
      { name: "Vitamin Beam", statType: "vitamin", description: "Heal 10%" },
      { name: "Hydro Splash", statType: "hydration", description: "Cleanse debuffs" }
    ]
  };
  res.json({ state });
});
