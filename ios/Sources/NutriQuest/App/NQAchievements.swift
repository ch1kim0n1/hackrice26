import SwiftUI
import NutriQuestUI

/// Discrete "you did X" milestones — the missing achievement layer.
/// Evaluated locally after scans / crate pulls / battle results; unlocks are
/// persisted in UserDefaults and surfaced as a one-shot celebration overlay.
struct Achievement: Identifiable, Equatable {
    let id: String
    let title: String
    let detail: String
    let icon: NQIcon
}

enum Achievements {
    static let all: [Achievement] = [
        Achievement(id: "first_scan", title: "First Contact", detail: "Scanned your first food", icon: .barcode),
        Achievement(id: "scans_10", title: "Aisle Warrior", detail: "10 foods scanned", icon: .barcode),
        Achievement(id: "first_rare", title: "Rare Find", detail: "First rare+ pull", icon: .star),
        Achievement(id: "first_legend", title: "Golden Pull", detail: "First legendary character", icon: .crown),
        Achievement(id: "squad_5", title: "Squad Goals", detail: "5 characters collected", icon: .grid),
        Achievement(id: "battles_10", title: "Ten-Round Veteran", detail: "10 battles won", icon: .trophy)
    ]

    private static let storeKey = "achievements.unlocked"

    static func unlockedIDs() -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: storeKey) ?? [])
    }

    struct Stats {
        var totalScans: Int = 0
        var uniqueCharacters: Int = 0
        var rarePlusPulls: Int = 0
        var legendaries: Int = 0
        var battlesWon: Int = 0

        func earnedIDs() -> Set<String> {
            var ids: Set<String> = []
            if totalScans >= 1 { ids.insert("first_scan") }
            if totalScans >= 10 { ids.insert("scans_10") }
            if rarePlusPulls >= 1 { ids.insert("first_rare") }
            if legendaries >= 1 { ids.insert("first_legend") }
            if uniqueCharacters >= 5 { ids.insert("squad_5") }
            if battlesWon >= 10 { ids.insert("battles_10") }
            return ids
        }
    }

    /// Evaluates current stats against every achievement; returns newly
    /// unlocked ones (and persists them). Call after scans, pulls, battles.
    static func evaluate(stats: Stats) -> [Achievement] {
        let earned = stats.earnedIDs()
        let already = unlockedIDs()
        let freshIDs = earned.subtracting(already)
        guard !freshIDs.isEmpty else { return [] }
        var current = already
        current.formUnion(freshIDs)
        UserDefaults.standard.set(Array(current), forKey: storeKey)
        return all.filter { freshIDs.contains($0.id) }
    }
}
