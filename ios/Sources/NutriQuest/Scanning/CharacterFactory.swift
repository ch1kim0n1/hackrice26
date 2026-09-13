import Foundation

/// Scanned-product helpers.
///
/// Monster creation itself is gone from the client — `POST /scan` is
/// server-authoritative (once per user per barcode, anti-cheat snapshot,
/// nutrition-rolled rarity and stats). What stays here is the small
/// enrichment the local day log still wants and the server snapshot
/// doesn't carry: the Micro Score.
enum CharacterFactory {
    /// Micro Score: share of key micronutrient fields present on the product.
    static func microScore(for product: FoodProduct) -> Double {
        var present = 0.0
        let total = 5.0
        if product.vitaminsTags?.isEmpty == false { present += 1 }
        if product.mineralsTags?.isEmpty == false { present += 1 }
        if (product.nutriments?.proteins100g ?? 0) > 5 { present += 1 }
        if (product.nutriments?.fiber100g ?? 0) > 3 { present += 1 }
        if product.labelsTags?.contains(where: { $0.contains("vitamin") }) == true { present += 1 }
        return present / total
    }
}

extension FoodProduct {
    /// Convenience micro score accessor computed on demand.
    var microScore: Double? { CharacterFactory.microScore(for: self) }
}
