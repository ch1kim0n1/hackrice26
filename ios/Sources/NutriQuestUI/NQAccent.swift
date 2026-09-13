import SwiftUI

/// How the app-wide accent color is chosen.
///
/// Adventure palette: the accent is no longer derived from the displayed character.
/// There is ONE command accent — gold — and every mode resolves to it. The mode is
/// kept because screens, tweak props and persisted state still carry it, and
/// because `.none` still means "empty squad" to the copy layer.
///
/// A character's own hue survives only inside its artwork:
/// `NQCharacterColor.base` (and the `art*` derivatives below), which
/// `ChibiCharacterView` draws with. Chrome, buttons, tabs, rings, banners and
/// washes all read the fixed gold ramp.
public enum NQAccentMode: String, CaseIterable, Sendable {
    case active
    case bestUnselected
    case none
}

/// A character's identity color + the app accent palette.
public struct NQCharacterColor: Sendable, Equatable {
    public var name: String
    /// The character's own hue. Artwork only — never chrome.
    public var base: Color

    public init(name: String, hex: UInt32) {
        self.name = name
        self.base = Color(hex: hex)
    }

    public init(name: String, base: Color) {
        self.name = name
        self.base = base
    }

    // MARK: App accent — fixed, character-independent.

    public var accentBg: Color { NQTheme.accentBg }
    public var accentSoft: Color { NQTheme.accentSoft }
    public var accent: Color { NQTheme.accent }
    public var accentDark: Color { NQTheme.accentDark }

    // MARK: Character artwork tints — the only place `base` still spreads.

    /// Mid-tone fill for the character's body.
    public var artFill: Color { base.characterDerivative(satCap: nil, lightness: 58) }
    /// Deeper edge/shade tone inside the artwork.
    public var artShade: Color { base.characterDerivative(satCap: nil, lightness: 36) }
    /// Pale tone for highlights inside the artwork.
    public var artSoft: Color { base.characterDerivative(satCap: 55, lightness: 90) }
}

// MARK: - HSL derivation (character artwork only)

private extension Color {
    /// HSL (h: 0-360, s/l: 0-100) of this color in sRGB.
    var hsl: (h: Double, s: Double, l: Double) {
        let (r, g, b) = components
        let maxV = max(r, g, b), minV = min(r, g, b)
        let l = (maxV + minV) / 2
        guard maxV != minV else { return (0, 0, l * 100) }
        let d = maxV - minV
        let s = l > 0.5 ? d / (2 - maxV - minV) : d / (maxV + minV)
        var h: Double
        if maxV == r { h = (g - b) / d + (g < b ? 6 : 0) }
        else if maxV == g { h = (b - r) / d + 2 }
        else { h = (r - g) / d + 4 }
        return (h / 6 * 360, s * 100, l * 100)
    }

    /// Same hue, saturation floored at 45 and optionally capped, new lightness.
    func characterDerivative(satCap: Double?, lightness: Double) -> Color {
        let (h, s, _) = hsl
        let sat = min(max(s, 45), satCap ?? 100)
        return Color(h: h, s: sat, l: lightness)
    }
}

extension Color {
    /// Creates a Color from HSL values (h: 0-360, s/l: 0-100), matching the
    /// design system's hslStr() convention (CSS hsl(), distinct from SwiftUI's HSB init).
    public init(h: Double, s: Double, l: Double) {
        let s = max(0, min(100, s)) / 100
        let l = max(0, min(100, l)) / 100
        let c = (1 - abs(2 * l - 1)) * s
        let hPrime = h.truncatingRemainder(dividingBy: 360) / 60
        let x = c * (1 - abs(hPrime.truncatingRemainder(dividingBy: 2) - 1))
        let m = l - c / 2
        let rgb: (Double, Double, Double)
        switch hPrime {
        case 0..<1: rgb = (c, x, 0)
        case 1..<2: rgb = (x, c, 0)
        case 2..<3: rgb = (0, c, x)
        case 3..<4: rgb = (0, x, c)
        case 4..<5: rgb = (x, 0, c)
        default:    rgb = (c, 0, x)
        }
        self.init(red: rgb.0 + m, green: rgb.1 + m, blue: rgb.2 + m)
    }
}

/// Resolved accent context injected into the environment.
public struct NQAccentContext: Sendable, Equatable {
    public var mode: NQAccentMode
    public var character: NQCharacterColor?

    public init(mode: NQAccentMode, character: NQCharacterColor?) {
        self.mode = mode
        self.character = character
    }

    /// Neutral fallback — used when mode is `.none` or character is nil.
    /// The accent ramp is identical either way; only `base` (artwork) differs.
    public static let neutral = NQAccentContext(
        mode: .none,
        character: NQCharacterColor(name: "Neutral", hex: 0x8A8A8A)
    )

    public var isActive: Bool { mode == .active }
    public var isBestUnselected: Bool { mode == .bestUnselected }
    public var isNone: Bool { mode == .none }

    public var accentBg: Color { NQTheme.accentBg }
    public var accentSoft: Color { NQTheme.accentSoft }
    public var accent: Color { NQTheme.accent }
    public var accentDark: Color { NQTheme.accentDark }
}

// MARK: - Environment

private struct NQAccentKey: EnvironmentKey {
    static let defaultValue = NQAccentContext.neutral
}

public extension EnvironmentValues {
    /// Read the resolved accent anywhere: `@Environment(\.nqAccent) var accent`
    var nqAccent: NQAccentContext {
        get { self[NQAccentKey.self] }
        set { self[NQAccentKey.self] = newValue }
    }
}

public extension View {
    /// Inject the app-wide accent. Call once at the root, near the top of the
    /// hierarchy, recomputed whenever the displayed character changes.
    func nqAccentContext(_ context: NQAccentContext) -> some View {
        environment(\.nqAccent, context)
    }
}

// MARK: - Preset character colors (artwork palette)

public extension NQCharacterColor {
    static let mint = NQCharacterColor(name: "Mint", hex: 0x5FCB82)
    static let sky = NQCharacterColor(name: "Sky", hex: 0x56B8F5)
    static let blossom = NQCharacterColor(name: "Blossom", hex: 0xF78FB3)
    static let peach = NQCharacterColor(name: "Peach", hex: 0xFFB86B)
    static let lilac = NQCharacterColor(name: "Lilac", hex: 0xB892FF)
    static let lime = NQCharacterColor(name: "Lime", hex: 0x8FE3A0)
}
