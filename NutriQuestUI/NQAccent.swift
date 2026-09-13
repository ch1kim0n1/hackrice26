import SwiftUI

/// How the app-wide accent color is chosen, per the design system:
/// - `.active`: light tint of the currently selected character's color
/// - `.bestUnselected`: no character selected — fall back to the best owned character
/// - `.none`: no characters owned — neutral grey
public enum NQAccentMode: String, CaseIterable, Sendable {
    case active
    case bestUnselected
    case none
}

/// A character's identity color + the accent palette derived from it.
public struct NQCharacterColor: Sendable, Equatable {
    public var name: String
    public var base: Color

    public init(name: String, hex: UInt32) {
        self.name = name
        self.base = Color(hex: hex)
    }

    public init(name: String, base: Color) {
        self.name = name
        self.base = base
    }

    /// The palette every screen reads. All accents derive from `base`:
    /// bg = 90% toward white, soft = 75%, accent = the base itself,
    /// dark = 25% toward black (badges, mascot shading).
    public var accentBg: Color { base.tinted(0.90) }
    public var accentSoft: Color { base.tinted(0.72) }
    public var accent: Color { base }
    public var accentDark: Color { base.darkened(0.25) }
}

/// Resolved accent context injected into the environment.
public struct NQAccentContext: Sendable, Equatable {
    public var mode: NQAccentMode
    public var character: NQCharacterColor?

    public init(mode: NQAccentMode, character: NQCharacterColor?) {
        self.mode = mode
        self.character = character
    }

    /// Neutral fallback (grey) — used when mode is `.none` or character is nil.
    public static let neutral = NQAccentContext(
        mode: .none,
        character: NQCharacterColor(name: "Neutral", hex: 0x9C978F)
    )

    public var isActive: Bool { mode == .active }
    public var isBestUnselected: Bool { mode == .bestUnselected }
    public var isNone: Bool { mode == .none }

    public var accentBg: Color { character?.accentBg ?? NQAccentContext.neutral.character!.accentBg }
    public var accentSoft: Color { character?.accentSoft ?? NQAccentContext.neutral.character!.accentSoft }
    public var accent: Color { character?.accent ?? NQAccentContext.neutral.character!.accent }
    public var accentDark: Color { character?.accentDark ?? NQAccentContext.neutral.character!.accentDark }
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
    ///
    ///     rootView.nqAccentContext(
    ///         NQAccentContext(mode: .active, character: activeCharacter.color)
    ///     )
    func nqAccentContext(_ context: NQAccentContext) -> some View {
        environment(\.nqAccent, context)
    }
}

// MARK: - Preset character colors (from the design system)

public extension NQCharacterColor {
    static let mint = NQCharacterColor(name: "Mint", hex: 0x5FCB82)
    static let sky = NQCharacterColor(name: "Sky", hex: 0x56B8F5)
    static let blossom = NQCharacterColor(name: "Blossom", hex: 0xF78FB3)
    static let peach = NQCharacterColor(name: "Peach", hex: 0xFFB86B)
    static let lilac = NQCharacterColor(name: "Lilac", hex: 0xB892FF)
    static let lime = NQCharacterColor(name: "Lime", hex: 0x8FE3A0)
}
