import Foundation

// BattleKit model — the Swift mirror of backend/src/services/battleEngine.ts
// over the Phase-0 contract (backend/src/schemas/monster.ts, Spec.swift).
//
// The spec removed: elements/types, the tempo turn-order stat, the
// four-stat model, squad bonuses, and the global miss chance. Monsters now
// carry Health + Base Attack (+ Mana on Epic and above), 3 authored standard
// moves, and one Mana Special.

// MARK: - Rarity

/// The seven-tier ladder. Order matches `rarityCombatMult` in Spec.swift and
/// `RARITY_COMBAT_MULT` in backend/src/game/spec.ts. Rarity is a property of
/// the monster INSTANCE — rolled at mint — never of the catalog character.
public enum BattleRarity: Int, CaseIterable, Sendable, Comparable, Codable {
    case common = 0, uncommon, rare, epic, legendary, mythic, secret

    public var statMultiplier: Double { NQSpec.rarityCombatMult[rawValue] }

    /// Epic and above carry Mana and can use the Special Ability.
    public var hasMana: Bool { self >= NQSpec.manaMinRarity }

    /// Highest star level this rarity can reach (Secret caps at ★2).
    public var maxStars: Int { self == .secret ? NQSpec.secretMaxStar : NQSpec.maxStar }

    public static func < (l: BattleRarity, r: BattleRarity) -> Bool { l.rawValue < r.rawValue }
}

// MARK: - Statuses

/// The authored status vocabulary (catalog `statusEffect` ids).
/// Timed statuses store their remaining duration in the afflicted side's
/// turns; `heal`/`leech` are instant and never stored.
public enum StatusEffectID: String, Sendable, Codable, CaseIterable {
    case burn = "burn"        // DoT: STATUS_PARAMS fraction of max HP per turn
    case accDown = "acc_down" // accuracy × STATUS_PARAMS.accDownMult
    case atkUp = "atk_up"     // effective attack × STATUS_PARAMS.attackUpMult
    case guardUp = "guard_up" // incoming damage × STATUS_PARAMS.guardUpMult
    case stun = "stun"        // skips its actions while active
    case heal = "heal"        // instant self-heal
    case leech = "leech"      // instant heal for a fraction of damage dealt
}

// MARK: - Moves

/// One authored move as the engine consumes it — mirror of MoveSpec.
public struct BattleMoveSpec: Sendable, Equatable, Codable, Identifiable {
    public enum Kind: String, Sendable, Codable {
        case standard
        /// Mana-based Special Ability — Epic+ only, consumes `manaCost`.
        case special
    }

    public let id: String
    public let name: String
    public let kind: Kind
    /// 0–10 damage scale; 0 = pure status/utility move.
    public let power: Double
    /// 1...100 — P(hit) = accuracy/100, modified by acc_down.
    public let accuracy: Double
    /// Mana spent on use; > 0 only on specials.
    public let manaCost: Double
    public let statusEffect: StatusEffectID?
    /// P(status | hit) in percent.
    public let statusChance: Double?
    /// Timed-status duration in the affected side's turns.
    public let duration: Int?
    public let description: String?

    public init(
        id: String, name: String, kind: Kind, power: Double, accuracy: Double,
        manaCost: Double, statusEffect: StatusEffectID? = nil,
        statusChance: Double? = nil, duration: Int? = nil, description: String? = nil
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.power = power
        self.accuracy = accuracy
        self.manaCost = manaCost
        self.statusEffect = statusEffect
        self.statusChance = statusChance
        self.duration = duration
        self.description = description
    }
}

/// Fallback for units with no authored catalog entry (mirror of STRIKE in
/// backend/src/data/attacks.ts).
public let strikeMove = BattleMoveSpec(
    id: "strike", name: "Strike", kind: .standard, power: 3, accuracy: 100, manaCost: 0
)

// MARK: - Squad snapshot

/// One locked monster entering a battle — the battle-start squad snapshot
/// (mirror of BattleUnitSpec). baseHealth/baseAttack are PRE-scaling bases;
/// the engine applies rarity × star itself.
public struct BattleUnitSpec: Sendable, Equatable, Codable, Identifiable {
    public let id: String
    public let name: String
    public let baseHealth: Double
    public let baseAttack: Double
    public let rarity: BattleRarity
    /// 1...5 mastery stars; Secret clamps to ★2 inside the engine.
    public let star: Int
    public let moves: [BattleMoveSpec]
    /// Authored per character; only Epic+ instances carry Mana.
    public let baseMana: Double?

    public init(
        id: String, name: String, baseHealth: Double, baseAttack: Double,
        rarity: BattleRarity, star: Int, moves: [BattleMoveSpec], baseMana: Double? = nil
    ) {
        self.id = id
        self.name = name
        self.baseHealth = baseHealth
        self.baseAttack = baseAttack
        self.rarity = rarity
        self.star = star
        self.moves = moves
        self.baseMana = baseMana
    }

    /// Engine-scaled max HP — rarity × star applied.
    public var maxHP: Double { NQSpec.effectiveStat(baseHealth, rarity: rarity, stars: star) }
    /// Engine-scaled attack — same scaling expression.
    public var effectiveAttack: Double { NQSpec.effectiveStat(baseAttack, rarity: rarity, stars: star) }
    /// floor(baseMana × starManaMult); 0 for sub-Epic.
    public var startingMana: Int {
        NQSpec.startingMana(baseMana ?? 0, rarity: rarity, stars: star)
    }
}

// MARK: - Actions

public enum BattleAction: Sendable, Equatable {
    /// Use move at `moves[index]` (standard or special).
    case move(Int)
    /// Voluntary switch to squad slot — consumes the whole turn.
    case switchTo(Int)
}

// MARK: - Battle events (replay)

/// One event in the replay stream. Field names match the server's JSON
/// (schemas/battle-event.json) so BattleReplayMapper can build these from
/// the response payload verbatim.
public enum BattleEvent: Sendable, Equatable, Codable {
    case battleStart(seed: String, first: Int)
    case turnStart(turn: Int, side: Int, unit: String)
    case turnEnd(turn: Int)
    case attack(attacker: String, defender: String, move: String, moveID: String, damage: Int, crit: Bool)
    case miss(attacker: String, defender: String, move: String, moveID: String)
    /// A timed status was applied (self-buffs carry no `source`).
    case status(unit: String, kind: StatusEffectID, source: String?)
    /// Burn tick at the start of the afflicted unit's turn.
    case statusTick(unit: String, kind: StatusEffectID, damage: Double)
    /// Instant heal (kind nil = heal move, "leech" = leech proc).
    case heal(unit: String, amount: Double, kind: StatusEffectID?)
    /// The unit's action was consumed by stun.
    case stunned(unit: String)
    /// forced = free faint replacement; false = voluntary switch (a whole turn).
    case switchEvent(side: Int, out: String?, `in`: String, forced: Bool)
    case faint(unit: String)
    case victory(winner: Int, turns: Int, reason: VictoryReason)

    // MARK: Codable — schemas/battle-event.json wire shape
    //
    // The same JSON the server emits and the LAN host sends: one object per
    // event, discriminated by `event`. Sides are "A"/"B" on the wire, 0/1
    // in memory; the seed stays a string so a UInt64 seed survives JSON.

    private enum WireKey: String, CodingKey {
        case event, seed, first, turn, side, unit, attacker, defender
        case move, moveId, damage, crit, kind, source, amount
        case out, `in`, forced, winner, turns, reason, typeMod
    }

    private static func sideName(_ side: Int) -> String { side == 0 ? "A" : "B" }
    private static func sideIndex(_ name: String) -> Int { name == "A" ? 0 : 1 }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: WireKey.self)
        func miss(_ key: WireKey) -> DecodingError {
            DecodingError.keyNotFound(key, .init(codingPath: decoder.codingPath, debugDescription: "battle event missing '\(key.rawValue)'"))
        }
        switch try c.decode(String.self, forKey: .event) {
        case "battleStart":
            self = .battleStart(seed: try c.decode(String.self, forKey: .seed),
                                first: Self.sideIndex(try c.decode(String.self, forKey: .first)))
        case "turnStart":
            self = .turnStart(turn: try c.decode(Int.self, forKey: .turn),
                              side: Self.sideIndex(try c.decode(String.self, forKey: .side)),
                              unit: try c.decode(String.self, forKey: .unit))
        case "turnEnd":
            self = .turnEnd(turn: try c.decode(Int.self, forKey: .turn))
        case "attack":
            self = .attack(attacker: try c.decode(String.self, forKey: .attacker),
                           defender: try c.decode(String.self, forKey: .defender),
                           move: try c.decode(String.self, forKey: .move),
                           moveID: try c.decode(String.self, forKey: .moveId),
                           damage: try c.decode(Int.self, forKey: .damage),
                           crit: try c.decode(Bool.self, forKey: .crit))
        case "miss":
            self = .miss(attacker: try c.decode(String.self, forKey: .attacker),
                         defender: try c.decode(String.self, forKey: .defender),
                         move: try c.decode(String.self, forKey: .move),
                         moveID: try c.decode(String.self, forKey: .moveId))
        case "status":
            guard let kind = StatusEffectID(rawValue: try c.decode(String.self, forKey: .kind)) else { throw miss(.kind) }
            self = .status(unit: try c.decode(String.self, forKey: .unit), kind: kind,
                           source: try c.decodeIfPresent(String.self, forKey: .source))
        case "statusTick":
            guard let kind = StatusEffectID(rawValue: try c.decode(String.self, forKey: .kind)) else { throw miss(.kind) }
            self = .statusTick(unit: try c.decode(String.self, forKey: .unit), kind: kind,
                               damage: try c.decode(Double.self, forKey: .damage))
        case "heal":
            let kind = try c.decodeIfPresent(String.self, forKey: .kind).flatMap(StatusEffectID.init(rawValue:))
            self = .heal(unit: try c.decode(String.self, forKey: .unit),
                         amount: try c.decode(Double.self, forKey: .amount), kind: kind)
        case "stunned":
            self = .stunned(unit: try c.decode(String.self, forKey: .unit))
        case "switch":
            self = .switchEvent(side: Self.sideIndex(try c.decode(String.self, forKey: .side)),
                                out: try c.decodeIfPresent(String.self, forKey: .out),
                                in: try c.decode(String.self, forKey: .in),
                                forced: try c.decode(Bool.self, forKey: .forced))
        case "faint":
            self = .faint(unit: try c.decode(String.self, forKey: .unit))
        case "victory":
            guard let reason = VictoryReason(rawValue: try c.decode(String.self, forKey: .reason)) else { throw miss(.reason) }
            self = .victory(winner: Self.sideIndex(try c.decode(String.self, forKey: .winner)),
                            turns: try c.decode(Int.self, forKey: .turns), reason: reason)
        case let other:
            throw DecodingError.dataCorruptedError(forKey: .event, in: c,
                debugDescription: "Unknown battle event '\(other)'")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: WireKey.self)
        switch self {
        case .battleStart(let seed, let first):
            try c.encode("battleStart", forKey: .event)
            try c.encode(seed, forKey: .seed)
            try c.encode(Self.sideName(first), forKey: .first)
        case .turnStart(let turn, let side, let unit):
            try c.encode("turnStart", forKey: .event)
            try c.encode(turn, forKey: .turn)
            try c.encode(Self.sideName(side), forKey: .side)
            try c.encode(unit, forKey: .unit)
        case .turnEnd(let turn):
            try c.encode("turnEnd", forKey: .event)
            try c.encode(turn, forKey: .turn)
        case .attack(let attacker, let defender, let move, let moveID, let damage, let crit):
            try c.encode("attack", forKey: .event)
            try c.encode(attacker, forKey: .attacker)
            try c.encode(defender, forKey: .defender)
            try c.encode(move, forKey: .move)
            try c.encode(moveID, forKey: .moveId)
            try c.encode(damage, forKey: .damage)
            try c.encode(crit, forKey: .crit)
            try c.encode(1.0, forKey: .typeMod) // legacy echo — the type system is gone
        case .miss(let attacker, let defender, let move, let moveID):
            try c.encode("miss", forKey: .event)
            try c.encode(attacker, forKey: .attacker)
            try c.encode(defender, forKey: .defender)
            try c.encode(move, forKey: .move)
            try c.encode(moveID, forKey: .moveId)
        case .status(let unit, let kind, let source):
            try c.encode("status", forKey: .event)
            try c.encode(unit, forKey: .unit)
            try c.encode(kind.rawValue, forKey: .kind)
            try c.encodeIfPresent(source, forKey: .source)
        case .statusTick(let unit, let kind, let damage):
            try c.encode("statusTick", forKey: .event)
            try c.encode(unit, forKey: .unit)
            try c.encode(kind.rawValue, forKey: .kind)
            try c.encode(damage, forKey: .damage)
        case .heal(let unit, let amount, let kind):
            try c.encode("heal", forKey: .event)
            try c.encode(unit, forKey: .unit)
            try c.encode(amount, forKey: .amount)
            try c.encodeIfPresent(kind?.rawValue, forKey: .kind)
        case .stunned(let unit):
            try c.encode("stunned", forKey: .event)
            try c.encode(unit, forKey: .unit)
        case .switchEvent(let side, let out, let newIn, let forced):
            try c.encode("switch", forKey: .event)
            try c.encode(Self.sideName(side), forKey: .side)
            try c.encodeIfPresent(out, forKey: .out)
            try c.encode(newIn, forKey: .in)
            try c.encode(forced, forKey: .forced)
        case .faint(let unit):
            try c.encode("faint", forKey: .event)
            try c.encode(unit, forKey: .unit)
        case .victory(let winner, let turns, let reason):
            try c.encode("victory", forKey: .event)
            try c.encode(Self.sideName(winner), forKey: .winner)
            try c.encode(turns, forKey: .turns)
            try c.encode(reason.rawValue, forKey: .reason)
        }
    }
}

public enum VictoryReason: String, Sendable, Codable {
    /// All three monsters on one side fainted.
    case wipeout
    /// Anti-stall: the max-turn cap was hit; resolved by count then HP share.
    case turnLimit
}

/// Full deterministic replay: server and client produce identical events for
/// identical squads + seed.
public struct BattleReplay: Sendable, Equatable {
    public let seed: UInt64
    public let events: [BattleEvent]
    /// 0 = side A, 1 = side B.
    public let winnerSide: Int
    /// Total side-turns played.
    public let turns: Int
    public let reason: VictoryReason
    /// End-of-battle HP as fractions of effective max HP, in squad order.
    public let hpFractionsA: [Double]
    public let hpFractionsB: [Double]
    /// Units that ended at 0 HP — the faint-persistence list.
    public let faintedA: [String]
    public let faintedB: [String]

    public init(
        seed: UInt64, events: [BattleEvent], winnerSide: Int, turns: Int,
        reason: VictoryReason, hpFractionsA: [Double], hpFractionsB: [Double],
        faintedA: [String], faintedB: [String]
    ) {
        self.seed = seed
        self.events = events
        self.winnerSide = winnerSide
        self.turns = turns
        self.reason = reason
        self.hpFractionsA = hpFractionsA
        self.hpFractionsB = hpFractionsB
        self.faintedA = faintedA
        self.faintedB = faintedB
    }
}
