import SwiftUI

/// Drives a Collection card's outline color, independent of ACTIVE/SUGGESTED state.
///
/// Seven tiers, matching `RARITY_TIERS` in backend/src/data/lootTable.ts and
/// `BattleRarity` in BattleKit. The raw values are the backend's tier ids, so a
/// loot drop decodes straight into this enum -- previously `uncommon`, `mythic`
/// and `secret` had nowhere to land and were collapsed into neighbouring tiers,
/// which meant a Secret pull displayed as Common.
///
/// Colors and names delegate to `kitRarity` (NQRarity) so the design system
/// owns the palette; `Comparable` forwards to the same rank so an eighth tier
/// cannot silently fall out of ordinal comparisons.
enum Rarity: String, Codable, CaseIterable, Comparable {
    case common, uncommon, rare, epic, legendary, mythic, secret

    /// Ascending scarcity, forwarded from NQRarity so both enums share one
    /// ordering.
    var rank: Int { kitRarity.rank }

    static func < (lhs: Rarity, rhs: Rarity) -> Bool { lhs.rank < rhs.rank }

    var label: String {
        kitRarity.displayName
    }

    var badgeBackground: Color {
        kitRarity.badgeBackground
    }

    var badgeText: Color {
        kitRarity.badgeText
    }

    var ringColor: Color { kitRarity.outline }

    var ringWidth: CGFloat { kitRarity.outlineWidth }

    /// Extra glow layered under the card for the showier tiers.
    var glow: (color: Color, radius: CGFloat)? {
        switch self {
        case .epic: return (kitRarity.outline.opacity(0.18), 3)
        case .legendary: return (kitRarity.outline.opacity(0.22), 4)
        case .mythic: return (kitRarity.outline.opacity(0.26), 5)
        case .secret: return (kitRarity.outline.opacity(0.30), 6)
        default: return nil
        }
    }
}
