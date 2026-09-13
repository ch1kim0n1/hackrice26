import SwiftUI
import NutriQuestUI
import BattleKit

/// Real calorie/macro tracking, the way MyFitnessPal-style apps do it —
/// but driven entirely by this session's actual scanned foods and the
/// player's personal targets (Mifflin-St Jeor), not sample data.
struct HealthDashboardView: View {
    @ObservedObject var gameState: GameState

    @Environment(\.nqAccent) private var accent

    private var profile: PlayerProfile { gameState.nutritionProfile }

    var body: some View {
        ScrollView {
            VStack(spacing: NQTheme.spaceL) {
                calorieCard
                macroRow
                diversityCard
                multiplierCard
                todayLogCard
            }
            .padding(NQTheme.spaceL)
        }
        .nqPageBackground()
        .navigationTitle("Health Dashboard")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Calories

    private var calorieCard: some View {
        VStack(spacing: NQTheme.spaceM) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("TODAY")
                        .font(NQText.microS.font)
                        .tracking(0.6)
                        .foregroundStyle(NQTheme.inkMuted)
                    Text("Calories")
                        .font(NQText.heading.font.weight(.heavy))
                        .foregroundStyle(NQTheme.ink)
                }
                Spacer()
                NQChip("\(gameState.todayEntries.count) logged", icon: .barcode)
            }

            HStack(spacing: NQTheme.spaceL) {
                CalorieRing(
                    progress: gameState.todayCalorieProgress,
                    isOver: gameState.todayCalories > profile.calorieTarget,
                    tint: accent.accent
                )
                .frame(width: 128, height: 128)

                VStack(alignment: .leading, spacing: NQTheme.spaceS) {
                    statRow(label: "Consumed", value: "\(Int(gameState.todayCalories)) kcal", color: NQTheme.ink)
                    statRow(label: "Target", value: "\(Int(profile.calorieTarget)) kcal", color: NQTheme.inkMuted)
                    let remaining = profile.calorieTarget - gameState.todayCalories
                    statRow(
                        label: remaining >= 0 ? "Remaining" : "Over by",
                        value: "\(Int(abs(remaining))) kcal",
                        color: remaining >= 0 ? NQTheme.success : NQTheme.warning
                    )
                }
                Spacer(minLength: 0)
            }
        }
        .nqPadding(.card)
        .nqPlate(RoundedRectangle(cornerRadius: NQTheme.radiusXL), elevation: .raised)
    }

    private func statRow(label: String, value: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(label)
                .font(NQText.microS.font)
                .foregroundStyle(NQTheme.inkFaint)
            Text(value)
                .font(NQText.body.font.weight(.bold))
                .foregroundStyle(color)
        }
    }

    // MARK: - Macros

    private var macroRow: some View {
        HStack(spacing: NQTheme.spaceM - 2) {
            macroCard(
                title: "Protein",
                value: gameState.todayProtein,
                target: profile.proteinTarget,
                unit: "g",
                color: NQTheme.info
            )
            macroCard(
                title: "Fiber",
                value: gameState.todayFiber,
                target: profile.fiberTarget,
                unit: "g",
                color: NQTheme.success
            )
            macroCard(
                title: "Sugar",
                value: gameState.todaySugar,
                target: 50,
                unit: "g",
                color: NQTheme.warning,
                isLimit: true
            )
        }
    }

    private func macroCard(title: String, value: Double, target: Double, unit: String, color: Color, isLimit: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: NQTheme.spaceS) {
            Text(title)
                .font(NQText.captionS.font.weight(.bold))
                .foregroundStyle(NQTheme.inkMuted)
            Text("\(Int(value))\(unit)")
                .font(NQText.headingL.font.weight(.heavy))
                .foregroundStyle(NQTheme.ink)
            Text(isLimit ? "under \(Int(target))\(unit)" : "of \(Int(target))\(unit)")
                .font(NQText.microS.font)
                .foregroundStyle(NQTheme.inkFaint)
            NQStatBar(value: min(value / max(target, 1), 1))
                .fill(isLimit && value > target ? NQTheme.warning : color)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .nqPadding(.card)
        .nqPlate(RoundedRectangle(cornerRadius: NQTheme.radiusL), elevation: .soft)
    }

    // MARK: - Diversity

    private var diversityCard: some View {
        VStack(alignment: .leading, spacing: NQTheme.spaceS + 2) {
            HStack {
                Text("Food Diversity")
                    .font(NQText.heading.font)
                    .foregroundStyle(NQTheme.ink)
                Spacer()
                Text("\(gameState.todayFoodGroups)/4 groups")
                    .font(NQText.captionS.font.weight(.bold))
                    .foregroundStyle(accent.accentDark)
            }
            HStack(spacing: NQTheme.spaceS) {
                ForEach(diversityGroups, id: \.group) { entry in
                    groupChip(entry.label, hit: entry.hit)
                }
            }
            HStack(spacing: NQTheme.spaceS + 2) {
                NQIcon.sparkle.view
                    .frame(width: 14, height: 14)
                    .foregroundStyle(accent.accentDark)
                Text("Quality score")
                    .font(NQText.caption.font)
                    .foregroundStyle(NQTheme.inkSubtle)
                NQStatBar(value: gameState.todayQualityScore)
                Text("\(Int(gameState.todayQualityScore * 100))%")
                    .font(NQText.captionS.font.weight(.heavy))
                    .foregroundStyle(NQTheme.ink)
            }
        }
        .nqPadding(.card)
        .frame(maxWidth: .infinity, alignment: .leading)
        .nqPlate(RoundedRectangle(cornerRadius: NQTheme.radiusL), elevation: .soft)
    }

    private var diversityGroups: [(group: FoodGroup, label: String, hit: Bool)] {
        let hitGroups = Set(gameState.todayEntries.map(\.foodGroup))
        return [
            (.produce, "Produce", hitGroups.contains(.produce)),
            (.grain, "Grain", hitGroups.contains(.grain)),
            (.dairy, "Dairy", hitGroups.contains(.dairy)),
            (.protein, "Protein", hitGroups.contains(.protein))
        ]
    }

    private func groupChip(_ label: String, hit: Bool) -> some View {
        Text(label)
            .font(NQText.captionS.font.weight(.bold))
            .foregroundStyle(hit ? accent.accent.readableTextColor() : NQTheme.inkFaint)
            .nqPadding(.badge)
            .padding(.horizontal, 4)
            .frame(maxWidth: .infinity)
            .background(
                Capsule().fill(hit ? accent.accent : NQTheme.hairline)
            )
    }

    // MARK: - Multiplier tie-in

    private var multiplierCard: some View {
        VStack(alignment: .leading, spacing: NQTheme.spaceS + 2) {
            HStack {
                Text("Today's Squad Boost")
                    .font(NQText.heading.font)
                    .foregroundStyle(NQTheme.ink)
                Spacer()
                NQChip("×\(String(format: "%.2f", gameState.lastMultiplier))", icon: .battle, filled: true)
            }
            Text("Balanced eating powers your squad in battle. Here's what's driving today's number.")
                .font(NQText.captionS.font)
                .foregroundStyle(NQTheme.inkMuted)
            VStack(spacing: 6) {
                breakdownRow("Protein window", gameState.lastBreakdown.protein)
                breakdownRow("Fiber", gameState.lastBreakdown.fiber)
                breakdownRow("Diversity", gameState.lastBreakdown.diversity)
                breakdownRow("Micronutrients", gameState.lastBreakdown.micronutrients)
                breakdownRow("Calorie window", gameState.lastBreakdown.calorie)
                if gameState.lastBreakdown.sugarPenalty < 0 {
                    breakdownRow("Sugar / quality penalty", gameState.lastBreakdown.sugarPenalty)
                }
            }
        }
        .nqPadding(.card)
        .frame(maxWidth: .infinity, alignment: .leading)
        .nqPlate(RoundedRectangle(cornerRadius: NQTheme.radiusL), elevation: .soft)
    }

    private func breakdownRow(_ label: String, _ bonus: Double) -> some View {
        HStack {
            Text(label)
                .font(NQText.caption.font)
                .foregroundStyle(NQTheme.inkSubtle)
            Spacer()
            Text(bonus == 0 ? "—" : "\(bonus > 0 ? "+" : "")\(Int(bonus * 100))%")
                .font(NQText.captionS.font.weight(.heavy))
                .foregroundStyle(bonus > 0 ? NQTheme.success : (bonus < 0 ? NQTheme.warning : NQTheme.inkFaint))
        }
    }

    // MARK: - Today's log

    @ViewBuilder private var todayLogCard: some View {
        VStack(alignment: .leading, spacing: NQTheme.spaceS + 2) {
            Text("Today's Log")
                .font(NQText.heading.font)
                .foregroundStyle(NQTheme.ink)
            if gameState.todayEntries.isEmpty {
                NQEmptyState(message: "Nothing scanned yet today. Scan a food to start tracking", icon: .barcode)
                    .padding(.vertical, NQTheme.spaceM)
            } else {
                VStack(spacing: NQTheme.spaceS) {
                    ForEach(gameState.todayEntries.reversed()) { entry in
                        logRow(entry)
                    }
                }
            }
        }
        .nqPadding(.card)
        .frame(maxWidth: .infinity, alignment: .leading)
        .nqPlate(RoundedRectangle(cornerRadius: NQTheme.radiusL), elevation: .soft)
    }

    private func logRow(_ entry: DayLogEntry) -> some View {
        HStack(spacing: NQTheme.spaceS + 2) {
            Circle()
                .fill(accent.accentSoft)
                .frame(width: 34, height: 34)
                .overlay {
                    NQIcon.barcode.view
                        .frame(width: 14, height: 14)
                        .foregroundStyle(accent.accentDark)
                }
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.name.isEmpty ? entry.barcode : entry.name)
                    .font(NQText.caption.font.weight(.bold))
                    .foregroundStyle(NQTheme.ink)
                    .lineLimit(1)
                Text("\(Int(entry.protein))g protein · \(Int(entry.fiber))g fiber")
                    .font(NQText.microS.font)
                    .foregroundStyle(NQTheme.inkFaint)
            }
            Spacer()
            Text("\(Int(entry.calories)) kcal")
                .font(NQText.captionS.font.weight(.heavy))
                .foregroundStyle(NQTheme.inkMuted)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Circular calorie ring — trim-based, no external dependency.
private struct CalorieRing: View {
    let progress: Double  // 0...1
    let isOver: Bool
    let tint: Color

    var body: some View {
        ZStack {
            Circle()
                .stroke(NQTheme.hairline, lineWidth: 12)
            Circle()
                .trim(from: 0, to: max(0.02, progress))
                .stroke(
                    isOver ? NQTheme.warning : tint,
                    style: StrokeStyle(lineWidth: 12, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .animation(NQMotion.fill, value: progress)
            Text("\(Int(progress * 100))%")
                .font(NQText.headingL.font.weight(.heavy))
                .foregroundStyle(NQTheme.ink)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(Int(progress * 100)) percent of calorie target")
    }
}
