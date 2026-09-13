import Foundation

/// Deterministic 3v3 battle engine — the Swift port of
/// backend/src/services/battleEngine.ts (final-dev-doc §4).
///
/// Pure: identical squads + seed produce an identical event stream on every
/// device and on the server. No I/O, no clock, no system randomness. The two
/// ports MUST stay draw-for-draw identical — the server is authoritative and
/// clients replay the same events.
///
/// Model: one active monster per side, strictly alternating turns; a turn is
/// one action — a standard move, a Mana Special (Epic+), or a voluntary
/// switch (the whole turn). A faint forces a free replacement. No tempo
/// ordering, no types, no global miss chance, no squad bonus.
///
///   EffectiveStat = Base × rarityMult × starCombatMult(star)
///   BaseDamage    = (MovePower × EffectiveAttack) / damageScale + 2
///   FinalDamage   = floor(BaseDamage × crit × U(0.85,1.00) × modifiers)
///   StartingMana  = floor(BaseMana × manaStarMult(star))   — Epic+ only
///
/// RNG DRAW ORDER (identical in both ports — the parity contract):
///   0. first-mover coin flip, once at init, only for .coinFlip
///   per action (move/special):
///   1. hit roll      unit() * 100 < effectiveAccuracy
///   2. crit roll     unit() < critChance          (only if hit and power > 0)
///   3. variance roll 0.85 + 0.15 * unit()         (same conditions)
///   4. status roll   unit() * 100 < statusChance  (only if hit and the move
///      carries a statusEffect)
///   The auto policy additionally draws once per decision, and the
///   turn-limit tiebreak draws once if count and HP share both tie.
public final class Battle {

    // MARK: - Tunables (mirror battleEngine.ts)

    /// Spec §4 DamageScale — sized for the catalog's stat envelope; retune
    /// after playtesting. MUST equal DAMAGE_SCALE in the TS port.
    public static let damageScale = 10.0
    /// Anti-stall cap on total side-turns.
    public static let maxTurns = 100

    /// Status magnitudes — mirror STATUS_PARAMS in the TS port. The catalog
    /// stores only effect id + duration; the numbers live here.
    public enum StatusParams {
        public static let burnFraction = 0.05
        public static let attackUpMult = 1.25
        public static let guardUpMult = 0.7
        public static let accDownMult = 0.75
        public static let healFraction = 0.15
        public static let leechFraction = 0.5
    }

    // MARK: - Input / options

    public enum FirstTurn: Sendable {
        /// PvP: one seeded draw decides the opener.
        case coinFlip
        /// PvE: fixed opener — the human (side A) always moves first.
        case side(Int)
    }

    public struct Options: Sendable {
        public var firstTurn: FirstTurn
        public var maxTurns: Int
        /// Fractions of effective HP each unit starts with (dungeon carry-over).
        public var carryHP: [[Double]?]
        public init(firstTurn: FirstTurn = .coinFlip, maxTurns: Int = Battle.maxTurns, carryHP: [[Double]?] = [nil, nil]) {
            self.firstTurn = firstTurn
            self.maxTurns = maxTurns
            self.carryHP = carryHP
        }
    }

    // MARK: - Mutable battle state

    private struct Slot {
        var spec: BattleUnitSpec
        var maxHP: Double
        var hp: Double
        var mana: Int
        /// Timed statuses: effect -> turns remaining on the afflicted side's
        /// turns. Instant effects (heal, leech) are never stored.
        var statuses: [StatusEffectID: Int]
    }

    private var sides: [[Slot]]
    private var active: [Int]
    private var turn = 0
    private var finished = false
    private var winnerSide: Int?
    private var reason: VictoryReason?
    private var rng: SeededRNG
    private let first: Int
    private let maxTurns: Int

    /// Timed statuses that expire on the afflicted side's turn start —
    /// same iteration order as TIMED_STATUSES in the TS port.
    private static let timedStatuses: [StatusEffectID] = [.burn, .accDown, .atkUp, .guardUp, .stun]

    public private(set) var events: [BattleEvent] = []

    public init(squadA: [BattleUnitSpec], squadB: [BattleUnitSpec], seed: UInt64, options: Options = Options()) {
        rng = SeededRNG(seed: seed)
        maxTurns = options.maxTurns

        // Draw 0 — the first-mover coin flip (PvP). PvE callers pass .side
        // and no draw is consumed.
        switch options.firstTurn {
        case .coinFlip:
            first = rng.unit() < NQSpec.pvpFirstTurnP ? 0 : 1
        case .side(let s):
            first = s == 0 ? 0 : 1
        }

        func build(_ specs: [BattleUnitSpec], carry: [Double]?) -> [Slot] {
            specs.enumerated().map { i, input in
                // Locked snapshot — specs are value types, so the copy the
                // caller handed in is already isolated.
                let maxHP = NQSpec.effectiveStat(input.baseHealth, rarity: input.rarity, stars: input.star)
                let fraction = carry?[i] ?? 1
                return Slot(
                    spec: input,
                    maxHP: maxHP,
                    hp: max(0, min(maxHP, maxHP * fraction)),
                    mana: input.startingMana,
                    statuses: [:]
                )
            }
        }

        sides = [build(squadA, carry: options.carryHP[0]), build(squadB, carry: options.carryHP[1])]
        active = [0, 0]
        events.append(.battleStart(seed: String(seed), first: first))
    }

    // MARK: - Inspection

    /// One RNG draw — policies use this so their picks join the same
    /// deterministic stream as the engine's own draws.
    public func draw() -> Double { rng.unit() }

    public var currentTurn: Int { turn }
    public var isFinished: Bool { finished }
    public var winner: Int? { winnerSide }
    public var victoryReason: VictoryReason? { reason }

    /// The side expected to act next (nil once finished).
    public var currentSide: Int? {
        finished ? nil : (first + turn) % 2
    }

    public func activeIndex(_ side: Int) -> Int { active[side] }

    public struct UnitState: Sendable, Equatable {
        public let id: String
        public let hp: Double
        public let maxHP: Double
        public let mana: Int
        public let fainted: Bool
        public let stunned: Bool
        public let statuses: [StatusEffectID: Int]
    }

    public func unitState(_ side: Int, _ index: Int) -> UnitState {
        let slot = sides[side][index]
        return UnitState(
            id: slot.spec.id, hp: slot.hp, maxHP: slot.maxHP, mana: slot.mana,
            fainted: slot.hp <= 0, stunned: (slot.statuses[.stun] ?? 0) > 0,
            statuses: slot.statuses
        )
    }

    public func sideState(_ side: Int) -> [UnitState] {
        sides[side].indices.map { unitState(side, $0) }
    }

    /// Actions the side's active unit may legally take right now.
    public func legalActions(_ side: Int) -> [BattleAction] {
        guard let slot = activeSlot(side), slot.hp > 0 else { return [] }
        var actions: [BattleAction] = []
        for (i, move) in slot.spec.moves.enumerated() {
            if move.kind == .special && (!slot.spec.rarity.hasMana || Double(slot.mana) < move.manaCost) {
                continue
            }
            actions.append(.move(i))
        }
        for i in sides[side].indices where i != active[side] && sides[side][i].hp > 0 {
            actions.append(.switchTo(i))
        }
        return actions
    }

    private func activeSlot(_ side: Int) -> Slot? {
        let squad = sides[side]
        return squad.indices.contains(active[side]) ? squad[active[side]] : nil
    }

    /// Whether the side's active slot is fainted and needs a free replacement.
    public func needsReplacement(_ side: Int) -> Bool {
        guard let slot = activeSlot(side) else { return false }
        return slot.hp <= 0 && sides[side].contains { $0.hp > 0 }
    }

    // MARK: - Forced replacement (free — does not consume the side's turn)

    public func chooseReplacement(_ side: Int, unitIndex: Int) {
        let squad = sides[side]
        guard squad.indices.contains(unitIndex), squad[unitIndex].hp > 0, unitIndex != active[side] else { return }
        let out = activeSlot(side)
        active[side] = unitIndex
        events.append(.switchEvent(side: side, out: out?.spec.id, in: squad[unitIndex].spec.id, forced: true))
    }

    private func autoReplace(_ side: Int) {
        if let idx = sides[side].firstIndex(where: { $0.hp > 0 }), idx != active[side] {
            chooseReplacement(side, unitIndex: idx)
        }
    }

    // MARK: - One turn

    /// Apply one side's action. Advances the turn counter and appends the
    /// event-log entries for everything the action caused.
    public func act(_ side: Int, action: BattleAction) {
        guard !finished else { return }
        guard (first + turn) % 2 == side else { return }
        if needsReplacement(side) { autoReplace(side) }

        turn += 1
        guard var slot = activeSlot(side), slot.hp > 0 else { return }
        let slotIndex = active[side]

        events.append(.turnStart(turn: turn, side: side, unit: slot.spec.id))

        // Status ticks at the start of the acting unit's turn — burn included
        // even while stunned. They draw nothing.
        if (slot.statuses[.burn] ?? 0) > 0 && slot.hp > 0 {
            let burnDamage = slot.maxHP * StatusParams.burnFraction
            slot.hp = max(0, slot.hp - burnDamage)
            events.append(.statusTick(unit: slot.spec.id, kind: .burn, damage: burnDamage))
        }
        for kind in Battle.timedStatuses where kind != .stun {
            if let left = slot.statuses[kind] {
                if left - 1 <= 0 { slot.statuses[kind] = nil } else { slot.statuses[kind] = left - 1 }
            }
        }
        sides[side][slotIndex] = slot

        if slot.hp <= 0 {
            // Burned out on its own turn start: the side loses this action
            // but the replacement is still free.
            events.append(.faint(unit: slot.spec.id))
            autoReplace(side)
            finishTurn(turn)
            return
        }

        if (slot.statuses[.stun] ?? 0) > 0 {
            // Stun eats the action and only then spends a turn of its
            // duration — decrement here, not in the pass above.
            let left = slot.statuses[.stun]!
            if left - 1 <= 0 { sides[side][slotIndex].statuses[.stun] = nil }
            else { sides[side][slotIndex].statuses[.stun] = left - 1 }
            events.append(.stunned(unit: slot.spec.id))
            finishTurn(turn)
            return
        }

        let legal = legalActions(side)
        let applied = legal.contains(action) ? action : legal.first
        guard let applied else {
            finishTurn(turn)
            return
        }

        if case .switchTo(let unitIndex) = applied {
            let outID = slot.spec.id
            active[side] = unitIndex
            events.append(.switchEvent(side: side, out: outID, in: sides[side][unitIndex].spec.id, forced: false))
            finishTurn(turn)
            return
        }

        guard case .move(let moveIndex) = applied, slot.spec.moves.indices.contains(moveIndex) else {
            finishTurn(turn)
            return
        }
        let move = slot.spec.moves[moveIndex]
        if move.kind == .special {
            // Mana is spent on use — hit or miss (spec: Specials consume
            // their authored ManaCost).
            sides[side][slotIndex].mana = max(0, slot.mana - Int(move.manaCost))
            slot.mana = sides[side][slotIndex].mana
        }

        let defSide = 1 - side
        guard var defender = activeSlot(defSide), defender.hp > 0 else {
            finishTurn(turn)
            return
        }
        let defIndex = active[defSide]

        // Draw 1 — accuracy. acc_down scales the move's authored accuracy.
        let accuracy = move.accuracy * ((slot.statuses[.accDown] ?? 0) > 0 ? StatusParams.accDownMult : 1)
        guard rng.unit() * 100 < accuracy else {
            events.append(.miss(attacker: slot.spec.id, defender: defender.spec.id, move: move.name, moveID: move.id))
            finishTurn(turn)
            return
        }

        var damage = 0.0
        var crit = false
        if move.power > 0 {
            // Draw 2 — crit. Draw 3 — variance.
            crit = rng.unit() < NQSpec.critChance
            let variance = NQSpec.varianceRange.lowerBound
                + (NQSpec.varianceRange.upperBound - NQSpec.varianceRange.lowerBound) * rng.unit()
            let effAtk = slot.spec.effectiveAttack
                * ((slot.statuses[.atkUp] ?? 0) > 0 ? StatusParams.attackUpMult : 1)
            let guardMult = (defender.statuses[.guardUp] ?? 0) > 0 ? StatusParams.guardUpMult : 1
            let base = (move.power * effAtk) / Battle.damageScale + 2
            // Minimum-damage rule: a successful hit never rounds below 1.
            damage = max(NQSpec.minDamage, floor(base * (crit ? NQSpec.critMult : 1) * variance * guardMult))
            defender.hp = max(0, defender.hp - damage)
        }
        sides[defSide][defIndex] = defender

        events.append(.attack(
            attacker: slot.spec.id, defender: defender.spec.id,
            move: move.name, moveID: move.id, damage: Int(damage), crit: crit
        ))

        // Draw 4 — secondary status, only on a hit (P = P(hit) × P(status|hit)).
        if let effect = move.statusEffect, rng.unit() * 100 < (move.statusChance ?? 100) {
            applyEffect(effect, duration: move.duration, attackerSide: side, attackerIndex: slotIndex,
                        defenderSide: defSide, defenderIndex: defIndex, damageDealt: damage)
        }

        if sides[defSide][defIndex].hp <= 0 {
            events.append(.faint(unit: sides[defSide][defIndex].spec.id))
            autoReplace(defSide)
        }

        finishTurn(turn)
    }

    private func applyEffect(
        _ effect: StatusEffectID, duration: Int?,
        attackerSide: Int, attackerIndex: Int,
        defenderSide: Int, defenderIndex: Int,
        damageDealt: Double
    ) {
        switch effect {
        case .heal:
            let amount = sides[attackerSide][attackerIndex].maxHP * StatusParams.healFraction
            let slot = sides[attackerSide][attackerIndex]
            sides[attackerSide][attackerIndex].hp = min(slot.maxHP, slot.hp + amount)
            events.append(.heal(unit: slot.spec.id, amount: amount, kind: nil))
        case .leech:
            let amount = damageDealt * StatusParams.leechFraction
            let slot = sides[attackerSide][attackerIndex]
            sides[attackerSide][attackerIndex].hp = min(slot.maxHP, slot.hp + amount)
            events.append(.heal(unit: slot.spec.id, amount: amount, kind: .leech))
        case .atkUp, .guardUp:
            // Self-buffs: the duration counts down on the USER's turns.
            sides[attackerSide][attackerIndex].statuses[effect] = duration ?? 2
            events.append(.status(unit: sides[attackerSide][attackerIndex].spec.id, kind: effect, source: nil))
        default:
            // burn / acc_down / stun land on the defender.
            sides[defenderSide][defenderIndex].statuses[effect] = duration ?? 1
            events.append(.status(unit: sides[defenderSide][defenderIndex].spec.id, kind: effect,
                                  source: sides[attackerSide][attackerIndex].spec.id))
        }
    }

    private func finishTurn(_ turn: Int) {
        events.append(.turnEnd(turn: turn))
        let aAlive = sides[0].contains { $0.hp > 0 }
        let bAlive = sides[1].contains { $0.hp > 0 }
        if !aAlive || !bAlive {
            winnerSide = aAlive ? 0 : 1
            finished = true
            reason = .wipeout
            events.append(.victory(winner: winnerSide!, turns: turn, reason: .wipeout))
        }
    }

    // MARK: - Turn-limit resolution (anti-stall)
    //
    // Deterministic: remaining non-fainted monsters first, then total HP
    // percentage, then — only if both tie — one seeded draw.

    private func resolveTurnLimit() {
        let alive = sides.map { $0.filter { $0.hp > 0 }.count }
        let share: (Int) -> Double = { [self] side in
            let hp = self.sides[side].reduce(0.0) { $0 + max(0, $1.hp) }
            let total = self.sides[side].reduce(0.0) { $0 + $1.maxHP }
            return total > 0 ? hp / total : 0
        }
        let winner: Int
        if alive[0] != alive[1] {
            winner = alive[0] > alive[1] ? 0 : 1
        } else {
            let shareA = share(0), shareB = share(1)
            // Tiebreak draw — the only post-flip draw outside action resolution.
            winner = shareA != shareB ? (shareA > shareB ? 0 : 1) : (rng.unit() < 0.5 ? 0 : 1)
        }
        winnerSide = winner
        finished = true
        reason = .turnLimit
        events.append(.victory(winner: winner, turns: turn, reason: .turnLimit))
    }

    // MARK: - Whole-match driver

    /// A policy answers "what does this side do?" for interactive drivers.
    public typealias Policy = (Battle, Int) -> BattleAction

    /// Default policy: uniform pick among legal move/special actions (one
    /// RNG draw); never switches voluntarily. Deterministic given the seed.
    public static func autoPolicy(battle: Battle, side: Int) -> BattleAction {
        let usable = battle.legalActions(side).compactMap { a -> BattleAction? in
            if case .move = a { return a }
            return nil
        }
        guard !usable.isEmpty else { return .move(0) }
        return usable[Int((battle.draw() * Double(usable.count)).rounded(.down))]
    }

    public func runToCompletion(policyA: Policy? = nil, policyB: Policy? = nil, seed: UInt64) -> BattleReplay {
        let policies: [Policy] = [policyA ?? Battle.autoPolicy, policyB ?? Battle.autoPolicy]
        while !finished && turn < maxTurns {
            let side = (first + turn) % 2
            act(side, action: policies[side](self, side))
        }
        if !finished { resolveTurnLimit() }

        let fractions: (Int) -> [Double] = { side in
            self.sides[side].map { max(0, $0.hp) / $0.maxHP }
        }
        let fainted: (Int) -> [String] = { side in
            self.sides[side].filter { $0.hp <= 0 }.map { $0.spec.id }
        }
        return BattleReplay(
            seed: seed,
            events: events,
            winnerSide: winnerSide ?? 0,
            turns: turn,
            reason: reason ?? .turnLimit,
            hpFractionsA: fractions(0),
            hpFractionsB: fractions(1),
            faintedA: fainted(0),
            faintedB: fainted(1)
        )
    }
}

/// One-shot convenience: build a Battle, auto-run both sides, hand back the
/// replay. Same squads + same seed → same result on device and server.
public enum BattleEngine {
    public static func simulate(
        squadA: [BattleUnitSpec],
        squadB: [BattleUnitSpec],
        seed: UInt64,
        options: Battle.Options = .init()
    ) -> BattleReplay {
        Battle(squadA: squadA, squadB: squadB, seed: seed, options: options)
            .runToCompletion(seed: seed)
    }
}
