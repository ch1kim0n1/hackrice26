import Foundation

/// Frozen Phase-0 battle contract — mirror of `backend/src/game/spec.ts`.
///
/// Same numbers on device and server so a seeded replay is identical on both.
/// The spec removed: elements/types, the tempo turn-order stat, power bands,
/// shiny, and the 4-stat (power/guard/vitality/tempo) model. Monsters now
/// carry Health + Base Attack (+ Mana on Epic and above).
public enum NQSpec {

    // MARK: - Rarity / stars (doc §2)

    /// Combat multiplier per rarity. Order matches `BattleRarity` raw values.
    public static let rarityCombatMult: [Double] = [1.00, 1.06, 1.12, 1.25, 1.40, 1.55, 1.70]

    /// Star combat multipliers, index = stars - 1 (★1..★5).
    /// Multiplicative with the rarity multiplier.
    public static let starCombatMult: [Double] = [1.00, 1.08, 1.18, 1.30, 1.45]

    /// Star Mana multipliers, index = stars - 1 (★1..★5).
    public static let starManaMult: [Double] = [1.00, 1.10, 1.20, 1.35, 1.50]

    public static let maxStar = 5
    /// Secret monsters never exceed ★2.
    public static let secretMaxStar = 2

    /// Epic and above (BattleRarity rawValue >= 3) carry Mana and a Special.
    public static let manaMinRarity = BattleRarity.epic

    // MARK: - Battle format (doc §4)

    public static let teamSize = 3
    public static let standardMovesPerCharacter = 3

    public static let critChance = 1.0 / 24.0   // ≈4.17%
    public static let critMult = 1.5
    public static let varianceRange: ClosedRange<Double> = 0.85...1.00
    /// A successful damaging hit never deals less than this. Misses deal 0.
    public static let minDamage = 1.0
    /// PvP opening-turn coin flip. PvE: the human always opens.
    public static let pvpFirstTurnP = 0.5

    // MARK: - Derived helpers (shared formulas, not data)

    /// effectiveAttack = baseAttack × rarityMult × starCombatMult.
    /// The same expression applies to effectiveHealth.
    public static func effectiveStat(_ base: Double, rarity: BattleRarity, stars: Int) -> Double {
        base * rarityCombatMult[rarity.rawValue] * starCombatMult[clampedStars(stars, rarity: rarity) - 1]
    }

    /// startingMana = floor(baseMana × starManaMult). 0 for sub-Epic.
    public static func startingMana(_ baseMana: Double, rarity: BattleRarity, stars: Int) -> Int {
        guard rarity >= manaMinRarity else { return 0 }
        return Int((baseMana * starManaMult[clampedStars(stars, rarity: rarity) - 1]).rounded(.down))
    }

    public static func clampedStars(_ stars: Int, rarity: BattleRarity) -> Int {
        let cap = rarity == .secret ? secretMaxStar : maxStar
        return min(max(stars, 1), cap)
    }
}
