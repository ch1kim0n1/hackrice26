import SwiftUI
import UIKit

/// Creature-adventure palette: ocean blue menus, warm ivory lettering,
/// golden actions and bright elemental colors. Kept stable in both system
/// appearances so game surfaces and native chrome share one visual world.
public enum NQTheme {
    // MARK: Lettering
    public static let ink = Color(hex: 0xFFF5DA)
    public static let inkSubtle = Color(hex: 0xD6E6EF)
    public static let inkDeep = Color(hex: 0x071B32)
    public static let inkMuted = Color(hex: 0xBDD5E7)
    public static let inkFaint = Color(hex: 0xB2CDDF)
    public static let inkRule = Color(hex: 0x6FA6DA)

    // MARK: Cartoon-blue game surfaces
    public static let background = Color(hex: 0x2C6AC4)
    public static let page = Color(hex: 0x17479A)
    public static let surface = Color(hex: 0x3A7BD4)
    public static let hairline = Color(hex: 0x62A0E0)
    public static let track = Color(hex: 0x0F2E66)
    public static let chrome = Color(hex: 0x0C2656)
    public static let lockedFill = Color(hex: 0x40679C)
    public static let scrim = Color(hex: 0x061634).opacity(0.72)
    public static let sky = Color(hex: 0x38B4F5)
    public static let frameHighlight = Color(hex: 0xA8DAFF)

    // MARK: Golden command buttons
    public static let accent = Color(hex: 0xFFCC2E)
    public static let accentPress = Color(hex: 0xF5A91C)
    /// Bright enough for text and icons on blue panels.
    public static let accentDark = Color(hex: 0xFFE27A)
    public static let accentSoft = Color(hex: 0x5A5230)
    public static let accentBg = page

    // MARK: Elemental colors
    public static let protein = Color(hex: 0xFF6B6B)
    public static let carbs = Color(hex: 0xFFC93C)
    public static let fat = Color(hex: 0x5CB0FF)
    public static let calories = ink
    public static let fibre = Color(hex: 0x4FE39C)
    public static let water = Color(hex: 0x3FDDF2)
    public static let leaf = Color(hex: 0x4FE39C)
    public static let leafSoft = Color(hex: 0x1F7A5C)
    public static let teal = Color(hex: 0x3FDDF2)
    public static let plum = Color(hex: 0xB48CFF)

    // MARK: Status and rewards
    public static let success = Color(hex: 0x4FE39C)
    public static let warning = Color(hex: 0xFF7A7A)
    public static let error = warning
    public static let caution = Color(hex: 0xFFCC2E)
    public static let info = Color(hex: 0x5CB0FF)
    public static let flame = Color(hex: 0xFF9442)
    public static let gold = Color(hex: 0xFFCC2E)
    public static let blush = Color(hex: 0xFF8FBE)

    // MARK: Battle surfaces
    public static let battleBg = Color(hex: 0x0C2656)
    public static let battleSurface = Color(hex: 0x2C6AC4)
    public static let battleHairline = hairline
    public static let battleInk = ink
    public static let battleInkMuted = inkMuted
    public static let battleRival = Color(hex: 0xFF9290)

    // MARK: Spacing scale

    public static let spaceXS: CGFloat = 4
    public static let spaceS: CGFloat = 8
    public static let spaceM: CGFloat = 14
    public static let spaceL: CGFloat = 20
    public static let spaceXL: CGFloat = 32

    // MARK: Radii scale

    public static let radiusXS: CGFloat = 6
    public static let radiusS: CGFloat = 12
    public static let radiusM: CGFloat = 16
    public static let radiusL: CGFloat = 22
    public static let radiusXL: CGFloat = 28
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
    case bodyL       // 13 — empty-state copy
    case body        // 13 — banners, streak counts
    case caption     // 12 — card metadata
    case captionS    // 12 — chips
    case tagBold     // 12 — small cartoony tags: rarity/type chips
    case micro       // 10 — tiny labels
    case microS      // 10 — ribbons
    case microXS     // 10 — fine print

    public var size: CGFloat {
        switch self {
        case .displayL: return 30
        case .display: return 24
        case .headingL: return 18
        case .heading: return 16
        case .bodyL: return 13
        case .body: return 13
        case .caption: return 12
        case .captionS: return 12
        case .tagBold: return 12
        case .micro: return 10
        case .microS: return 10
        case .microXS: return 10
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
        case .captionS, .tagBold, .micro, .microS, .microXS: return .caption2
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
        case .tagBold:
            // Baloo 2 at chip scale: a rarity or type tag reads as the same
            // cartoony lettering as a card title, just smaller — and heavy,
            // not merely bold, so it doesn't read as an afterthought.
            return .custom("Baloo 2", size: size, relativeTo: textStyle).weight(.heavy)
        case .bodyL, .body, .caption, .captionS:
            // Variable file registers family "Quicksand Light" (typographic family
            // "Quicksand"). Ask for the registered family or body silently
            // falls back to SF.
            return .custom("Quicksand Light", size: size, relativeTo: textStyle).weight(.semibold)
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
        case .body: return .custom("Quicksand Light", size: size, relativeTo: .footnote).weight(.semibold)
        case .caption: return .custom("Quicksand Light", size: size, relativeTo: .caption).weight(.medium)
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
    case sticker    // die-cut: hard offset, no blur
    case nav        // bottom nav (upward)
    case glow(Color) // colored glow (selection, beams)

    var radius: CGFloat {
        switch self {
        case .none: return 0
        case .soft: return 2
        case .card: return 3
        case .raised: return 8
        case .sticker: return 0
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
        case .sticker: return 6
        case .nav: return -4
        case .glow: return 0
        }
    }

    var color: Color {
        switch self {
        case .none: return .clear
        // Shadows stay black-based in both modes — a "light" shadow in dark
        // mode reads as a glow artifact.
        case .soft: return NQTheme.inkDeep.opacity(0.3)
        case .card: return NQTheme.inkDeep.opacity(0.4)
        case .raised: return NQTheme.inkDeep.opacity(0.5)
        case .sticker: return NQTheme.inkDeep.opacity(0.8)
        case .nav: return Color.black.opacity(0.16)
        case .glow(let c): return c.opacity(0.55)
        }
    }
}

public extension View {
    /// Applies a drop shadow to the entire view, including any text inside it.
    /// Prefer `nqPlate` for cards and pills so foreground text stays flat.
    func nqElevation(_ level: NQShadowLevel) -> some View {
        switch level {
        case .none:
            return AnyView(self)
        case .glow:
            return AnyView(self.shadow(color: level.color, radius: level.radius))
        case .raised:
            // A single shadow reads as a blurred outline. Stacking a tight
            // contact shadow under a softer, larger ambient one is what
            // actually reads as a card lifted off the page — the same pairing
            // real elevation always is, one shadow close and sharp, one far
            // and soft.
            return AnyView(
                self
                    .shadow(color: Color.black.opacity(0.05), radius: 2, y: 1)
                    .shadow(color: level.color, radius: level.radius, y: level.y)
            )
        default:
            return AnyView(self.shadow(color: level.color, radius: level.radius, y: level.y))
        }
    }

    /// Filled plate behind the content — elevation sits on the shape only,
    /// so labels and headlines render without a drop shadow.
    func nqPlate<S: InsettableShape>(
        _ shape: S,
        fill: Color = NQTheme.background,
        elevation: NQShadowLevel = .sticker,
        inkStroke: Bool = false,
        lineWidth: CGFloat = 2
    ) -> some View {
        background {
            shape.fill(fill)
                .overlay {
                    shape.fill(LinearGradient(
                        colors: [.white.opacity(0.16), .clear],
                        startPoint: .top, endPoint: .bottom
                    ))
                }
                .nqElevation(elevation)
        }
        .overlay {
            if inkStroke {
                shape.strokeBorder(NQTheme.inkDeep, lineWidth: lineWidth + 3)
                shape.inset(by: lineWidth + 3)
                    .strokeBorder(NQTheme.frameHighlight.opacity(0.6), lineWidth: 1.5)
            }
        }
    }

    /// Coloring-book edge. Pair with `nqPlate` for die-cut chrome.
    func nqInkStroke<S: InsettableShape>(_ shape: S, lineWidth: CGFloat = 2) -> some View {
        overlay { shape.strokeBorder(NQTheme.inkDeep, lineWidth: lineWidth) }
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

// MARK: - Layout scale
//
// Named values for the handful of measurements that are not component
// padding: screen gutters, the gaps between things, and the sizes controls
// and glyphs come in. These exist so call sites stop writing arithmetic on
// the spacing scale (`spaceM - 2`, `spaceXL - 8`), which is how a rhythm
// quietly drifts out of step screen by screen.

public enum NQLayout {
    /// Horizontal inset from the screen edge. Every screen uses this one.
    public static let screenGutter: CGFloat = NQTheme.spaceL
    /// Between cards inside the same section.
    public static let cardGap: CGFloat = NQTheme.spaceM
    /// Between one section and the next.
    public static let sectionGap: CGFloat = NQTheme.spaceL
    /// Clearance around a screen's hero element — the air that makes it read
    /// as the hero rather than the first card.
    public static let heroAir: CGFloat = NQTheme.spaceXL
    /// Minimum tap target, per the HIG.
    public static let controlMinHeight: CGFloat = 44
    /// Divider / border weight. One weight, everywhere.
    public static let hairlineWidth: CGFloat = 1.5

    public static let heroNumberSize: CGFloat = 44
    public static let crestSize: CGFloat = 56
    public static let mealMascotSize: CGFloat = 76
    public static let scannerIdleHeight: CGFloat = 150
    public static let scannerActiveHeight: CGFloat = 300

    // Glyph sizes. Icons are the one place a raw point size is allowed, and
    // only from this set.
    public static let iconXS: CGFloat = 12
    public static let iconS: CGFloat = 14
    public static let iconM: CGFloat = 16
    public static let iconL: CGFloat = 20
    public static let iconXL: CGFloat = 24
}

// MARK: - Surfaces
//
// Every container in the app is one of these. A surface bundles the three
// things that were previously chosen independently at each call site —
// corner radius, fill, and elevation — so a card cannot end up with a
// tile's radius and a hero's shadow.
//
// Framed top-level menus have a dark outer edge and a fine blue bevel.
// Nested panels stay quieter so information remains easy to read.

public enum NQSurfaceStyle {
    /// The one raised surface on a screen: the hero. Two-layer shadow.
    case hero
    /// Standard content card — die-cut sticker with an ink edge.
    case sticker
    /// Quieter card, for surfaces nested inside another one.
    case card
    /// Small tile or list container.
    case tile
    /// Banner / inline notice.
    case banner
    /// Flat surface: fill and radius only, no depth.
    case flush

    public var radius: CGFloat {
        switch self {
        case .hero: return NQTheme.radiusXL
        case .sticker, .card: return NQTheme.radiusL
        case .tile, .banner, .flush: return NQTheme.radiusM
        }
    }

    public var elevation: NQShadowLevel {
        switch self {
        case .hero: return .raised
        case .sticker: return .sticker
        case .card, .tile: return .soft
        case .banner: return .soft
        case .flush: return .none
        }
    }

    /// Hero and standard panels carry the double game-menu frame.
    public var strokesInk: Bool {
        switch self {
        case .sticker, .hero: return true
        default: return false
        }
    }
}

public extension View {
    /// Draws this content on a standard surface. Prefer it over hand-rolling
    /// `background` + `clipShape` + `shadow`, so radius and depth stay paired.
    func nqSurface(_ style: NQSurfaceStyle = .sticker, fill: Color = NQTheme.background) -> some View {
        nqPlate(
            NQPanelShape(cut: style.radius * 0.6),
            fill: fill,
            elevation: style.elevation,
            inkStroke: style.strokesInk,
            lineWidth: NQLayout.hairlineWidth
        )
        .overlay {
            if style.strokesInk { NQPanelCorners() }
        }
    }

    /// The illustrated-map ground shared by adventure screens.
    func nqPageBackground() -> some View {
        modifier(NQPageBackground())
    }
}

/// Reads the accent from the environment so a screen never spells the page
/// colour out itself.
public struct NQPageBackground: ViewModifier {
    public func body(content: Content) -> some View {
        content.background { NQAdventureBackdrop().ignoresSafeArea() }
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
        contrast(with: .white) >= contrast(with: NQTheme.inkDeep) ? .white : NQTheme.inkDeep
    }

    var components: (r: Double, g: Double, b: Double) {
        #if canImport(UIKit)
        let traits = UITraitCollection(traitsFrom: [
            UITraitCollection(userInterfaceStyle: .light),
            UITraitCollection(displayGamut: .SRGB)
        ])
        let ui = UIColor(self).resolvedColor(with: traits)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, alpha: CGFloat = 0
        if ui.getRed(&r, green: &g, blue: &b, alpha: &alpha) {
            return (Double(r), Double(g), Double(b))
        }
        var white: CGFloat = 0
        ui.getWhite(&white, alpha: &alpha)
        return (Double(white), Double(white), Double(white))
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

// MARK: - UIColor helper (dynamic provider needs UIColor, not Color)

import UIKit

extension UIColor {
    convenience init(hex: UInt32) {
        self.init(
            red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}
