import XCTest
@testable import NutriQuest

final class GameArtTests: XCTestCase {
    func testLootSpritesResolveToCartoonFiles() {
        let idle: [String: String] = [
            "broccoli-bud": "broccoli-char",
            "carrot-cadet": "carrot-char",
            "water-droplet": "water-char",
            "bean-sprout": "bean-sprout-char",
            "spinach-scout": "spinach-char",
            "almond-knight": "almond-char",
            "salmon-striker": "salmon-char",
            "avocado-aegis": "avocado-char",
            "kale-colossus": "kale-char",
            "chia-chieftain": "chia-seed-char",
            "pomegranate-paladin": "pomegranate-char",
            "turmeric-titan": "turmeric-char",
            "spirulina-wyrm": "spirulina-char",
            "the-first-seed": "seed-char",
            "oat-sprout": "oat-char",
            "rice-grain": "rice-char",
            "yogurt-sage": "Yogurt-char",
            "berry-bolt": "raspberry-char",
            "quinoa-quill": "quinoa-char",
            "mango-monarch": "mango-char",
            "cacao-phantom": "cocoa-char"
        ]
        for (id, file) in idle {
            XCTAssertEqual(GameArt.sprite(id: id), file, id)
        }
    }

    func testHurtAndOriginalSixAndScanFallback() {
        XCTAssertEqual(GameArt.sprite(id: "carrot-cadet", hurt: true), "carrot-hurt")
        XCTAssertEqual(GameArt.sprite(id: "bean-sprout", hurt: true), "mean-sprout-hurt")
        XCTAssertEqual(GameArt.sprite(id: "sushi-sam"), "sushi-char")
        XCTAssertEqual(GameArt.sprite(id: "berry-belle"), "berry-char")
        XCTAssertEqual(GameArt.sprite(id: "citrus-chip"), "orange-char")
        XCTAssertEqual(GameArt.sprite(id: "grape-gus"), "grapes-char")
        XCTAssertEqual(GameArt.sprite(id: "sprout-wisp"), "Sprout-char")
        XCTAssertEqual(GameArt.sprite(id: "scan-salad-1"), "other-dish-char")
        XCTAssertEqual(GameArt.sprite(id: "locked-1"), "unknown-characters")
        XCTAssertEqual(GameArt.sprite(id: "crate-carrot-cadet"), "carrot-char")
        XCTAssertEqual(GameArt.sprite(id: "shark-brainrot"), "shark-brainrot")
        XCTAssertEqual(GameArt.sprite(id: "zibra-zubra-zibralini"), "Zibra-Zubra-Zibralini")
        XCTAssertEqual(GameArt.sprite(id: "frigo-camello"), "Frigo-Camello")
        XCTAssertEqual(GameArt.sprite(id: "bobrini-cocosini"), "Bobrini-Cocosini")
        XCTAssertEqual(GameArt.sprite(id: "triple-t-brainrot"), "triple-t-brainrot")
    }

    func testCrateAndChromeNames() {
        XCTAssertEqual(GameArt.crateClosed("starter-crate"), "common-chest")
        XCTAssertEqual(GameArt.crateOpened("starter-crate"), "common-chest-opened")
        XCTAssertEqual(GameArt.crateClosed("harvest-crate"), "loot-capsule")
        XCTAssertEqual(GameArt.crateOpened("harvest-crate"), "harvest-chest-opened")
        XCTAssertEqual(GameArt.crateClosed("protein-crate"), "gym-chest")
        XCTAssertEqual(GameArt.crateClosed("dessert-crate"), "sweet-chest-epic")
        XCTAssertEqual(GameArt.crateOpened("dessert-crate"), "sweet-chest-epic")
        XCTAssertEqual(GameArt.crateClosed("chefs-table-crate"), "legendary-case")
        XCTAssertEqual(GameArt.crateClosed("secret-crate"), "secret-chest")
        XCTAssertEqual(GameArt.crateOpened("secret-crate"), "secret-chest-opened")
        XCTAssertEqual(GameArt.rarityFrame(.secret), "secret-frame")
        XCTAssertEqual(GameArt.gameTile("wheel"), "rulete-mini-game-icon")
        XCTAssertEqual(GameArt.scene("casino"), "casino-area")
        XCTAssertEqual(GameArt.streakBadge(days: 7), "flame-streak-2-14-days")
        XCTAssertEqual(GameArt.streakBadge(days: 100), "flame-streak-tier-3")
    }
}
