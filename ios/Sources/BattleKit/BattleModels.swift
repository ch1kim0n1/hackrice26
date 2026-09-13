import Foundation

// MARK: - Elements & rarity

public enum BattleElement: String, CaseIterable, Sendable {
    case protein, fiber, vitamin, hydration

    /// Advantage triangle: Protein → Fiber → Hydration → Protein (1.25x).
    /// Vitamin is the wildcard: no advantage, +10% self stats in battle.
    public var advantageOver: BattleElement? {
        switch self {
        case .protein: return .fiber
        case .fiber: return .hydration
        case .hydration: return .protein
        case .vitamin: return nil
        }
    }

    public func typeMod(against defender: BattleElement) -> Double {
        advantageOver == defender ? 1.25 : (defender.advantageOver == self ? 0.8 : 1.0)
    }
}

/// The seven-tier ladder, matching `RARITY_TIERS` in
/// backend/src/data/lootTable.ts. The multipliers are the same numbers the
/// server derives its `RARITY_MULT` from, so a squad simulated on device and
/// on the server scales identically.
///
/// The original four multipliers are unchanged, so widening the ladder does
/// not re-balance matchups that already worked. Raw values are ordering only
/// and are never encoded, so inserting `uncommon` is safe.
public enum BattleRarity: Int, CaseIterable, Sendable, Comparable {
    case common = 0, uncommon, rare, epic, legendary, mythic, secret

    public var statMultiplier: Double {
        switch self {
        case .common: return 1.0
        case .uncommon: return 1.06
        case .rare: return 1.12
        case .epic: return 1.25
        case .legendary: return 1.4
        case .mythic: return 1.55
        case .secret: return 1.7
        }
    }

    public static func < (l: BattleRarity, r: BattleRarity) -> Bool { l.rawValue < r.rawValue }
}

// MARK: - Stat kind

public enum StatKind: String, CaseIterable, Sendable {
    case power, `guard`, vitality, tempo
}

public struct BattleStats: Sendable, Equatable {
    public var power: Double      // protein-driven attack
    public var `guard`: Double    // fiber-driven mitigation
    public var vitality: Double   // micronutrient-driven HP
    public var tempo: Double      // speed / turn order

    public init(power: Double, `guard`: Double, vitality: Double, tempo: Double) {
        self.power = power
        self.`guard` = `guard`
        self.vitality = vitality
        self.tempo = tempo
    }

    public static let standard = BattleStats(power: 40, guard: 40, vitality: 40, tempo: 40)

    /// Applies rarity multiplier and fusion tier (+8% per tier).
    public func scaled(by rarity: BattleRarity, fusionTier: Int) -> BattleStats {
        let m = rarity.statMultiplier * (1.0 + 0.08 * Double(fusionTier))
        return BattleStats(power: power * m, guard: `guard` * m, vitality: vitality * m, tempo: tempo * m)
    }

    /// Dominant stat — drives the signature move.
    public var highest: StatKind {
        let pairs: [(StatKind, Double)] = [
            (.power, power), (.guard, `guard`), (.vitality, vitality), (.tempo, tempo)
        ]
        return pairs.max(by: { $0.1 < $1.1 })!.0
    }

    public subscript(kind: StatKind) -> Double {
        switch kind {
        case .power: return power
        case .guard: return `guard`
        case .vitality: return vitality
        case .tempo: return tempo
        }
    }
}

// MARK: - Moves

public struct BattleMove: Sendable, Equatable {
    public let name: String
    public let power: Double          // 1.0 basic, 1.45 signature (x1.25 at ★3)
    public let usesStat: StatKind

    public init(name: String, power: Double, usesStat: StatKind) {
        self.name = name
        self.power = power
        self.usesStat = usesStat
    }

    public static func basic() -> BattleMove {
        BattleMove(name: "Strike", power: 1.0, usesStat: .power)
    }

    /// Signature move uses the character's dominant stat; ★3 fusion boosts it.
    public static func signature(name: String, stats: BattleStats, fusionTier: Int) -> BattleMove {
        BattleMove(name: name, power: fusionTier >= 3 ? 1.45 * 1.25 : 1.45, usesStat: stats.highest)
    }
}

// MARK: - Character & squad

public struct FoodCharacter: Sendable, Equatable, Identifiable {
    public let id: UUID
    public let name: String
    public let barcode: String
    public let element: BattleElement
    public let rarity: BattleRarity
    public let fusionTier: Int            // 0...5
    public let baseStats: BattleStats     // pre rarity/fusion scaling

    public init(
        id: UUID = UUID(),
        name: String,
        barcode: String,
        element: BattleElement,
        rarity: BattleRarity,
        fusionTier: Int = 0,
        baseStats: BattleStats
    ) {
        self.id = id
        self.name = name
        self.barcode = barcode
        self.element = element
        self.rarity = rarity
        self.fusionTier = min(max(fusionTier, 0), 5)
        self.baseStats = baseStats
    }

    public var stats: BattleStats {
        baseStats.scaled(by: rarity, fusionTier: fusionTier)
    }

    public var maxHP: Double {
        55 + stats.vitality * 1.1
    }

    public var moves: [BattleMove] {
        [
            BattleMove.basic(),
            BattleMove.signature(name: "\(name) Special", stats: stats, fusionTier: fusionTier)
        ]
    }
}

/// A unit inside a battle: character with the player's daily multiplier applied.
public struct BattleUnit: Sendable, Equatable, Identifiable {
    public let id: UUID
    public let character: FoodCharacter
    public let partyMultiplier: Double
    public let maxHP: Double

    public init(character: FoodCharacter, partyMultiplier: Double) {
        self.id = character.id
        self.character = character
        self.partyMultiplier = partyMultiplier
        self.maxHP = character.maxHP * partyMultiplier
    }

    public var stats: BattleStats { character.stats }
    public var element: BattleElement { character.element }
}

public struct BattleSquad: Sendable, Equatable {
    public let units: [BattleUnit]   // exactly 3

    public init(units: [BattleUnit]) {
        self.units = Array(units.prefix(3))
    }

    /// +5% per distinct element beyond the first (cap +10%).
    public var squadBonus: Double {
        let distinct = Set(units.map(\.element)).count
        return 1.0 + 0.05 * Double(max(0, distinct - 1))
    }
}

// MARK: - Battle events (replay)

public enum BattleEvent: Sendable, Equatable {
    case battleStart(seed: UInt64)
    case roundStart(Int)
    case attack(attackerID: UUID, defenderID: UUID, move: String, damage: Double, crit: Bool, typeMod: Double)
    case miss(attackerID: UUID, defenderID: UUID)
    case faint(unitID: UUID)
    case roundEnd(Int)
    case victory(winnerSide: Int, rounds: Int)
}

/// Full deterministic replay: both clients and the server produce this
/// identical structure for the same squads + seed.
public struct BattleReplay: Sendable, Equatable {
    public let seed: UInt64
    public let events: [BattleEvent]
    public let winnerSide: Int
    public let rounds: Int

    public init(seed: UInt64, events: [BattleEvent], winnerSide: Int, rounds: Int) {
        self.seed = seed
        self.events = events
        self.winnerSide = winnerSide
        self.rounds = rounds
    }
}
