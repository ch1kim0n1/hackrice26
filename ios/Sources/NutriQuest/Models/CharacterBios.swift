import Foundation

/// Pokédex copy for the characters the app ships with, and the fallback line
/// for the ones it mints at runtime.
///
/// The backend owns the authored bios for its own roster — `GET
/// /characters/catalog` for the full entries, `flavor` on every drop payload
/// for the one-liner. This table covers the starter roster, which is local and
/// has to read the same with the network down.
enum CharacterBios {
    /// Keyed by roster id, matching `SampleData.characters`.
    private static let starterRoster: [String: String] = [
        "broccoli-bud": "Turns up to every meal early and leaves last. Bud has never won a fight quickly, and has never needed to.",
        "sushi-sam": "Precise down to the grain of rice. Sam rearranges the squad before every battle and is quietly furious when nobody notices.",
        "berry-belle": "Sweet for the first round and considerably less so by the third. Belle keeps a chart of everyone she has stained.",
        "citrus-chip": "Loud, sharp, and gone in a second. Chip has never finished a sentence or lost an argument.",
        "grape-gus": "Travels as a crowd and will not say which one of them is Gus. The squad has stopped asking.",
        "sprout-wisp": "Two days old and already the first one awake. Wisp is certain it will be enormous, and is not entirely wrong."
    ]

    /// The bio to show on a character's sheet.
    /// - Parameters:
    ///   - character: The card that was pressed.
    ///   - catalog: Authored bios fetched from the backend, keyed by roster id.
    ///     Preferred over everything else — it is the source of truth, and the
    ///     full paragraph rather than the one-line flavour a drop carries.
    /// - Returns: The bio, or nil for a locked character: there is nothing to
    ///   tell about one you have not found.
    static func bio(for character: Character, catalog: [String: String] = [:]) -> String? {
        guard !character.isLocked else { return nil }
        if let authored = catalog[character.rosterID], !authored.isEmpty { return authored }
        if let carried = character.bio, !carried.isEmpty { return carried }
        if let starter = starterRoster[character.rosterID] { return starter }
        return summonedBio(for: character)
    }

    /// Characters minted from a scan are named after whatever food produced
    /// them, so no bio can be written for them in advance. Say what is
    /// actually known rather than inventing a history.
    private static func summonedBio(for character: Character) -> String {
        "A \(character.rarity.label.lowercased()) \(character.statType.label.lowercased()) type you summoned yourself. "
            + "No field notes on this one yet — take it into a battle and write some."
    }
}
