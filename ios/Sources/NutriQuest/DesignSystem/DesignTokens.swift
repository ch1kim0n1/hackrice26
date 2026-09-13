import SwiftUI

/// How the app-wide accent color is currently sourced. Mirrors the three
/// states from the design system:
///   .active         -> a character is selected; accent = that character's color
///   .bestUnselected -> characters are owned, none selected; accent = best owned character's color
///   .none           -> no characters owned yet; accent = neutral grey
///
/// The resolved palette lives in the kit: `NQAccentContext`, injected at the
/// root via `.nqAccentContext(...)` and read anywhere with
/// `@Environment(\.nqAccent)`. All fixed colors/typography live in the kit's
/// `NQTheme` / `NQText`.
enum ColorMode: String, Codable {
    case active
    case bestUnselected
    case none
}
