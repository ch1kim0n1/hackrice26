import XCTest
@testable import NutriQuest

// ============================================================================
// Scan -> character pipeline regression guard (issue #24).
//
// GameState.registerScanResult is the moment a barcode scan becomes a
// playable character. The server owns the mint — it scores nutrition, rolls
// rarity, picks the catalog monster and returns the instance — so these
// tests pin the client contract: the minted character lands in
// GameState.scannedCharacters (the collection source of truth), its battle
// snapshot is registered under the character id, and a duplicate scan logs
// the meal without minting.
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

    private func makeResult(
        name: String = "Nutella",
        rarity: String = "rare",
        baseHealth: Double = 120,
        baseAttack: Double = 60,
        duplicate: Bool = false
    ) -> ScanResultDTO {
        ScanResultDTO(
            barcode: barcode,
            foodName: name,
            brands: nil,
            nutritionScore: 62,
            summonedCharacter: duplicate ? nil : LootCharacterDTO(
                id: "scan-\(barcode)",
                name: name,
                colorHex: "#5FCB82",
                rarity: rarity,
                imageKey: nil,
                tagline: nil,
                baseHealth: baseHealth,
                baseAttack: baseAttack,
                baseMana: nil,
                isLocked: false,
                rarityLabel: nil,
                rarityColorHex: nil,
                flavor: nil,
                bio: nil
            ),
            nutrition: ScanNutritionDTO(
                calories: 539, proteinG: 6.3, carbsG: nil, fatG: nil,
                fiberG: 3.3, sugarG: 56.3, sodiumMg: nil, satFatG: nil
            ),
            duplicate: duplicate,
            mealId: "meal-1",
            mint: duplicate ? nil : ScanMintDTO(dropId: "drop-1", netWorth: 1200, stars: 1)
        )
    }

    func testScanRegistersCharacterInCollection() throws {
        let gameState = GameState()

        let character = try XCTUnwrap(gameState.registerScanResult(makeResult()))

        XCTAssertEqual(character.id, "scan-\(barcode)")
        XCTAssertEqual(character.name, "Nutella")
        XCTAssertFalse(character.isLocked)
        XCTAssertTrue(gameState.scannedCharacters.contains { $0.id == character.id })
    }

    func testScanRegistersBattleCharacter() throws {
        let gameState = GameState()

        let character = try XCTUnwrap(gameState.registerScanResult(makeResult()))

        // Keyed by the character id — the same key every lookup uses. This
        // used to assert the bare barcode, which encoded a bug: lookups by
        // character id missed, and scanned characters fought with sample stats.
        let battleCharacter = gameState.battleCharacters[character.id]
        XCTAssertNotNil(battleCharacter)
        XCTAssertEqual(battleCharacter?.name, "Nutella")
    }

    /// The stats a battle actually uses must be the server's minted bases,
    /// not the local fallback (100/50).
    func testScannedCharacterBattlesWithItsServerStats() throws {
        let gameState = GameState()

        let character = try XCTUnwrap(gameState.registerScanResult(
            makeResult(baseHealth: 120, baseAttack: 60)
        ))
        let stats = gameState.battleStats(for: character)

        XCTAssertEqual(stats.baseHealth, 120, accuracy: 0.001)
        XCTAssertEqual(stats.baseAttack, 60, accuracy: 0.001)
    }

    /// Rarity comes from the server's roll — the client never re-derives it.
    func testScanPreservesRarityFromTheServer() throws {
        let gameState = GameState()

        let character = try XCTUnwrap(gameState.registerScanResult(makeResult(rarity: "epic")))

        XCTAssertEqual(character.rarity, .epic)
    }

    /// A barcode mints once per user ever: the duplicate response carries no
    /// monster but still logs the meal and the scan.
    func testDuplicateScanMintsNothingButStillLogs() throws {
        let gameState = GameState()

        let character = gameState.registerScanResult(makeResult(duplicate: true))

        XCTAssertNil(character)
        XCTAssertTrue(gameState.scannedCharacters.isEmpty)
        XCTAssertEqual(gameState.recentScans.first, "Nutella")
        // The meal also lands on the day log, but appendDayLog is async —
        // asserting it here races the MainActor hop.
    }

    func testRecentScansLogRecordsDisplayName() throws {
        let gameState = GameState()

        _ = gameState.registerScanResult(makeResult())

        XCTAssertEqual(gameState.recentScans.first, "Nutella")
    }
}
