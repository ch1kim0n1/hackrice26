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
                                title: "Collection by rarity",
                                data: journey.collection.byRarity,
                                color: { label in
                                    NQRarity(rawValue: label.lowercased())?.outline ?? accent.accent
                                }
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
                ToolbarItem(placement: .principal) {
                    NQGameTitle("Journey")
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 14, weight: .heavy))
                            .foregroundStyle(NQTheme.inkDeep)
                            .frame(width: 36, height: 36)
                            .background(NQTicketShape().fill(NQTheme.gold))
                            .overlay { NQTicketShape().strokeBorder(NQTheme.inkDeep, lineWidth: 2.5) }
                    }
                    .buttonStyle(NQPressableStyle(scale: 0.94, haptic: false, ledge: 3))
                    .accessibilityLabel("Done")
                }
                .nqHideGlass()
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
            VStack(alignment: .leading, spacing: 2) {
                Text("\(journey.profile.rr ?? 0) RR")
                    .font(NQText.heading.font.weight(.heavy))
                    .foregroundStyle(NQTheme.gold)
                Text("\(journey.profile.nutritionStreakDays ?? journey.profile.streakDays ?? 0) day streak")
                    .font(NQText.caption.font.weight(.heavy))
                    .foregroundStyle(NQTheme.flame)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Summary grid

    private func summaryGrid(_ summary: JourneySummary) -> some View {
        let columns = [GridItem(.flexible()), GridItem(.flexible())]
        let tiles = [
            ("Scans", summary.totalScans, "barcode.viewfinder"),
            ("Drops", summary.totalDrops, "gift.fill"),
            ("Characters", summary.totalCharacters, "person.3.fill"),
            ("Loot value", summary.totalLootValue, "dollarsign.circle.fill"),
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
        HStack(spacing: NQTheme.spaceS) {
            Rectangle()
                .fill(NQTheme.gold)
                .frame(width: 8)
            Image(systemName: icon)
                .font(.system(size: NQLayout.iconM, weight: .bold))
                .foregroundStyle(NQTheme.gold)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 0) {
                Text(label)
                    .font(NQText.microS.font)
                    .foregroundStyle(NQTheme.inkMuted)
                Text("\(value)")
                    .font(NQText.headingL.font.weight(.heavy))
                    .foregroundStyle(NQTheme.ink)
                    .monospacedDigit()
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
        .background(NQTicketShape().fill(NQTheme.chrome))
        .overlay { NQTicketShape().strokeBorder(NQTheme.inkDeep, lineWidth: 2.5) }
        .clipShape(NQTicketShape())
    }

    // MARK: - Timeline

    private func timelineSection(_ timeline: JourneyTimeline) -> some View {
        NQCard {
            VStack(alignment: .leading, spacing: NQTheme.spaceM) {
                Text("Activity")
                    .font(NQText.headingL.font)
                    .foregroundStyle(NQTheme.ink)
                    .padding(.top, 2)

                if !timeline.scansByDay.isEmpty {
                    chartBlock(title: "Scans per day") {
                        Chart(timeline.scansByDay, id: \.date) { point in
                            BarMark(
                                x: .value("Date", point.date),
                                y: .value("Scans", point.count)
                            )
                            .foregroundStyle(accent.accent)
                            .cornerRadius(4)
                        }
                    }
                }

                if !timeline.dropsByDay.isEmpty {
                    chartBlock(title: "Drops per day") {
                        Chart(timeline.dropsByDay, id: \.date) { point in
                            BarMark(
                                x: .value("Date", point.date),
                                y: .value("Drops", point.count)
                            )
                            .foregroundStyle(NQTheme.gold)
                            .cornerRadius(4)
                        }
                    }
                }
            }
        }
    }

    private func chartBlock<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: NQTheme.spaceS) {
            Text(title)
                .font(NQText.caption.font.weight(.bold))
                .foregroundStyle(NQTheme.inkMuted)
            content()
                .frame(height: 160)
                .chartPlotStyle { plot in
                    plot.background(NQTheme.track.opacity(0.45))
                }
                .chartXAxis {
                    AxisMarks { _ in
                        AxisGridLine().foregroundStyle(NQTheme.inkSubtle.opacity(0.2))
                        AxisValueLabel()
                            .font(NQText.microXS.font)
                            .foregroundStyle(NQTheme.inkMuted)
                    }
                }
                .chartYAxis {
                    AxisMarks { _ in
                        AxisGridLine().foregroundStyle(NQTheme.inkSubtle.opacity(0.25))
                        AxisValueLabel()
                            .font(NQText.microXS.font)
                            .foregroundStyle(NQTheme.inkMuted)
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
        NQCard {
            VStack(alignment: .leading, spacing: NQTheme.spaceM) {
                Text(title)
                    .font(NQText.headingL.font)
                    .foregroundStyle(NQTheme.ink)
                Chart(data, id: \.label) { item in
                    BarMark(
                        x: .value("Count", item.count),
                        y: .value("Kind", item.label)
                    )
                    .foregroundStyle(color(item.label))
                    .cornerRadius(4)
                }
                .frame(height: max(120, CGFloat(data.count) * 40))
                .chartPlotStyle { plot in
                    plot.background(NQTheme.track.opacity(0.45))
                }
                .chartYAxis {
                    AxisMarks(position: .leading) { _ in
                        AxisValueLabel()
                            .font(NQText.microS.font)
                            .foregroundStyle(NQTheme.inkMuted)
                    }
                }
                .chartXAxis {
                    AxisMarks { _ in
                        AxisGridLine().foregroundStyle(NQTheme.inkSubtle.opacity(0.25))
                        AxisValueLabel()
                            .font(NQText.microXS.font)
                            .foregroundStyle(NQTheme.inkMuted)
                    }
                }
            }
        }
    }

    // MARK: - Recent drops

    private func recentDrops(_ drops: [InventoryItemDTO]) -> some View {
        VStack(alignment: .leading, spacing: NQTheme.spaceS) {
            Text("Recent drops")
                .font(NQText.headingL.font)
                .foregroundStyle(NQTheme.ink)

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
                Text(String(repeating: "★", count: drop.stars ?? 1))
                    .font(NQText.captionS.font.weight(.heavy))
                    .foregroundStyle(NQTheme.gold)
            }
        }
        .nqPadding(.card)
        .background(NQTicketShape().fill(NQTheme.chrome))
        .overlay { NQTicketShape().strokeBorder(NQTheme.inkDeep, lineWidth: 2.5) }
    }
}

fileprivate protocol JourneyDistributionItem {
    var label: String { get }
    var count: Int { get }
}

extension JourneyDistribution: JourneyDistributionItem {
    var label: String { rarity }
}


