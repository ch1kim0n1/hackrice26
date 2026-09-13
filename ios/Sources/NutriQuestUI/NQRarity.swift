import SwiftUI

/// Character rarity. Drives Collection card outline color, independent of
/// ACTIVE/SUGGESTED state.
///
/// Seven tiers, matching `RARITY_TIERS` in backend/src/data/lootTable.ts. The
/// raw values are the backend's tier ids, so `NQRarity(rawValue:)` resolves a
/// loot drop directly instead of falling through to `.common`.
public enum NQRarity: String, CaseIterable, Sendable, Comparable {
    case common
    case uncommon
    case rare
    case epic
    case legendary
    case mythic
    case secret

    public var rank: Int {
        switch self {
        case .common: return 0
        case .uncommon: return 1
        case .rare: return 2
        case .epic: return 3
        case .legendary: return 4
        case .mythic: return 5
        case .secret: return 6
        }
    }

    public static func < (lhs: NQRarity, rhs: NQRarity) -> Bool {
        lhs.rank < rhs.rank
    }

    /// Outline color per the design system:
    /// grey / green / blue / purple / gold / red / cyan.
    public var outline: Color {
        switch self {
        case .common: return Color(hex: 0xB8CAD8)
        case .uncommon: return Color(hex: 0x4ADE80)
        case .rare: return NQTheme.info
        case .epic: return Color(hex: 0xB892FF)
        case .legendary: return NQTheme.gold
        case .mythic: return Color(hex: 0xFF9290)
        case .secret: return Color(hex: 0x22D3EE)
        }
    }

    /// Outline width per the design system (2 for common, 2.5 mid, 3 top tiers).
    public var outlineWidth: CGFloat {
        switch self {
        case .common, .uncommon: return 2
        case .rare: return 2.5
        case .epic, .legendary, .mythic, .secret: return 3
        }
    }

    /// Saturated gem color in a dark enamel badge.
    public var badgeBackground: Color { outline.mix(with: NQTheme.background, amount: 0.82) }

    public var badgeText: Color { outline }

    public var displayName: String {
        switch self {
        case .common: return "Common"
        case .uncommon: return "Uncommon"
        case .rare: return "Rare"
        case .epic: return "Epic"
        case .legendary: return "Legendary"
        case .mythic: return "Mythic"
        case .secret: return "Secret"
        }
    }
}

/// The stat specialty shown on a character's chest badge.
public enum NQStatType: String, CaseIterable, Sendable {
    case protein
    case fiber
    case vitamin
    case hydration

    /// SF Symbol fallback icon.
    public var symbol: String {
        switch self {
        case .protein: return "dumbbell.fill"
        case .fiber: return "leaf.fill"
        case .vitamin: return "star.fill"
        case .hydration: return "drop.fill"
        }
    }

    /// Kit vector icon.
    public var icon: NQIcon {
        switch self {
        case .protein: return .gym
        case .fiber: return .leaf
        case .vitamin: return .star
        case .hydration: return .droplet
        }
    }

    /// Display name.
    public var displayName: String {
        switch self {
        case .protein: return "Protein"
        case .fiber: return "Fiber"
        case .vitamin: return "Vitamin"
        case .hydration: return "Hydration"
        }
    }

    /// Badge tint per stat type (used when a character color is not applied).
    public var tint: Color {
        switch self {
        case .protein: return Color(hex: 0xFF9290)
        case .fiber: return Color(hex: 0x5FCB82)
        case .vitamin: return Color(hex: 0xFFC24B)
        case .hydration: return Color(hex: 0x56B8F5)
        }
    }
}
