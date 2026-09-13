import SwiftUI
import Charts
import NutriQuestUI

/// Full-screen entertainment/engagement dashboard: numbers + charts for the
/// player’s entire NutriQuest journey (scans, crate pulls, collection), plus a
/// calendar of the watch's workout history (`JourneyActivityCalendar`), which
/// is where per-day steps live now.
struct JourneyView: View {
    @EnvironmentObject var gameState: GameState
    @Environment(\.dismiss) private var dismiss
    @Environment(\.nqAccent) private var accent

    var body: some View {
        NavigationStack {
            ScrollView {
                if let journey = gameState.journey {
                    VStack(alignment: .leading, spacing: NQTheme.spaceL) {
                        NQAssetBanner("banner", height: 120)
                        header(journey)
                            .nqSlideUp(delay: 0.05)
                        summaryGrid(journey.summary)
                        if let activity = journey.activity {
                            JourneyActivityCalendar(days: activity.byDay)
                                .nqSlideUp(delay: 0.1)
                        }
                        if !journey.timeline.scansByDay.isEmpty || !journey.timeline.dropsByDay.isEmpty {
                            timelineSection(journey.timeline)
                                .nqSlideUp(delay: 0.15)
                        }
                        if !journey.collection.byRarity.isEmpty {
                            distributionSection(
                                title: "Collection by Rarity",
                                data: journey.collection.byRarity,
                                color: { _ in accent.accent }
                            )
                            .nqSlideUp(delay: 0.2)
                        }
                        if !journey.recentDrops.isEmpty {
                            recentDrops(journey.recentDrops)
                                .nqSlideUp(delay: 0.35)
                        }
                    }
                    .padding(NQTheme.spaceL)
                } else if gameState.backendError != nil {
                    NQContentState(.error(
                        "Couldn't load your journey. Check your connection and retry.",
                        retry: { Task { await gameState.loadJourney() } }
                    ))
                    .padding(.top, 120)
                } else {
                    NQContentState(.loading("Loading journey..."))
                        .padding(.top, 120)
                }
            }
            .background(NQTheme.background.ignoresSafeArea())
            .navigationTitle("Your Journey")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(accent.accent)
                }
            }
        }
        .task {
            await gameState.loadJourney()
        }
    }

    // MARK: - Header

    private func header(_ journey: JourneyResponse) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(journey.profile.displayName)
                .font(NQText.displayL.font)
                .foregroundStyle(NQTheme.ink)
            HStack(spacing: NQTheme.spaceS) {
                NQChip("\(journey.profile.rr ?? 0) RR", filled: true)
                NQChip("\(journey.profile.nutritionStreakDays ?? journey.profile.streakDays ?? 0) day streak", icon: .flame)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Summary grid

    private func summaryGrid(_ summary: JourneySummary) -> some View {
        let columns = [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())]
        let tiles = [
            ("Scans", summary.totalScans, "barcode.viewfinder"),
            ("Drops", summary.totalDrops, "gift.fill"),
            ("Characters", summary.totalCharacters, "person.3.fill"),
            ("Loot Value", summary.totalLootValue, "dollarsign.circle.fill"),
            ("Vitals", summary.totalVitalsSnapshots, "heart.fill")
        ]
        return LazyVGrid(columns: columns, spacing: NQTheme.spaceS) {
            ForEach(Array(tiles.enumerated()), id: \.offset) { index, tile in
                statTile(tile.0, value: tile.1, icon: tile.2)
                    .nqCascade(index: index)
            }
        }
    }

    private func statTile(_ label: String, value: Int, icon: String) -> some View {
        VStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(accent.accent)
            Text("\(value)")
                .font(NQText.headingL.font.weight(.bold))
                .foregroundStyle(NQTheme.ink)
            Text(label)
                .font(NQText.microXS.font)
                .foregroundStyle(NQTheme.inkMuted)
        }
        .frame(maxWidth: .infinity, minHeight: 86)
        .nqPlate(RoundedRectangle(cornerRadius: NQTheme.radiusM), elevation: .soft)
    }

    // MARK: - Timeline

    private func timelineSection(_ timeline: JourneyTimeline) -> some View {
        VStack(alignment: .leading, spacing: NQTheme.spaceS) {
            Text("ACTIVITY")
                .font(NQText.microXS.font)
                .tracking(0.4)
                .foregroundStyle(NQTheme.inkMuted)
                .padding(.leading, 4)

            NQCard {
                VStack(alignment: .leading, spacing: NQTheme.spaceM) {
                    if !timeline.scansByDay.isEmpty {
                        Text("Scans per day")
                            .font(NQText.bodyL.font.weight(.semibold))
                            .foregroundStyle(NQTheme.ink)
                        Chart(timeline.scansByDay, id: \.date) { point in
                            BarMark(
                                x: .value("Date", point.date),
                                y: .value("Scans", point.count)
                            )
                            .foregroundStyle(accent.accent)
                            .cornerRadius(4)
                        }
                        .frame(height: 160)
                    }

                    if !timeline.dropsByDay.isEmpty {
                        Text("Drops per day")
                            .font(NQText.bodyL.font.weight(.semibold))
                            .foregroundStyle(NQTheme.ink)
                        Chart(timeline.dropsByDay, id: \.date) { point in
                            BarMark(
                                x: .value("Date", point.date),
                                y: .value("Drops", point.count)
                            )
                            .foregroundStyle(NQTheme.inkSubtle)
                            .cornerRadius(4)
                        }
                        .frame(height: 160)
                    }
                }
            }
        }
    }

    // MARK: - Distribution

    private func distributionSection<Item: JourneyDistributionItem>(
        title: String,
        data: [Item],
        color: @escaping (String) -> Color
    ) -> some View {
        VStack(alignment: .leading, spacing: NQTheme.spaceS) {
            Text(title)
                .font(NQText.microXS.font)
                .foregroundStyle(NQTheme.inkMuted)
                .padding(.leading, 4)

            NQCard {
                Chart(data, id: \.label) { item in
                    BarMark(
                        x: .value("Count", item.count),
                        y: .value("Kind", item.label)
                    )
                    .foregroundStyle(color(item.label))
                    .cornerRadius(4)
                }
                .frame(height: max(120, CGFloat(data.count) * 40))
                .chartYAxis {
                    AxisMarks(position: .leading)
                }
            }
        }
    }

    // MARK: - Recent drops

    private func recentDrops(_ drops: [InventoryItemDTO]) -> some View {
        VStack(alignment: .leading, spacing: NQTheme.spaceS) {
            Text("RECENT DROPS")
                .font(NQText.microXS.font)
                .tracking(0.4)
                .foregroundStyle(NQTheme.inkMuted)
                .padding(.leading, 4)

            VStack(spacing: NQTheme.spaceS) {
                ForEach(Array(drops.enumerated()), id: \.offset) { index, drop in
                    dropRow(drop)
                        .nqCascade(index: index)
                }
            }
        }
    }

    private func dropRow(_ drop: InventoryItemDTO) -> some View {
        HStack(spacing: NQTheme.spaceM) {
            Circle()
                .fill(Color(hex: drop.character.colorHex))
                .frame(width: 40, height: 40)
                .overlay {
                    Text(String(drop.character.name.prefix(1)))
                        .font(NQText.headingL.font)
                        .foregroundStyle(.white)
                }
            VStack(alignment: .leading, spacing: 2) {
                Text(drop.character.name)
                    .font(NQText.bodyL.font.weight(.semibold))
                    .foregroundStyle(NQTheme.ink)
                Text("\(drop.character.rarity.capitalized) · value \(drop.value)")
                    .font(NQText.microS.font)
                    .foregroundStyle(NQTheme.inkMuted)
            }
            Spacer()
            if (drop.stars ?? 1) > 1 {
                Text("★\(drop.stars ?? 1)")
                    .font(NQText.captionS.font.weight(.heavy))
                    .foregroundStyle(NQTheme.gold)
            }
        }
        .nqPadding(.card)
        .nqPlate(RoundedRectangle(cornerRadius: NQTheme.radiusM), elevation: .soft)
    }
}

fileprivate protocol JourneyDistributionItem {
    var label: String { get }
    var count: Int { get }
}

extension JourneyDistribution: JourneyDistributionItem {
    var label: String { rarity }
}


