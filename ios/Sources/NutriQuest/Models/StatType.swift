import SwiftUI

/// The four nutrient categories a character's chest badge can represent.
enum StatType: String, Codable, CaseIterable {
    case protein, fiber, vitamin, hydration

    var label: String {
        switch self {
        case .protein: return "Protein"
        case .fiber: return "Fiber"
        case .vitamin: return "Vitamin"
        case .hydration: return "Hydration"
        }
    }

    /// SF Symbol standing in for the custom badge glyph until it's bundled as an asset.
    var systemImageName: String {
        switch self {
        case .protein: return "bolt.fill"
        case .fiber: return "leaf.fill"
        case .vitamin: return "sparkle"
        case .hydration: return "drop.fill"
        }
    }
}
