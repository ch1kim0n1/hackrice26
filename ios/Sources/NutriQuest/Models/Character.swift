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
    /// Sprite/art lookup key from the master catalog — the checked-in asset
    /// name. nil for local placeholders, which fall back to the id.
    var imageKey: String? = nil
    var rarity: Rarity
    /// Source-neutral combat stats (final-dev-doc §2): the rolled instance's
    /// Health and Base Attack before rarity/star scaling, plus Mana on Epic+.
    /// Replaces the old power/guard/vitality/tempo blob and the element model.
    var baseHealth: Double = 100
    var baseAttack: Double = 50
    /// Mana pool — only Epic-and-higher instances carry Mana at all.
    var baseMana: Double? = nil
    var isLocked: Bool = false
    /// Mastery, ★1–★5 (Secret caps at ★2). Every monster starts at ★1;
    /// fusing raises it.
    var starLevel: Int = 1
    /// Pokédex entry, shown on the character sheet. Comes off the wire with a
    /// cookbook pull or scan mint (`flavor`/`bio`); nil for the starter
    /// roster, which `CharacterBios` fills in locally so the sheet reads the
    /// same offline.
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

    /// Cosmetic chest-badge category for the procedural chibi. Stat types are
    /// gone from the game itself — this stays only so `ChibiCharacterView`
    /// keeps a stable, varied glyph per character. Deterministic on the id,
    /// never sent to or decoded from the backend.
    var statType: StatType {
        let kinds = StatType.allCases
        let hash = baseID.utf8.reduce(5381) { ($0 &* 33) &+ Int($1) }
        return kinds[abs(hash) % kinds.count]
    }

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
            imageKey: imageKey,
            rarity: rarity,
            baseHealth: baseHealth,
            baseAttack: baseAttack,
            baseMana: baseMana,
            isLocked: isLocked,
            starLevel: starLevel,
            bio: bio
        )
    }

    /// Clamps an arbitrary star count to the canonical 1..5 range.
    static func clampedStarLevel(_ value: Int) -> Int {
        min(max(value, 1), 5)
    }

    /// Cartoon sprite in `game-assets/`. Locked slots use the silhouette.
    /// The catalog `imageKey` wins over the id — it names the checked-in
    /// asset directly.
    var artworkAssetName: String? {
        if isLocked { return "unknown-characters" }
        return GameArt.sprite(id: imageKey ?? baseID)
    }

    /// Server-generated anime art (GET /characters/:id/art, 302 → image
    /// service). Every minted monster is a catalog character now, so the
    /// roster id always resolves; crate pulls strip their prefix to hit it.
    /// nil for locked placeholders — those stay procedural.
    var artworkRemoteURL: URL? {
        guard !isLocked else { return nil }
        let base = AppConfig.backendBaseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return URL(string: "\(base)/characters/\(rosterID)/art")
    }
}

enum SampleData {
    // The backend starter six (data/sampleCharacters.ts) — the same catalog
    // characters with the same stats the server mints on first attach, so the
    // pre-sync collection renders exactly what the player actually owns.
    static let characters: [Character] = [
        Character(id: "broccoli-bud", name: "Broccoli Bud", colorHex: "#5FCB82", imageKey: "broccoli-bud", rarity: .common, baseHealth: 95, baseAttack: 42),
        Character(id: "bean-sprout", name: "Bean Sprout", colorHex: "#8FD16A", imageKey: "bean-sprout", rarity: .common, baseHealth: 85, baseAttack: 52),
        Character(id: "carrot-cadet", name: "Carrot Cadet", colorHex: "#F2913D", imageKey: "carrot-cadet", rarity: .common, baseHealth: 105, baseAttack: 44),
        Character(id: "water-droplet", name: "Water Droplet", colorHex: "#7CC5E8", imageKey: "water-droplet", rarity: .common, baseHealth: 90, baseAttack: 40),
        Character(id: "spinach-scout", name: "Spinach Scout", colorHex: "#3E9B5F", imageKey: "spinach-scout", rarity: .uncommon, baseHealth: 120, baseAttack: 46),
        Character(id: "almond-knight", name: "Almond Knight", colorHex: "#C08A5E", imageKey: "almond-knight", rarity: .rare, baseHealth: 95, baseAttack: 60),
        Character(id: "locked-1", name: "???", colorHex: "#9C978F", rarity: .common, isLocked: true),
        Character(id: "locked-2", name: "???", colorHex: "#9C978F", rarity: .common, isLocked: true)
    ]
}
