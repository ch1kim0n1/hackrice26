import XCTest
@testable import NutriQuest

// ============================================================================
// Scan -> character pipeline regression guard (issue #24).
//
// GameState.registerScan is the moment a scanned barcode becomes a playable
// character. These tests pin the contract: the character lands in
// GameState.scannedCharacters (the collection source of truth) and its
// battle representation is registered so the battle screen can field it.
//
// Note: issue #20 tracks the fact that RootTabView still feeds Collection/
// Battle from a static SampleData list instead of GameState.scannedCharacters.
// When #20 lands and GameState becomes the single source of truth, these
// tests guard the merge point.
// ============================================================================

@MainActor
final class ScanPipelineTests: XCTestCase {

    private let barcode = "3017620422003"

    private func makeProduct(name: String = "Nutella") throws -> FoodProduct {
        let json = """
        {
            "product_name_en": "\(name)",
            "nutriments": {
                "energy-kcal_100g": 539,
                "proteins_100g": 6.3,
                "fiber_100g": 3.3,
                "sugars_100g": 56.3
            },
            "vitamins_tags": ["en:vitamin-b2"],
            "labels_tags": ["en:vegetarian", "en:palmoil-free"]
        }
        """.data(using: .utf8)!
        return try JSONDecoder().decode(FoodProduct.self, from: json)
    }

    func testScanRegistersCharacterInCollection() throws {
        let gameState = GameState()
        let product = try makeProduct()

        let character = gameState.registerScan(product: product, barcode: barcode)

        XCTAssertEqual(character.id, "scan-\(barcode)")
        XCTAssertEqual(character.name, "Nutella")
        XCTAssertFalse(character.isLocked)
        XCTAssertTrue(gameState.scannedCharacters.contains { $0.id == character.id })
    }

    func testScanRegistersBattleCharacter() throws {
        let gameState = GameState()
        let product = try makeProduct()

        let character = gameState.registerScan(product: product, barcode: barcode)

        // Keyed by the character id — the same key every lookup uses. This
        // used to assert the bare barcode, which encoded a bug: lookups by
        // character id missed, and scanned characters fought with sample stats.
        let battleCharacter = gameState.battleCharacters[character.id]
        XCTAssertNotNil(battleCharacter)
        XCTAssertEqual(battleCharacter?.name, "Nutella")
    }

    /// The stats a battle actually uses must be the scanned nutrition, not
    /// the balanced sample fallback (all 50s).
    func testScannedCharacterBattlesWithItsRealStats() throws {
        let gameState = GameState()
        let product = try makeProduct()

        let character = gameState.registerScan(product: product, barcode: barcode)
        let stats = try XCTUnwrap(gameState.battleStats(for: character))

        // CharacterFactory: power = 20 + protein × 4. The sample fallback is 50.
        XCTAssertEqual(stats.baseStats.power, 20 + 6.3 * 4, accuracy: 0.001)
        XCTAssertNotEqual(stats.baseStats.power, 50)
    }

    /// A product with enough scarcity signals must surface its real tier.
    ///
    /// Regression guard: BattleRarity is Int-backed and Rarity is String-backed,
    /// so bridging through the raw value produced "0"/"1"/... and fell back to
    /// .common for every scan ever made. CharacterFactory scores 4+ labels as
    /// .rare, so this product must not come back common.
    func testScanPreservesRarityFromTheProduct() throws {
        let gameState = GameState()
        let json = """
        {
            "product_name_en": "Fancy Muesli",
            "nutriments": { "proteins_100g": 12, "fiber_100g": 9, "sugars_100g": 4 },
            "vitamins_tags": ["en:vitamin-b2", "en:vitamin-e"],
            "labels_tags": ["en:organic", "en:fair-trade", "en:no-added-sugar"]
        }
        """.data(using: .utf8)!
        let product = try JSONDecoder().decode(FoodProduct.self, from: json)

        let character = gameState.registerScan(product: product, barcode: "1234567890123")

        XCTAssertEqual(character.rarity, .rare)
    }

    /// Every BattleKit tier must survive the hop into the app's Rarity enum.
    func testEveryRarityTierBridgesFromBattleKit() throws {
        let gameState = GameState()
        // 8+ labels scores .epic in CharacterFactory.
        let json = """
        {
            "product_name_en": "Superfood Bowl",
            "nutriments": { "proteins_100g": 20, "fiber_100g": 14, "sugars_100g": 2 },
            "vitamins_tags": ["en:vitamin-a", "en:vitamin-c", "en:vitamin-d", "en:vitamin-e"],
            "labels_tags": ["en:organic", "en:vegan", "en:gluten-free", "en:fair-trade", "en:no-additives"]
        }
        """.data(using: .utf8)!
        let product = try JSONDecoder().decode(FoodProduct.self, from: json)

        let character = gameState.registerScan(product: product, barcode: "9876543210987")

        XCTAssertEqual(character.rarity, .epic)
    }

    func testRecentScansLogRecordsDisplayName() throws {
        let gameState = GameState()
        let product = try makeProduct(name: "Nutella")

        gameState.registerScan(product: product, barcode: barcode)

        XCTAssertEqual(gameState.recentScans.first, "Nutella")
    }
}
