import Foundation
import NutriQuestUI

/// Cartoon filenames in `game-assets/`. One table so collection, battle,
/// crates, and the catalog URL all point at the same drawing.
enum GameArt {
    private static let sprites: [String: (idle: String, hurt: String)] = [
        "broccoli-bud": ("broccoli-char", "brocoli-hurt"),
        "carrot-cadet": ("carrot-char", "carrot-hurt"),
        "water-droplet": ("water-char", "water-hurt"),
        "bean-sprout": ("bean-sprout-char", "mean-sprout-hurt"),
        "spinach-scout": ("spinach-char", "spanich-hurt"),
        "almond-knight": ("almond-char", "almond-hurt"),
        "salmon-striker": ("salmon-char", "salmon-hurt"),
        "avocado-aegis": ("avocado-char", "avocado-hurt"),
        "kale-colossus": ("kale-char", "kale-hurt"),
        "chia-chieftain": ("chia-seed-char", "chia-hurt"),
        "pomegranate-paladin": ("pomegranate-char", "pomegranate-hurt"),
        "turmeric-titan": ("turmeric-char", "turmeric-hurt"),
        "spirulina-wyrm": ("spirulina-char", "spirulia-hurt"),
        "the-first-seed": ("seed-char", "seed-hurt"),
        "oat-sprout": ("oat-char", "oat-hurt"),
        "rice-grain": ("rice-char", "rice-hurt"),
        "yogurt-sage": ("Yogurt-char", "yogurt-hurt"),
        "berry-bolt": ("raspberry-char", "rasberry-hurt"),
        "quinoa-quill": ("quinoa-char", "quinoa-hurt"),
        "mango-monarch": ("mango-char", "mango-hurt"),
        "cacao-phantom": ("cocoa-char", "coca-hurt"),
        "sushi-sam": ("sushi-char", "sushi-hurt"),
        "berry-belle": ("berry-char", "berry-hurt"),
        "citrus-chip": ("orange-char", "orange-hurt"),
        "grape-gus": ("grapes-char", "grape-hurt"),
        "sprout-wisp": ("Sprout-char", "sprout-hurt"),
        "shark-brainrot": ("shark-brainrot", "shark-brainrot"),
        "zibra-zubra-zibralini": ("Zibra-Zubra-Zibralini", "Zibra-Zubra-Zibralini"),
        "frigo-camello": ("Frigo-Camello", "Frigo-Camello"),
        "bobrini-cocosini": ("Bobrini-Cocosini", "Bobrini-Cocosini"),
        "triple-t-brainrot": ("triple-t-brainrot", "triple-t-brainrot")
    ]

    private static let crates: [String: (closed: String, opened: String)] = [
        "starter-crate": ("common-chest", "common-chest-opened"),
        "garden-crate": ("uncommon-chest", "uncommon-chest-opened"),
        "pantry-crate": ("rare-chest", "rare-chest-opened"),
        "harvest-crate": ("loot-capsule", "harvest-chest-opened"),
        "protein-crate": ("gym-chest", "gym-chest-opened"),
        "dessert-crate": ("sweet-chest-epic", "sweet-chest-epic"),
        "chefs-table-crate": ("legendary-case", "legendary-chest-opened"),
        "secret-crate": ("secret-chest", "secret-chest-opened")
    ]

    static func sprite(id: String, hurt: Bool = false) -> String {
        let key = canonicalID(id)
        if key.hasPrefix("locked") || key.hasPrefix("???") { return "unknown-characters" }
        if key.hasPrefix("scan-") {
            return hurt ? "other-dish-hurt" : "other-dish-char"
        }
        guard let pair = sprites[key] else {
            return hurt ? "other-dish-hurt" : "other-dish-char"
        }
        return hurt ? pair.hurt : pair.idle
    }

    /// Per-rarity variant name (`<id>-epic|legendary|mythic`) — the caller
    /// must still fall back to `sprite(id:)` since not every character has
    /// variant art. Rarities below epic use the base sprite.
    static func spriteVariant(id: String, rarity: NQRarity) -> String? {
        switch rarity {
        case .epic, .legendary, .mythic:
            let key = canonicalID(id)
            guard sprites[key] != nil else { return nil }
            return "\(key)-\(rarity.rawValue)"
        default:
            return nil
        }
    }

    static func crateClosed(_ crateID: String) -> String {
        crates[crateID]?.closed ?? "common-chest"
    }

    static func crateOpened(_ crateID: String) -> String {
        crates[crateID]?.opened ?? "common-chest-opened"
    }

    static func rarityChest(closed rarity: NQRarity, opened: Bool) -> String {
        switch (rarity, opened) {
        case (.common, false): return "common-chest"
        case (.common, true): return "common-chest-opened"
        case (.uncommon, false): return "uncommon-chest"
        case (.uncommon, true): return "uncommon-chest-opened"
        case (.rare, false): return "rare-chest"
        case (.rare, true): return "rare-chest-opened"
        case (.epic, false): return "legendary-case"
        case (.epic, true): return "epic-chest-opened"
        case (.legendary, false): return "legendary-case"
        case (.legendary, true): return "legendary-chest-opened"
        case (.mythic, false): return "mythic-chest"
        case (.mythic, true): return "mythic-chest-opened"
        case (.secret, false): return "secret-chest"
        case (.secret, true): return "secret-chest-opened"
        }
    }

    static func rarityFrame(_ rarity: NQRarity) -> String {
        "\(rarity.rawValue)-frame"
    }

    static func gameTile(_ game: String) -> String {
        switch game {
        case "cauldron": return "cauldron-minigame-tile"
        case "mines": return "mine-mini-game-icon"
        case "plinko": return "plinko-mini-game-icon"
        case "wheel": return "rulete-mini-game-icon"
        default: return "cauldron-minigame-tile"
        }
    }

    static func scene(_ screen: String) -> String {
        switch screen {
        case "home": return "room-area"
        case "gym": return "gym-area"
        case "battle": return "battle-arena-area"
        case "casino": return "casino-area"
        case "dungeon": return "outdoors-area"
        default: return "room-area"
        }
    }

    static func streakBadge(days: Int) -> String {
        if days >= 30 { return "flame-streak-tier-3" }
        if days >= 7 { return "flame-streak-2-14-days" }
        if days >= 3 { return "streak-badge" }
        return "nutriquest-flame-medallion-flicker-common-512"
    }

    private static func canonicalID(_ id: String) -> String {
        if id.hasPrefix(Character.lanOpponentPrefix) {
            return String(id.dropFirst(Character.lanOpponentPrefix.count))
        }
        if id.hasPrefix("crate-") { return String(id.dropFirst(6)) }
        return id
    }
}
