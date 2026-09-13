import Foundation
import BattleKit

/// Bridges a scanned Open Food Facts product into the battle system:
/// derives BattleStats from nutrition and mints a FoodCharacter.
public struct CharacterFactory {
    public init() {}

    public func character(from product: FoodProduct, barcode: String) -> FoodCharacter {
        let n = product.nutriments
        let protein = n?.proteins100g ?? 0
        let fiber = n?.fiber100g ?? 0
        let sugar = n?.sugars100g ?? 0

        let power = clamp(20 + protein * 4, 10, 100)
        let guardV = clamp(20 + fiber * 5, 10, 100)
        let vitality = clamp(20 + (product.microScore ?? 0.3) * 45, 10, 100)
        let tempo = clamp(20 + (protein / max(sugar, 1)) * 10 + (50 - sugar) * 0.6, 10, 100)

        let element = dominantElement(power: power, guardV: guardV, vitality: vitality, tempo: tempo)
        let rarity = rarity(for: product)

        return FoodCharacter(
            name: product.displayName,
            barcode: barcode,
            element: element,
            rarity: rarity,
            fusionTier: 0,
            baseStats: BattleStats(power: power, guard: guardV, vitality: vitality, tempo: tempo)
        )
    }

    /// Micro Score: share of key micronutrient fields present on the product.
    public static func microScore(for product: FoodProduct) -> Double {
        var present = 0.0
        let total = 5.0
        if product.vitaminsTags?.isEmpty == false { present += 1 }
        if product.mineralsTags?.isEmpty == false { present += 1 }
        if (product.nutriments?.proteins100g ?? 0) > 5 { present += 1 }
        if (product.nutriments?.fiber100g ?? 0) > 3 { present += 1 }
        if product.labelsTags?.contains(where: { $0.contains("vitamin") }) == true { present += 1 }
        return present / total
    }

    private func dominantElement(power: Double, guardV: Double, vitality: Double, tempo: Double) -> BattleElement {
        let values: [(BattleElement, Double)] = [
            (.protein, power), (.fiber, guardV), (.vitamin, vitality), (.hydration, tempo)
        ]
        return values.max(by: { $0.1 < $1.1 })!.0
    }

    /// Rarity from scarcity signals available on the product record.
    /// Open Prices integration refines this server-side later.
    private func rarity(for product: FoodProduct) -> BattleRarity {
        if product.novaGroup == 4 { return .common }
        let labelCount = (product.labelsTags?.count ?? 0) + (product.vitaminsTags?.count ?? 0)
        if labelCount >= 8 { return .epic }
        if labelCount >= 4 { return .rare }
        return .common
    }

    private func clamp(_ v: Double, _ lo: Double, _ hi: Double) -> Double {
        min(hi, max(lo, v))
    }
}

extension FoodProduct {
    /// Convenience micro score accessor computed on demand.
    var microScore: Double? { CharacterFactory.microScore(for: self) }
}
