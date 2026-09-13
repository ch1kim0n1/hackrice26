import SwiftUI

/// NutriQuest design tokens — the single source of truth for the visual language.
/// White-first base; every accent is derived from the displayed character's color.
/// Components must consume tokens only — no raw sizes, colors, or paddings.
public enum NQTheme {

    // MARK: Core palette (fixed)

    /// Warm dark brown — primary text and icon color.
    public static let ink = Color(hex: 0x3A342E)
    /// Emphasized body text (banners, subtitles).
    public static let inkSubtle = Color(hex: 0x5B564E)
    /// Deepest ink — mascot pupils, outlines on accent fills.
    public static let inkDeep = Color(hex: 0x2B2620)
    /// Secondary text.
    public static let inkMuted = Color(hex: 0x8A857C)
    /// Tertiary / placeholder text.
    public static let inkFaint = Color(hex: 0xB9B4AC)
    /// App background — pure white.
    public static let background = Color(hex: 0xFFFFFF)
    /// Card / section tint.
    public static let surface = Color(hex: 0xFAFAF8)
    /// Hairline borders.
    public static let hairline = Color(hex: 0xEFEDE9)
    /// Locked / disabled fill.
    public static let lockedFill = Color(hex: 0xC9C4BB)

    // MARK: Semantic accents (fixed, independent of character)

    public static let flame = Color(hex: 0xFF9F5A)   // streaks, energy
    public static let gold = Color(hex: 0xFFC24B)    // legendary, rewards
    public static let blush = Color(hex: 0xFF9F9F)   // cheeks, hearts
    public static let success = Color(hex: 0x5FCB82)
    public static let info = Color(hex: 0x56B8F5)
    public static let warning = Color(hex: 0xE2765F)

    // MARK: Spacing scale

    public static let spaceXS: CGFloat = 4
    public static let spaceS: CGFloat = 8
    public static let spaceM: CGFloat = 14
    public static let spaceL: CGFloat = 20
    public static let spaceXL: CGFloat = 32

    // MARK: Radii scale

    public static let radiusXS: CGFloat = 6
    public static let radiusS: CGFloat = 10
    public static let radiusM: CGFloat = 16
    public static let radiusL: CGFloat = 20
    public static let radiusXL: CGFloat = 24
    public static let radiusPill: CGFloat = 999
}

// MARK: - Type scale
//
// One scale, eleven steps. Every text in the app uses one of these —
// never a raw size.

public enum NQText {
    case displayL    // 26 — summon / celebration titles
    case display     // 21 — top bar wordmark
    case headingL    // 17 — section headers
    case heading     // 15 — buttons, card titles
    case bodyL       // 13.5 — empty-state copy
    case body        // 13 — banners, streak counts
    case caption     // 12 — card metadata
    case captionS    // 11.5 — chips
    case micro       // 10 — tiny labels
    case microS      // 9 — ribbons
    case microXS     // 8 — fine print

    public var size: CGFloat {
        switch self {
        case .displayL: return 26
        case .display: return 21
        case .headingL: return 17
        case .heading: return 15
        case .bodyL: return 13.5
        case .body: return 13
        case .caption: return 12
        case .captionS: return 11.5
        case .micro: return 10
        case .microS: return 9
        case .microXS: return 8
        }
    }

    /// The Dynamic Type style each step scales relative to.
    public var textStyle: Font.TextStyle {
        switch self {
        case .displayL: return .largeTitle
        case .display: return .title
        case .headingL: return .title2
        case .heading: return .title3
        case .bodyL, .body: return .footnote
        case .caption: return .caption
        case .captionS, .micro, .microS, .microXS: return .caption2
        }
    }

    /// Resolved SwiftUI font with the correct family + weight.
    /// Uses `relativeTo` so every text scales with the user's Dynamic Type
    /// setting; when the TTFs are not bundled the fallback system font
    /// still scales.
    public var font: Font {
        switch self {
        case .displayL, .display, .headingL, .heading:
            return .custom("Baloo 2", size: size, relativeTo: textStyle)
                .weight(size >= 17 ? .heavy : .bold)
        case .bodyL, .body, .caption, .captionS:
            return .custom("Quicksand", size: size, relativeTo: textStyle).weight(.semibold)
        case .micro, .microS, .microXS:
            return .system(.caption2, design: .rounded).weight(.heavy)
        }
    }
}

/// Legacy entry point kept for call sites that need a custom size
/// (e.g. scaled variants). Prefer `NQText`.
public enum NQFont {
    case display, heading, body, caption, micro

    public func font(_ size: CGFloat) -> Font {
        switch self {
        case .display: return .custom("Baloo 2", size: size, relativeTo: .largeTitle).weight(.heavy)
        case .heading: return .custom("Baloo 2", size: size, relativeTo: .title3).weight(.bold)
        case .body: return .custom("Quicksand", size: size, relativeTo: .footnote).weight(.semibold)
        case .caption: return .custom("Quicksand", size: size, relativeTo: .caption).weight(.medium)
        case .micro: return .system(.caption2, design: .rounded).weight(.heavy)
        }
    }
}

// MARK: - Shadow scale

public enum NQShadowLevel {
    case none       // flat elements
    case soft       // banners, small cards
    case card       // standard cards, pills
    case raised     // character cards, modals
    case nav        // bottom nav (upward)
    case glow(Color) // colored glow (selection, beams)

    var radius: CGFloat {
        switch self {
        case .none: return 0
        case .soft: return 6
        case .card: return 8
        case .raised: return 12
        case .nav: return 14
        case .glow: return 10
        }
    }

    var y: CGFloat {
        switch self {
        case .none: return 0
        case .soft: return 2
        case .card: return 2
        case .raised: return 4
        case .nav: return -4
        case .glow: return 0
        }
    }

    var color: Color {
        switch self {
        case .none: return .clear
        case .soft: return NQTheme.ink.opacity(0.06)
        case .card: return NQTheme.ink.opacity(0.08)
        case .raised: return NQTheme.ink.opacity(0.10)
        case .nav: return NQTheme.ink.opacity(0.10)
        case .glow(let c): return c.opacity(0.55)
        }
    }
}

public extension View {
    /// The only way to apply shadows — keeps elevation consistent app-wide.
    func nqElevation(_ level: NQShadowLevel) -> some View {
        switch level {
        case .none:
            return AnyView(self)
        case .glow:
            return AnyView(self.shadow(color: level.color, radius: level.radius))
        default:
            return AnyView(self.shadow(color: level.color, radius: level.radius, y: level.y))
        }
    }
}

// MARK: - Padding scale

public enum NQPaddingSet {
    case chip        // h 10, v 5
    case badge       // h 8, v 3
    case banner      // h 17, v 11
    case card        // 14 all
    case button      // h 20, v 12
    case screen      // h 20
    case nav         // v 10

    var horizontal: CGFloat {
        switch self {
        case .chip: return 10
        case .badge: return 8
        case .banner: return 17
        case .card: return 14
        case .button: return 20
        case .screen: return 20
        case .nav: return 0
        }
    }

    var vertical: CGFloat {
        switch self {
        case .chip: return 5
        case .badge: return 3
        case .banner: return 11
        case .card: return 14
        case .button: return 12
        case .screen: return 0
        case .nav: return 10
        }
    }
}

public extension View {
    /// The only way to apply component padding — keeps rhythm consistent.
    func nqPadding(_ set: NQPaddingSet) -> some View {
        padding(.horizontal, set.horizontal)
            .padding(.vertical, set.vertical)
    }
}

// MARK: - Color helpers

public extension Color {
    init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }

    /// Mix toward white. `amount` 0 = unchanged, 1 = white.
    func tinted(_ amount: Double) -> Color {
        mix(with: .white, amount: amount)
    }

    /// Mix toward black. `amount` 0 = unchanged, 1 = black.
    func darkened(_ amount: Double) -> Color {
        mix(with: .black, amount: amount)
    }

    func mix(with other: Color, amount: Double) -> Color {
        let a = components, b = other.components
        return Color(
            red: a.r + (b.r - a.r) * amount,
            green: a.g + (b.g - a.g) * amount,
            blue: a.b + (b.b - a.b) * amount
        )
    }

    /// WCAG relative luminance (sRGB).
    func luminance() -> Double {
        func lin(_ c: Double) -> Double { c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        let (r, g, b) = components
        return 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b)
    }

    /// WCAG contrast ratio against another color (1...21).
    func contrast(with other: Color) -> Double {
        let l1 = luminance(), l2 = other.luminance()
        return (max(l1, l2) + 0.05) / (min(l1, l2) + 0.05)
    }

    /// White or ink — whichever has the higher contrast on this color.
    /// Use for text/icons over accent fills (buttons, ribbons, badges).
    func readableTextColor() -> Color {
        contrast(with: .white) >= contrast(with: NQTheme.ink) ? .white : NQTheme.ink
    }

    var components: (r: Double, g: Double, b: Double) {
        #if canImport(UIKit)
        let ui = UIColor(self)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, alpha: CGFloat = 0
        ui.getRed(&r, green: &g, blue: &b, alpha: &alpha)
        return (r, g, b)
        #elseif canImport(AppKit)
        let ns = NSColor(self)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, alpha: CGFloat = 0
        ns.usingColorSpace(.sRGB)?.getRed(&r, green: &g, blue: &b, alpha: &alpha)
        return (r, g, b)
        #else
        return (0, 0, 0)
        #endif
    }
}
