import Foundation

/// What one server-owned drop instance contributes to a card: its mastery,
/// its own rarity (a merged monster can out-value its tier but keeps it) and
/// whether an escrow currently holds it. Merge groups read this — the card's
/// aggregate `starLevel` can't tell three ★1s from a ★2 and a ★1.
struct DropMeta: Codable, Equatable {
    var stars: Int
    var rarity: String
    var locked: Bool
}

struct Character: Identifiable, Codable, Equatable {
    let id: String
    var name: String
    /// The character's own color — becomes the app accent color whenever this
    /// character is active (colorMode == .active) or suggested (.bestUnselected).
    var colorHex: String
    var rarity: Rarity
    var statType: StatType
    var isLocked: Bool = false
    /// produce/grain/dairy/protein/other, for characters summoned from a
    /// photographed dish. Shapes the procedural artwork so different kinds of
    /// meal read as different creatures rather than one recolored mascot.
    /// nil for barcode scans and the hand-drawn starter roster.
    var foodGroup: String? = nil
    /// Holo variant from a crate pull — cosmetic sparkle + doubled value.
    var isShiny: Bool = false
    /// Mastery, ★1–★5 (see backend/src/game/power.ts). Every monster starts
    /// at ★1; fusing raises it.
    var starLevel: Int = 1
    /// Pokédex entry, shown on the character sheet. Comes off the wire with a
    /// crate pull or a dish summon (`flavor`); nil for the starter roster,
    /// which `CharacterBios` fills in locally so the sheet reads the same
    /// offline.
    var bio: String? = nil
    /// Real, server-tracked drop instance ids this card represents — one
    /// entry per pull, several when the same character was pulled more than
    /// once. Crate pulls, casino rewards, starter monsters and scanned or
    /// dish-photo monsters all populate this — the server owns every one,
    /// so each can be sold, wagered or fused.
    var dropIDs: [String] = []
    /// Sum of every instance's net worth behind this card (services/coins.ts
    /// pays exactly this on sale). 0 when `dropIDs` is empty.
    var netWorth: Int = 0
    /// Per-instance detail keyed by dropId — populated alongside `dropIDs` by
    /// the inventory sync. Merge needs it because the backend fuses three
    /// same-character *and* same-rarity *and* same-star instances.
    var dropMeta: [String: DropMeta] = [:]

    /// Whether the server actually owns this as a sellable/wagerable drop.
    var isSellable: Bool { !dropIDs.isEmpty }

    /// Three or more unlocked copies sharing rarity and mastery? Then the
    /// backend can fuse them into the next star (max ★5). Returns the lowest
    /// eligible group — fusing bottom-up is the grind the mechanic is for.
    var mergeableGroup: (star: Int, rarity: String, dropIDs: [String])? {
        var groups: [String: (star: Int, rarity: String, ids: [String])] = [:]
        for (dropID, meta) in dropMeta where !meta.locked && meta.stars < 5 {
            let key = "\(meta.rarity)-\(meta.stars)"
            groups[key, default: (meta.stars, meta.rarity, [])].ids.append(dropID)
        }
        return groups.values
            .filter { $0.ids.count >= 3 }
            .sorted { $0.star < $1.star }
            .first
            .map { ($0.star, $0.rarity, Array($0.ids.prefix(3))) }
    }

    /// Prefix on a LAN opponent's characters. Every player starts with the
    /// same roster ids, and BattleView attributes sides and health bars by
    /// id, so an opponent's Broccoli Bud must not share yours.
    static let lanOpponentPrefix = "lan-opp:"

    /// The id without any LAN namespace — what artwork lookups key on.
    var baseID: String {
        id.hasPrefix(Self.lanOpponentPrefix) ? String(id.dropFirst(Self.lanOpponentPrefix.count)) : id
    }

    /// Prefix on a character minted from a crate pull.
    static let cratePrefix = "crate-"

    /// The catalog id behind this card: LAN namespace and crate-instance
    /// prefix removed. A pulled Broccoli Bud has to resolve to the same
    /// roster entry the starter one does, or its sheet comes up blank.
    var rosterID: String {
        let base = baseID
        return base.hasPrefix(Self.cratePrefix) ? String(base.dropFirst(Self.cratePrefix.count)) : base
    }

    /// A copy that can sit beside your own squad without colliding.
    func asLANOpponent() -> Character {
        Character(
            id: Self.lanOpponentPrefix + baseID,
            name: name,
            colorHex: colorHex,
            rarity: rarity,
            statType: statType,
            isLocked: isLocked,
            foodGroup: foodGroup,
            isShiny: isShiny,
            starLevel: starLevel,
            bio: bio
        )
    }

    /// Clamps an arbitrary star count to the canonical 1..5 range.
    static func clampedStarLevel(_ value: Int) -> Int {
        min(max(value, 1), 5)
    }

    /// Cartoon sprite in `game-assets/`. Locked slots use the silhouette.
    var artworkAssetName: String? {
        if isLocked { return "unknown-characters" }
        return GameArt.sprite(id: baseID)
    }

    /// Server-generated anime art (GET /characters/:id/art, 302 → image
    /// service). Roster ids resolve directly; crate pulls strip their prefix
    /// to hit the roster id; scanned-food characters use the query endpoint.
    /// nil for locked placeholders — those stay procedural.
    var artworkRemoteURL: URL? {
        guard !isLocked else { return nil }
        let base = AppConfig.backendBaseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let id = baseID
        if id.hasPrefix("scan-") {
            var comps = URLComponents(string: "\(base)/characters/art")
            comps?.queryItems = [
                URLQueryItem(name: "name", value: name),
                URLQueryItem(name: "color", value: colorHex),
                URLQueryItem(name: "type", value: statType.rawValue),
                URLQueryItem(name: "rarity", value: rarity.rawValue)
            ]
            return comps?.url
        }
        return URL(string: "\(base)/characters/\(rosterID)/art")
    }
}

enum SampleData {
    static let characters: [Character] = [
        Character(id: "broccoli-bud", name: "Broccoli Bud", colorHex: "#5FCB82", rarity: .common, statType: .fiber),
        Character(id: "sushi-sam", name: "Sushi Sam", colorHex: "#56B8F5", rarity: .rare, statType: .protein),
        Character(id: "berry-belle", name: "Berry Belle", colorHex: "#F78FB3", rarity: .epic, statType: .vitamin),
        Character(id: "citrus-chip", name: "Citrus Chip", colorHex: "#FFB86B", rarity: .common, statType: .vitamin),
        Character(id: "grape-gus", name: "Grape Gus", colorHex: "#B892FF", rarity: .legendary, statType: .hydration),
        Character(id: "sprout-wisp", name: "Sprout Wisp", colorHex: "#8FE3A0", rarity: .common, statType: .fiber),
        Character(id: "locked-1", name: "???", colorHex: "#9C978F", rarity: .common, statType: .fiber, isLocked: true),
        Character(id: "locked-2", name: "???", colorHex: "#9C978F", rarity: .common, statType: .fiber, isLocked: true)
    ]
}
