// Deterministic 3v3 battle engine — the canonical implementation of
// final-dev-doc.pdf §4 over the Phase-0 contract (game/spec.ts,
// schemas/monster.ts). This file is the TypeScript port; the Swift mirror
// lives in ios/Sources/BattleKit/BattleEngine.swift. The two MUST produce
// identical event streams for identical squads + seed, because the server is
// authoritative and both clients replay the same events. Every RNG draw
// below is annotated with its position in the draw order — reordering a draw
// in one port without the other is a parity break.
//
// Model (spec §4):
//   * One active monster per side; a side's turn is one action: a standard
//     move, a Special Ability (Epic+, costs Mana), or a voluntary switch
//     (consumes the whole turn). A faint forces a free replacement.
//   * No tempo/initiative stat — turns strictly alternate. The first mover
//     is a seeded 50/50 coin flip for PvP, or caller-fixed for PvE (the
//     human always moves first).
//   * No elements/types, no global miss chance, no squad bonus, no level or
//     defense stat. Combat strength = base stats × rarity × star.
//
//   EffectiveStat   = Base × rarityMult × starCombatMult(star)
//   BaseDamage      = (MovePower × EffectiveAttack) / DAMAGE_SCALE + 2
//   FinalDamage     = floor(BaseDamage × crit × variance × modifiers)
//   variance        ~ U(0.85, 1.00)          crit: 1/24 chance, ×1.5
//   StartingMana    = floor(BaseMana × manaStarMult(star))   — Epic+ only
//
// A damaging move that hits never deals less than MIN_DAMAGE (checklist).
// Misses deal 0 and skip hit-dependent statuses.
//
// RNG DRAW ORDER (identical in both ports — this is the parity contract):
//   0. first-mover coin flip, once at construction, only for "coinFlip"
//   per action (move/special):
//   1. hit roll        unit() * 100 < effectiveAccuracy
//   2. crit roll       unit() < CRIT_CHANCE     (only if hit and power > 0)
//   3. variance roll   VARIANCE_MIN + span * unit()   (same conditions)
//   4. status roll     unit() * 100 < statusChance    (only if hit and the
//      move carries a statusEffect)
//   The auto policy additionally draws once per decision to pick an action,
//   and the turn-limit tiebreak draws once if count and HP share both tie.
//   Status ticks, forced replacements, mana deduction and healing draw
//   nothing — they are pure functions of state.

import { Rarity } from "../types";
import {
  CRIT_CHANCE,
  CRIT_MULT,
  VARIANCE_MIN,
  VARIANCE_MAX,
  MIN_DAMAGE,
  STAR_COMBAT_MULT,
  STAR_MANA_MULT,
  RARITY_COMBAT_MULT,
  hasMana,
  maxStarsFor
} from "../game/spec";

// ---------------------------------------------------------------------------
// Tunables
// ---------------------------------------------------------------------------

/**
 * Global damage balancing constant (spec §4: "DamageScale is a global
 * balancing constant to be tuned against the actual Health/Base Attack
 * ranges of the authored characters"). Sized for the landed catalog:
 * baseHealth ≈ 95-130, baseAttack ≈ 40-60, move power 0-10 → a power-3.5
 * hit on ~50 effective attack lands ≈ 24 damage, i.e. a ~4-5 turn faint.
 * Retune after playtesting, not before.
 */
export const DAMAGE_SCALE = 10;

/** Anti-stall: hard cap on total turns (one turn = one side's action). */
export const MAX_TURNS = 100;

/**
 * Status magnitudes — the catalog stores only effect id + duration, so the
 * numbers behind each id live here (interim until the catalog grows
 * per-move magnitude fields). Effects of the same id do not stack;
 * reapplying refreshes the duration.
 */
export const STATUS_PARAMS = {
  /** Damage per tick as a fraction of the TARGET's max HP. */
  burnFraction: 0.05,
  /** Effective-attack multiplier while atk_up is active. */
  attackUpMult: 1.25,
  /** Incoming-damage multiplier while guard_up is active. */
  guardUpMult: 0.7,
  /** Accuracy multiplier while acc_down is active. */
  accDownMult: 0.75,
  /** Instant self-heal as a fraction of the user's max HP. */
  healFraction: 0.15,
  /** Leech heals this fraction of damage dealt… */
  leechFraction: 0.5,
  /** …but never more than this fraction of max HP — two leech-spammers
   *  trading the same hit must still make progress toward a finish. */
  leechCapFraction: 0.25
} as const;

// ---------------------------------------------------------------------------
// Public input model — the squad snapshot
// ---------------------------------------------------------------------------

/** The authored status vocabulary (catalog `statusEffect` values). */
export type StatusEffectId =
  | "burn"      // DoT: burnFraction of max HP at the start of the target's turns
  | "acc_down"  // target accuracy × accDownMult while active
  | "atk_up"    // user's effective attack × attackUpMult while active
  | "guard_up"  // user takes × guardUpMult damage while active
  | "stun"      // target skips its actions while active
  | "heal"      // instant: user heals healFraction of max HP
  | "leech";    // instant: user heals leechFraction of damage dealt

/**
 * One authored move as the engine consumes it — schemas/monster.ts
 * moveSchema plus the resolved kind.
 */
export interface MoveSpec {
  id: string;
  name: string;
  /** "special" = Mana-based Special Ability; everything else is standard. */
  kind: "standard" | "special";
  /** 0-10 damage scale; 0 = pure status/utility move. */
  power: number;
  /** 1..100 — P(hit) = accuracy/100, modified by acc_down. */
  accuracy: number;
  /** Mana spent on use; >0 only on specials. */
  manaCost: number;
  statusEffect?: StatusEffectId;
  /** P(status | hit) in percent. */
  statusChance?: number;
  /** Timed-status duration in the affected side's turns. */
  duration?: number;
  description?: string;
}

/**
 * One locked monster entering a battle — the squad snapshot. Everything the
 * engine needs and nothing mutable: inventory changes after battle start
 * cannot reach in here (spec checklist: battle-start squad snapshot).
 */
export interface BattleUnitSpec {
  id: string;
  name: string;
  /** Pre-scaling base stats (spec: Health + Base Attack). */
  baseHealth: number;
  baseAttack: number;
  rarity: Rarity;
  /** 1..5; Secret is clamped to ★2 for combat scaling. */
  star: number;
  moves: MoveSpec[];
  /** Authored per character; only Epic+ ever has Mana. */
  baseMana?: number;
}

export type SideId = "A" | "B";
export type SideIndex = 0 | 1;

export type BattleAction =
  | { type: "move"; moveIndex: number }
  | { type: "switch"; unitIndex: number };

export interface BattleOptions {
  /** Who moves first. "coinFlip" draws once from the seeded RNG (PvP);
   *  "A"/"B" fix the first mover without a draw (PvE: human = A). */
  firstTurn?: "coinFlip" | SideId;
  maxTurns?: number;
  /** Fractions of effective HP each unit starts with (dungeon carry-over). */
  carryHPA?: number[];
  carryHPB?: number[];
  /** Side whose faint-replacements are NOT auto-picked: the driver must call
   *  chooseReplacement() for it (interactive play — the player picks their
   *  next monster). Draws nothing, so the event stream stays deterministic
   *  either way; only the chosen index differs. */
  manualReplacement?: SideIndex;
}

/**
 * One decision in a submitted action script — what the interactive client
 * tells the server it did. `move`/`switch` consume a turn; `choose` is the
 * free faint-replacement pick (manualReplacement side only).
 */
export type ScriptedAction =
  | { type: "move"; moveIndex: number }
  | { type: "switch"; unitIndex: number }
  | { type: "choose"; unitIndex: number };

export interface BattleResult {
  winner: SideId;
  turns: number;
  events: object[];
  /** End-of-battle HP as fractions of effective max HP, in squad order. */
  hpFractionsA: number[];
  hpFractionsB: number[];
  /** Unit ids that ended the battle at 0 HP — the faint-persistence list
   *  (daily-reset / nutrition-task recovery consumes this). */
  faintedA: string[];
  faintedB: string[];
  reason: "wipeout" | "turnLimit";
}

// ---------------------------------------------------------------------------
// RNG — SplitMix64, identical to ios/Sources/BattleKit/SeededRNG.swift.
// Seed 0 remaps to the golden constant exactly as the Swift port does.
// ---------------------------------------------------------------------------

export function makeRng(seed: bigint): () => number {
  let state = seed === 0n ? 0x9e3779b97f4a7c15n : seed;
  return () => {
    state = (state + 0x9e3779b97f4a7c15n) & 0xffffffffffffffffn;
    let z = state;
    z = ((z ^ (z >> 30n)) * 0xbf58476d1ce4e5b9n) & 0xffffffffffffffffn;
    z = ((z ^ (z >> 27n)) * 0x94d049bb133111ebn) & 0xffffffffffffffffn;
    const v = z ^ (z >> 31n);
    return Number(v >> 11n) / Number(1n << 53n);
  };
}

// ---------------------------------------------------------------------------
// Scaling helpers
// ---------------------------------------------------------------------------

/** The star level that participates in combat scaling (Secret caps at ★2). */
export function combatStar(rarity: Rarity, star: number): number {
  return Math.min(Math.max(Math.trunc(star) || 1, 1), maxStarsFor(rarity));
}

export function starCombatMult(rarity: Rarity, star: number): number {
  return STAR_COMBAT_MULT[combatStar(rarity, star)];
}

export function effectiveStat(base: number, rarity: Rarity, star: number): number {
  return base * RARITY_COMBAT_MULT[rarity] * starCombatMult(rarity, star);
}

export function startingMana(spec: BattleUnitSpec): number {
  if (!hasMana(spec.rarity) || !spec.baseMana) return 0;
  return Math.floor(spec.baseMana * STAR_MANA_MULT[combatStar(spec.rarity, spec.star)]);
}

// ---------------------------------------------------------------------------
// Internal runtime state
// ---------------------------------------------------------------------------

interface Slot {
  spec: BattleUnitSpec;
  maxHP: number;
  hp: number;
  mana: number;
  /** Timed statuses: effect id -> turns remaining (the afflicted side's
   *  turns). Instant effects (heal, leech) are never stored. */
  statuses: Partial<Record<StatusEffectId, number>>;
}

interface EngineState {
  sides: [Slot[], Slot[]];
  active: [number, number];
  turn: number;
  finished: boolean;
  winner: SideIndex | null;
  reason: "wipeout" | "turnLimit" | null;
}

/** The side whose turn `turn` (0-based) belongs to. */
function sideForTurn(first: SideIndex, turn: number): SideIndex {
  return ((first + turn) % 2) as SideIndex;
}

const sideName = (s: SideIndex): SideId => (s === 0 ? "A" : "B");

/** Timed statuses that expire on the afflicted side's turn start. */
const TIMED_STATUSES: StatusEffectId[] = ["burn", "acc_down", "atk_up", "guard_up", "stun"];

// ---------------------------------------------------------------------------
// The battle
// ---------------------------------------------------------------------------

/**
 * A single match: one active monster per side, alternating turns. Pure and
 * deterministic — no clock, no I/O. Drive it interactively via act() /
 * chooseReplacement(), or resolve the whole thing with runToCompletion()
 * plus a policy per side.
 */
export class Battle {
  private state: EngineState;
  private rng: () => number;
  private first: SideIndex;
  private maxTurns: number;
  private manualReplacement: SideIndex | null;
  readonly events: object[] = [];

  constructor(squadA: BattleUnitSpec[], squadB: BattleUnitSpec[], seed: bigint, opts?: BattleOptions) {
    this.rng = makeRng(seed);
    this.maxTurns = opts?.maxTurns ?? MAX_TURNS;
    this.manualReplacement = opts?.manualReplacement ?? null;

    // Draw 0 — the first-mover coin flip (PvP). PvE callers pass firstTurn
    // explicitly and no draw is consumed.
    const firstOpt = opts?.firstTurn ?? "coinFlip";
    this.first = firstOpt === "coinFlip" ? (this.rng() < 0.5 ? 0 : 1) : firstOpt === "A" ? 0 : 1;

    const build = (specs: BattleUnitSpec[], carry?: number[]): Slot[] =>
      specs.map((input, i) => {
        // Locked battle-start snapshot: copy the spec (and its move list) so
        // nothing the caller does to the inputs afterwards can reach in.
        const spec: BattleUnitSpec = { ...input, moves: input.moves.map((m) => ({ ...m })) };
        const maxHP = effectiveStat(spec.baseHealth, spec.rarity, spec.star);
        const fraction = carry?.[i] ?? 1;
        return {
          spec,
          maxHP,
          hp: Math.max(0, Math.min(maxHP, maxHP * fraction)),
          mana: startingMana(spec),
          statuses: {}
        };
      });

    this.state = {
      sides: [build(squadA, opts?.carryHPA), build(squadB, opts?.carryHPB)],
      active: [0, 0],
      turn: 0,
      finished: false,
      winner: null,
      reason: null
    };

    this.events.push({ event: "battleStart", seed: seed.toString(), first: sideName(this.first) });
  }

  // ----- inspection --------------------------------------------------------

  /** One RNG draw — exposed for action policies so their picks participate
   *  in the same deterministic stream as the engine's own draws. */
  draw(): number {
    return this.rng();
  }

  get turn(): number {
    return this.state.turn;
  }

  get finished(): boolean {
    return this.state.finished;
  }

  get winner(): SideId | null {
    return this.state.winner === null ? null : sideName(this.state.winner);
  }

  /** The side expected to act next (null once finished). */
  get currentSide(): SideId | null {
    if (this.state.finished) return null;
    return sideName(sideForTurn(this.first, this.state.turn));
  }

  /** Active unit index for a side. */
  activeIndex(side: SideIndex): number {
    return this.state.active[side];
  }

  /** Read-only view of one unit's live state — for UI and tests. */
  unitState(side: SideIndex, index: number) {
    const slot = this.state.sides[side][index];
    return {
      id: slot.spec.id,
      hp: slot.hp,
      maxHP: slot.maxHP,
      mana: slot.mana,
      fainted: slot.hp <= 0,
      stunned: (slot.statuses.stun ?? 0) > 0,
      statuses: { ...slot.statuses }
    };
  }

  /** Every unit's live state for a side. */
  sideState(side: SideIndex) {
    return this.state.sides[side].map((_, i) => this.unitState(side, i));
  }

  /** Actions the side's active unit may legally take right now. */
  legalActions(side: SideIndex): BattleAction[] {
    const slot = this.activeSlot(side);
    if (!slot || slot.hp <= 0) return [];
    const actions: BattleAction[] = [];
    for (let i = 0; i < slot.spec.moves.length; i++) {
      const move = slot.spec.moves[i];
      if (move.kind === "special" && (!hasMana(slot.spec.rarity) || slot.mana < move.manaCost)) {
        continue;
      }
      actions.push({ type: "move", moveIndex: i });
    }
    for (let i = 0; i < this.state.sides[side].length; i++) {
      if (i !== this.state.active[side] && this.state.sides[side][i].hp > 0) {
        actions.push({ type: "switch", unitIndex: i });
      }
    }
    return actions;
  }

  private activeSlot(side: SideIndex): Slot | null {
    const squad = this.state.sides[side];
    return squad[this.state.active[side]] ?? null;
  }

  /** Whether the side's active slot is fainted and needs a (free) replacement. */
  needsReplacement(side: SideIndex): boolean {
    const slot = this.activeSlot(side);
    return !!slot && slot.hp <= 0 && this.state.sides[side].some((s) => s.hp > 0);
  }

  // ----- forced replacement -------------------------------------------------
  //
  // When the active monster faints its owner picks a new active immediately.
  // This does NOT consume the side's next turn (spec §4, Switching).

  chooseReplacement(side: SideIndex, unitIndex: number): void {
    const squad = this.state.sides[side];
    const target = squad[unitIndex];
    if (!target || target.hp <= 0 || unitIndex === this.state.active[side]) return;
    const out = this.activeSlot(side);
    this.state.active[side] = unitIndex;
    this.events.push({
      event: "switch",
      side: sideName(side),
      out: out?.spec.id,
      in: target.spec.id,
      forced: true
    });
  }

  private autoReplace(side: SideIndex): void {
    const squad = this.state.sides[side];
    const idx = squad.findIndex((s) => s.hp > 0);
    if (idx >= 0 && idx !== this.state.active[side]) this.chooseReplacement(side, idx);
  }

  // ----- one turn ------------------------------------------------------------

  /**
   * Apply one side's action. Advances the turn counter and appends the
   * event-log entries for everything the action caused.
   */
  act(side: SideIndex, action: BattleAction): void {
    if (this.state.finished) return;
    if (sideForTurn(this.first, this.state.turn) !== side) return;
    if (this.needsReplacement(side)) {
      // A manual-replacement side picks its own next monster — the driver
      // must chooseReplacement() before acting again. No turn consumed.
      if (side === this.manualReplacement) return;
      this.autoReplace(side);
    }

    const turn = ++this.state.turn;
    const slot = this.activeSlot(side);
    if (!slot || slot.hp <= 0) return;

    this.events.push({ event: "turnStart", turn, side: sideName(side), unit: slot.spec.id });

    // Status ticks happen at the start of the acting unit's turn, before it
    // can act — burn included even while stunned. They draw nothing — pure
    // functions of state.
    if ((slot.statuses.burn ?? 0) > 0 && slot.hp > 0) {
      const burnDamage = slot.maxHP * STATUS_PARAMS.burnFraction;
      slot.hp = Math.max(0, slot.hp - burnDamage);
      this.events.push({ event: "statusTick", unit: slot.spec.id, kind: "burn", damage: burnDamage });
    }
    for (const kind of TIMED_STATUSES) {
      if (kind === "stun") continue;
      const left = slot.statuses[kind];
      if (left !== undefined) {
        if (left - 1 <= 0) delete slot.statuses[kind];
        else slot.statuses[kind] = left - 1;
      }
    }
    if (slot.hp <= 0) {
      // Burned out on its own turn start: the side loses this action but the
      // replacement is still free.
      this.events.push({ event: "faint", unit: slot.spec.id });
      if (side !== this.manualReplacement) this.autoReplace(side);
      this.finishTurn(turn);
      return;
    }

    if ((slot.statuses.stun ?? 0) > 0) {
      // Stun eats the action and only then spends one turn of its duration —
      // decrement here, not in the timed-status pass above, or a 1-turn stun
      // would evaporate before it could bite.
      if (slot.statuses.stun! - 1 <= 0) delete slot.statuses.stun;
      else slot.statuses.stun = slot.statuses.stun! - 1;
      this.events.push({ event: "stunned", unit: slot.spec.id });
      this.finishTurn(turn);
      return;
    }

    const legal = this.legalActions(side);
    const applied = legal.some((a) => sameAction(a, action)) ? action : legal[0];
    if (!applied) {
      this.finishTurn(turn);
      return;
    }

    if (applied.type === "switch") {
      const out = slot;
      this.state.active[side] = applied.unitIndex;
      this.events.push({
        event: "switch",
        side: sideName(side),
        out: out.spec.id,
        in: this.state.sides[side][applied.unitIndex].spec.id,
        forced: false
      });
      this.finishTurn(turn);
      return;
    }

    const move = slot.spec.moves[applied.moveIndex];
    if (!move) {
      this.finishTurn(turn);
      return;
    }
    if (move.kind === "special") {
      // Mana is spent on use — hit or miss (spec: Specials consume their
      // authored ManaCost).
      slot.mana = Math.max(0, slot.mana - move.manaCost);
    }

    const defender = this.activeSlot((1 - side) as SideIndex);
    if (!defender || defender.hp <= 0) {
      this.finishTurn(turn);
      return;
    }

    // Draw 1 — accuracy. acc_down scales the move's authored accuracy.
    const accuracy = move.accuracy * ((slot.statuses.acc_down ?? 0) > 0 ? STATUS_PARAMS.accDownMult : 1);
    const hit = this.rng() * 100 < accuracy;
    if (!hit) {
      this.events.push({
        event: "miss",
        attacker: slot.spec.id,
        defender: defender.spec.id,
        move: move.name,
        moveId: move.id
      });
      this.finishTurn(turn);
      return;
    }

    let damage = 0;
    let crit = false;
    if (move.power > 0) {
      // Draw 2 — crit. Draw 3 — variance.
      crit = this.rng() < CRIT_CHANCE;
      const variance = VARIANCE_MIN + (VARIANCE_MAX - VARIANCE_MIN) * this.rng();
      const effAtk =
        effectiveStat(slot.spec.baseAttack, slot.spec.rarity, slot.spec.star) *
        ((slot.statuses.atk_up ?? 0) > 0 ? STATUS_PARAMS.attackUpMult : 1);
      const guardMult = (defender.statuses.guard_up ?? 0) > 0 ? STATUS_PARAMS.guardUpMult : 1;
      const base = (move.power * effAtk) / DAMAGE_SCALE + 2;
      // Minimum-damage rule: a successful hit can never round below 1.
      damage = Math.max(
        MIN_DAMAGE,
        Math.floor(base * (crit ? CRIT_MULT : 1) * variance * guardMult)
      );
      defender.hp = Math.max(0, defender.hp - damage);
    }

    this.events.push({
      event: "attack",
      attacker: slot.spec.id,
      defender: defender.spec.id,
      move: move.name,
      moveId: move.id,
      damage,
      crit,
      // The type system is gone; the field stays at 1.0 so older replay
      // consumers keep their shape.
      typeMod: 1
    });

    // Draw 4 — secondary status, only on a hit (P = P(hit) × P(status|hit)).
    if (move.statusEffect && this.rng() * 100 < (move.statusChance ?? 100)) {
      this.applyEffect(move.statusEffect, move.duration, slot, defender, damage);
    }

    if (defender.hp <= 0) {
      this.events.push({ event: "faint", unit: defender.spec.id });
      const defSide = (1 - side) as SideIndex;
      if (defSide !== this.manualReplacement) this.autoReplace(defSide);
    }

    this.finishTurn(turn);
  }

  private applyEffect(
    effect: StatusEffectId,
    duration: number | undefined,
    attacker: Slot,
    defender: Slot,
    damageDealt: number
  ): void {
    switch (effect) {
      case "heal": {
        const amount = attacker.maxHP * STATUS_PARAMS.healFraction;
        attacker.hp = Math.min(attacker.maxHP, attacker.hp + amount);
        this.events.push({ event: "heal", unit: attacker.spec.id, amount });
        return;
      }
      case "leech": {
        const amount = Math.min(
          damageDealt * STATUS_PARAMS.leechFraction,
          attacker.maxHP * STATUS_PARAMS.leechCapFraction
        );
        attacker.hp = Math.min(attacker.maxHP, attacker.hp + amount);
        this.events.push({ event: "heal", unit: attacker.spec.id, amount, kind: "leech" });
        return;
      }
      case "atk_up":
      case "guard_up":
        // Self-buffs: the duration counts down on the USER's turns.
        attacker.statuses[effect] = duration ?? 2;
        this.events.push({ event: "status", unit: attacker.spec.id, kind: effect });
        return;
      default:
        // burn / acc_down / stun land on the defender.
        defender.statuses[effect] = duration ?? 1;
        this.events.push({ event: "status", unit: defender.spec.id, kind: effect, source: attacker.spec.id });
    }
  }

  private finishTurn(turn: number): void {
    this.events.push({ event: "turnEnd", turn });
    const aAlive = this.state.sides[0].some((s) => s.hp > 0);
    const bAlive = this.state.sides[1].some((s) => s.hp > 0);
    if (!aAlive || !bAlive) {
      this.state.winner = aAlive ? 0 : 1;
      this.state.finished = true;
      this.state.reason = "wipeout";
      this.events.push({ event: "victory", winner: sideName(this.state.winner), turns: turn, reason: "wipeout" });
    }
  }

  // ----- turn-limit resolution (anti-stall) ----------------------------------
  //
  // Deterministic: remaining non-fainted monsters first, then total HP
  // percentage, then — only if both tie — one seeded draw. The per-turn
  // player timer is enforced at the endpoint layer (the engine is pure).

  private resolveTurnLimit(): void {
    const alive = (side: SideIndex) => this.state.sides[side].filter((s) => s.hp > 0).length;
    const share = (side: SideIndex) => {
      const squad = this.state.sides[side];
      const hp = squad.reduce((sum, s) => sum + Math.max(0, s.hp), 0);
      const max = squad.reduce((sum, s) => sum + s.maxHP, 0);
      return max > 0 ? hp / max : 0;
    };
    const countA = alive(0);
    const countB = alive(1);
    let winner: SideIndex;
    if (countA !== countB) {
      winner = countA > countB ? 0 : 1;
    } else {
      const shareA = share(0);
      const shareB = share(1);
      // Tiebreak draw — the only post-flip draw outside action resolution.
      winner = shareA !== shareB ? (shareA > shareB ? 0 : 1) : this.rng() < 0.5 ? 0 : 1;
    }
    this.state.winner = winner;
    this.state.finished = true;
    this.state.reason = "turnLimit";
    this.events.push({
      event: "victory",
      winner: sideName(winner),
      turns: this.state.turn,
      reason: "turnLimit"
    });
  }

  // ----- whole-match driver ---------------------------------------------------

  /**
   * A policy answers "what does this side do?" for interactive drivers. The
   * default policy picks uniformly among legal move/special actions (one RNG
   * draw) and never switches voluntarily — deterministic given the seed.
   */
  runToCompletion(
    policyA?: (battle: Battle, side: SideIndex) => BattleAction,
    policyB?: (battle: Battle, side: SideIndex) => BattleAction
  ): BattleResult {
    const policies: ((b: Battle, s: SideIndex) => BattleAction)[] = [
      policyA ?? Battle.defaultPolicy,
      policyB ?? Battle.defaultPolicy
    ];

    while (!this.state.finished && this.state.turn < this.maxTurns) {
      const side = sideForTurn(this.first, this.state.turn);
      this.act(side, policies[side](this, side));
    }
    if (!this.state.finished) this.resolveTurnLimit();
    return this.resultSnapshot();
  }

  /** The shared default policy: uniform pick among legal move/special
   *  actions (one RNG draw); never switches voluntarily. */
  static defaultPolicy(battle: Battle, side: SideIndex): BattleAction {
    const usable = battle
      .legalActions(side)
      .filter((a): a is { type: "move"; moveIndex: number } => a.type === "move");
    const pick = usable[Math.floor(battle.draw() * usable.length)] ?? usable[0];
    return pick ?? { type: "move", moveIndex: 0 };
  }

  /**
   * Server-authoritative interactive replay: side A's decisions come from
   * the submitted script, side B runs the default policy. Every scripted
   * action is validated against the legal set — an illegal or missing entry
   * rejects the script rather than silently substituting, because a fall-
   * back would diverge from what the player's client displayed.
   *
   * Deterministic: same squads + seed + script → same result, and the
   * returned event stream is exactly what an honest client saw locally.
   */
  runScripted(scriptA: ScriptedAction[]): { ok: true; result: BattleResult } | { ok: false; error: string } {
    let cursor = 0;
    while (!this.state.finished && this.state.turn < this.maxTurns) {
      // A fainted active on the manual side is replaced by a script `choose`
      // entry — free, draws nothing, consumes no turn.
      if (this.needsReplacement(0)) {
        const entry = scriptA[cursor++];
        if (!entry || entry.type !== "choose") {
          return { ok: false, error: `script[${cursor - 1}]: expected a replacement choice` };
        }
        const squad = this.state.sides[0];
        if (!squad[entry.unitIndex] || squad[entry.unitIndex].hp <= 0 || entry.unitIndex === this.state.active[0]) {
          return { ok: false, error: `script[${cursor - 1}]: illegal replacement ${entry.unitIndex}` };
        }
        this.chooseReplacement(0, entry.unitIndex);
        continue;
      }

      const side = sideForTurn(this.first, this.state.turn);
      if (side === 0) {
        const entry = scriptA[cursor++];
        if (!entry || entry.type === "choose") {
          return { ok: false, error: `script[${cursor - 1}]: expected a move or switch` };
        }
        const action: BattleAction =
          entry.type === "move"
            ? { type: "move", moveIndex: entry.moveIndex }
            : { type: "switch", unitIndex: entry.unitIndex };
        if (!this.legalActions(0).some((l) => sameAction(l, action))) {
          return { ok: false, error: `script[${cursor - 1}]: illegal action` };
        }
        this.act(0, action);
      } else {
        this.act(1, Battle.defaultPolicy(this, 1));
      }
    }
    if (cursor < scriptA.length) {
      return { ok: false, error: "script has trailing actions after the battle ended" };
    }
    if (!this.state.finished) this.resolveTurnLimit();
    return { ok: true, result: this.resultSnapshot() };
  }

  private resultSnapshot(): BattleResult {
    const fractions = (side: SideIndex) =>
      this.state.sides[side].map((s) => Math.max(0, s.hp) / s.maxHP);
    const fainted = (side: SideIndex) =>
      this.state.sides[side].filter((s) => s.hp <= 0).map((s) => s.spec.id);

    return {
      winner: sideName(this.state.winner ?? 0),
      turns: this.state.turn,
      events: this.events,
      hpFractionsA: fractions(0),
      hpFractionsB: fractions(1),
      faintedA: fainted(0),
      faintedB: fainted(1),
      reason: this.state.reason ?? "turnLimit"
    };
  }
}

function sameAction(a: BattleAction, b: BattleAction): boolean {
  if (a.type !== b.type) return false;
  if (a.type === "move" && b.type === "move") return a.moveIndex === b.moveIndex;
  if (a.type === "switch" && b.type === "switch") return a.unitIndex === b.unitIndex;
  return false;
}

/**
 * One-shot convenience for the endpoints: build a Battle, auto-run both
 * sides, hand back the result. Same squads + same seed → same result on
 * device and server.
 */
export function simulateBattle(
  squadA: BattleUnitSpec[],
  squadB: BattleUnitSpec[],
  seed: bigint,
  opts?: BattleOptions
): BattleResult {
  return new Battle(squadA, squadB, seed, opts).runToCompletion();
}
