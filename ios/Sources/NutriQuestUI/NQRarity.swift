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

// MARK: - Rarity reveal treatment

public extension NQRarity {
    /// Whether a pull at this tier is worth throwing confetti for.
    var deservesConfetti: Bool { self >= .legendary }
    /// Whether the card carries a moving shine.
    var deservesShine: Bool { self >= .rare }
    /// Whether the card sits in a halo of its own colour.
    var deservesGlow: Bool { self >= .epic }
    /// Secret is the one holographic tier in the system (design/README.md).
    var isHolographic: Bool { self == .secret }
}

/// One escalating visual treatment for a revealed reward, so a Legendary
/// never looks like a Common no matter which screen pulled it.
///
/// Before this existed every reveal screen decided for itself: the crate did
/// the full production, and the four wager games showed the same flat card at
/// every tier. The ladder is deliberately fixed here rather than per-screen —
/// that consistency *is* the feature.
///
/// | Tier | Treatment |
/// |---|---|
/// | Common / Uncommon | nothing — the ordinary result has to look ordinary |
/// | Rare | shine sweep |
/// | Epic | shine + coloured glow |
/// | Legendary / Mythic | shine + glow + confetti |
/// | Secret | all of it, plus the holographic sheen |
///
/// `trigger` drives the one-shot confetti: bump it at the moment of reveal.
/// Left at 0 the treatment is purely ambient, which is what a static card
/// (a Collection grid cell, say) wants.
public struct NQRarityTreatment: ViewModifier {
    private var rarity: NQRarity
    private var trigger: Int
    @State private var holoPhase: CGFloat = -1
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(rarity: NQRarity, trigger: Int = 0) {
        self.rarity = rarity
        self.trigger = trigger
    }

    public func body(content: Content) -> some View {
        content
            .nqShineSweep(active: rarity.deservesShine && !rarity.isHolographic)
            .modifier(HolographicSheen(active: rarity.isHolographic, phase: holoPhase))
            .background {
                if rarity.deservesGlow {
                    Circle()
                        .fill(rarity.outline.opacity(0.3))
                        .blur(radius: 26)
                        .padding(-10)
                        .allowsHitTesting(false)
                }
            }
            .overlay {
                if rarity.deservesConfetti && trigger > 0 {
                    NQConfetti(trigger: trigger)
                        .allowsHitTesting(false)
                }
            }
            .task(id: rarity.isHolographic) {
                guard rarity.isHolographic, !reduceMotion else { return }
                withAnimation(.linear(duration: 3.4).repeatForever(autoreverses: false)) {
                    holoPhase = 1
                }
            }
    }

    /// Iridescent band that slides across a Secret pull. A plain white shine
    /// reads as "shiny"; the hue shift is what reads as *holographic*.
    private struct HolographicSheen: ViewModifier {
        var active: Bool
        var phase: CGFloat
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        func body(content: Content) -> some View {
            content.overlay {
                if active && !reduceMotion {
                    GeometryReader { geo in
                        LinearGradient(
                            colors: [
                                .clear,
                                Color(hex: 0x22D3EE).opacity(0.55),
                                Color(hex: 0xB892FF).opacity(0.55),
                                Color(hex: 0xFF9290).opacity(0.45),
                                .clear
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                        .frame(width: geo.size.width * 0.75)
                        .offset(x: phase * geo.size.width * 1.7)
                        .blendMode(.plusLighter)
                        .allowsHitTesting(false)
                    }
                    .clipped()
                }
            }
        }
    }
}

public extension View {
    /// Apply the rarity reveal ladder. See `NQRarityTreatment`.
    func nqRarityTreatment(_ rarity: NQRarity, trigger: Int = 0) -> some View {
        modifier(NQRarityTreatment(rarity: rarity, trigger: trigger))
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
