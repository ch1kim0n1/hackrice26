import SwiftUI
import NutriQuestUI
import BattleKit

/// Home is today's nutrition mission, told in three sections. The first two
/// all read the same onboarding-derived DailyPlan:
///   1. Week strip — Monday to Sunday "day coins" that fill bottom-up as
///      each day's calories approach the goal, sealed with a check when hit.
///   2. Nutrition card — the calorie gauge (a 0-to-target capsule filled by
///      today's intake, red once over budget) with the protein, carbs, and
///      fats allowances below it, all in one card.
///   3. Activity row — calories burned (ring) and steps from the last watch
///      sync; dashes before the first sync, never fake numbers.
struct HomeView: View {
    @ObservedObject var gameState: GameState

    @Environment(\.nqAccent) private var accent

    /// The character the profile is currently showcasing — server value,
    /// starter fallback while it loads (same resolution RootTabView uses).
    private var activeCharacter: Character? {
        let id = gameState.profile?.activeCharacterId
        return gameState.collection.first { $0.id == id }
            ?? gameState.collection.first { !$0.isLocked }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: NQTheme.spaceL) {
                NQAssetBanner("3-2-ration-banner")
                    .nqSlideUp(delay: 0.02)
                weekStrip
                    .nqSlideUp(delay: 0.05)
                heroCard
                    .nqSlideUp(delay: 0.1)
                activityRow
                    .nqSlideUp(delay: 0.15)
                tasksCard
                    .nqSlideUp(delay: 0.2)
            }
            .padding(NQTheme.spaceL)
        }
        .refreshable {
            await gameState.refreshTasks()
            await gameState.refreshVitals()
            await gameState.loadCoinBalance()
            await gameState.loadProfile()
        }
        .nqSceneBackground(GameArt.scene("home"))
        .navigationTitle("Quest")
        .navigationBarTitleDisplayMode(.inline)
        .nqTransparentNav()
        .toolbar {
            ToolbarItem(placement: .principal) {
                NQGameTitle("Quest")
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                HStack(spacing: NQTheme.spaceS) {
                    if let days = gameState.streak?.days, days > 0 {
                        NQStreakPill(count: days)
                    }
                    NQCoinBalance(balance: gameState.coinBalance)
                }
            }
            .nqHideGlass()
        }
        .task {
            await gameState.refreshTasks()
            await gameState.loadCoinBalance()
        }
    }

    // MARK: - Hero card: display character + nutrition (#28)

    /// The display character stands centre-stage with today's calorie budget
    /// wrapped as a progress ring around its base; the three macro tiles sit
    /// underneath. One card, same daily plan numbers as before.
    private var heroCard: some View {
        let target = max(Double(gameState.dailyPlan.calories), 1)
        let consumed = gameState.todayCalories
        let over = consumed > target
        let progress = min(consumed / target, 1)
        let remaining = Int(abs(target - consumed).rounded())

        return VStack(spacing: NQTheme.spaceM) {
            ZStack {
                // The ring wraps the character's base — consumed calories
                // sweep it in the accent colour, red once over budget.
                Circle()
                    .stroke(NQTheme.hairline, lineWidth: 12)
                Circle()
                    .trim(from: 0, to: max(0.02, progress))
                    .stroke(
                        over ? AnyShapeStyle(NQTheme.overBudget)
                             : AnyShapeStyle(LinearGradient(colors: [accent.accent, accent.accentDark],
                                                            startPoint: .topLeading, endPoint: .bottomTrailing)),
                        style: StrokeStyle(lineWidth: 12, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
                    .animation(.easeOut(duration: 0.4), value: progress)
                if let character = activeCharacter, !character.isLocked {
                    CharacterArtwork(character: character)
                        .frame(width: 118, height: 148)
                        .modifier(MascotIdleBob(enabled: true))
                        .nqSquish()
                        .accessibilityHint("Tap to squish")
                } else {
                    NQIcon.sparkle.view
                        .frame(width: 44, height: 44)
                        .foregroundStyle(NQTheme.inkFaint)
                }
            }
            .frame(width: 190, height: 190)
            .padding(.top, NQTheme.spaceS)

            VStack(spacing: 2) {
                NQCountUpText(
                    value: remaining,
                    font: NQFont.display.font(34),
                    color: over ? NQTheme.overBudget : NQTheme.ink
                )
                Text(over ? "Calories over" : "Calories left")
                    .font(NQText.caption.font.weight(.bold))
                    .foregroundStyle(over ? NQTheme.overBudget : NQTheme.inkMuted)
            }

            Rectangle()
                .fill(NQTheme.hairline)
                .frame(height: 1.5)
            macroRow
        }
        .nqPadding(.card)
        .nqSurface(.hero)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            over
            ? "\(remaining) calories over today's \(gameState.dailyPlan.calories) calorie budget"
            : "\(remaining) calories left of today's \(gameState.dailyPlan.calories) calorie budget"
        )
    }

    // MARK: - Section 4: daily tasks (spec §6)

    /// Today's three server-verified tasks — one nutrition, one battle, one
    /// flex. Each claim pays 250 coins; all three pay +500. Nutrition and
    /// battle tasks also pay +5 task RR (capped +10/day, never promotes).
    private var tasksCard: some View {
        VStack(alignment: .leading, spacing: NQTheme.spaceS) {
            HStack {
                Text("Daily tasks")
                    .font(NQText.headingL.font)
                    .foregroundStyle(NQTheme.ink)
                    .shadow(color: NQTheme.inkDeep, radius: 0, y: 2)
                Spacer(minLength: 0)
                if let streak = gameState.streak {
                    NQChip("\(streak.days)d streak", icon: .flame, tint: NQTheme.flame, filled: streak.days > 0)
                    if streak.boosts > 0 {
                        NQChip("\(streak.boosts) boost\(streak.boosts == 1 ? "" : "s")", icon: .sparkle, tint: NQTheme.gold, filled: true)
                    }
                }
            }

            if gameState.dailyTasks.isEmpty {
                Text("Pull down to load today's tasks.")
                    .font(NQText.captionS.font)
                    .foregroundStyle(NQTheme.inkMuted)
            } else {
                ForEach(Array(gameState.dailyTasks.enumerated()), id: \.element.id) { index, task in
                    taskRow(task)
                        .nqCascade(index: index)
                }
            }

            if !gameState.dailyTasks.isEmpty {
                Text("All three claimed pays +500 bonus coins.")
                    .font(NQText.micro.font)
                    .foregroundStyle(NQTheme.inkFaint)
            }
        }
        .nqPadding(.card)
        .nqSurface(.sticker)
    }

    private func taskRow(_ task: TaskDTO) -> some View {
        HStack(spacing: NQTheme.spaceS) {
            ZStack {
                Circle()
                    .fill(taskTint(task).opacity(0.16))
                    .frame(width: 32, height: 32)
                taskIcon(task)
                    .frame(width: 15, height: 15)
                    .foregroundStyle(taskTint(task))
            }

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: NQTheme.spaceXS) {
                    Text(task.label)
                        .font(NQText.caption.font.weight(.semibold))
                        .foregroundStyle(NQTheme.ink)
                    if task.watchOnly == true {
                        NQChip("Watch", tint: NQTheme.info, filled: false)
                    }
                    if task.rrEligible {
                        NQChip("+5 RR", tint: NQTheme.gold, filled: false)
                    }
                }
            }
            Spacer(minLength: 0)

            if task.claimed {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(NQTheme.success)
                    .accessibilityLabel("Claimed")
            } else if task.done {
                Button {
                    NQHaptic.selection()
                    Task { _ = await gameState.claimTask(task.id) }
                } label: {
                    Text("Claim +250")
                        .font(NQText.captionS.font.weight(.heavy))
                        .foregroundStyle(accent.accent.readableTextColor())
                        .nqPadding(.badge)
                        .background(NQPanelShape(cut: NQTheme.radiusXS).fill(accent.accent))
                }
                .buttonStyle(NQPressableStyle(scale: 0.94, haptic: false, ledge: 3))
                .nqInvitePulse()
                .accessibilityHint("Claims the task reward")
            } else {
                Text("Open")
                    .font(NQText.captionS.font.weight(.bold))
                    .foregroundStyle(NQTheme.inkFaint)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func taskTint(_ task: TaskDTO) -> Color {
        switch task.category {
        case "nutrition": return NQTheme.flame
        case "battle": return NQTheme.info
        default: return accent.accentDark
        }
    }

    @ViewBuilder
    private func taskIcon(_ task: TaskDTO) -> some View {
        switch task.category {
        case "nutrition": NQIcon.flame.view
        case "battle": NQIcon.battle.view
        default: NQIcon.sparkle.view
        }
    }

    // MARK: - Section 1: week strip

    /// One day of the Monday-to-Sunday strip, with its goal progress.
    private struct WeekDay: Identifiable {
        let id: Int
        /// Single-letter label under the coin ("M"..."S").
        let label: String
        /// Full day name for accessibility ("Monday"...).
        let name: String
        /// 0...1 progress toward the daily calorie goal.
        let progress: Double
        let isToday: Bool
        let isFuture: Bool
    }

    /// Monday through Sunday of the current week, each with its progress
    /// toward the daily calorie goal. Past days read the persisted per-day
    /// totals; today reads the live session total; future days are empty.
    private var weekDays: [WeekDay] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        // Calendar weekday is 1 = Sunday ... 7 = Saturday; shift to
        // days-since-Monday so the strip always starts on Monday.
        let daysSinceMonday = (calendar.component(.weekday, from: today) + 5) % 7
        guard let monday = calendar.date(byAdding: .day, value: -daysSinceMonday, to: today) else { return [] }

        let labels = ["M", "T", "W", "T", "F", "S", "S"]
        let names = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"]
        let target = max(Double(gameState.dailyPlan.calories), 1)

        return (0..<7).map { offset in
            let date = calendar.date(byAdding: .day, value: offset, to: monday) ?? today
            return WeekDay(
                id: offset,
                label: labels[offset],
                name: names[offset],
                progress: min(gameState.calories(on: date) / target, 1),
                isToday: calendar.isDate(date, inSameDayAs: today),
                isFuture: date > today
            )
        }
    }

    /// Header strip of seven day coins, Monday through Sunday.
    private var weekStrip: some View {
        HStack(spacing: 0) {
            ForEach(weekDays) { day in
                DayCoin(
                    label: day.label,
                    dayName: day.name,
                    progress: day.progress,
                    isToday: day.isToday,
                    isFuture: day.isFuture,
                    tint: accent.accent
                )
                .frame(maxWidth: .infinity)
            }
        }
        .nqPadding(.card)
        .nqSurface(.sticker)
    }

    /// The three macro columns — protein, carbs, and fats — sized by the plan
    /// derived from the onboarding answers. Colors match the plan-ready
    /// screen so the vocabulary carries through from onboarding to home.
    private var macroRow: some View {
        HStack(spacing: NQTheme.spaceM) {
            MacroTile(
                name: "Protein", icon: "fork.knife", tint: NQTheme.protein,
                consumed: gameState.todayProtein,
                target: Double(gameState.dailyPlan.proteinG)
            )
            MacroTile(
                name: "Carbs", icon: "leaf.fill", tint: NQTheme.carbs,
                consumed: gameState.todayCarbs,
                target: Double(gameState.dailyPlan.carbsG)
            )
            MacroTile(
                name: "Fats", icon: "drop.fill", tint: NQTheme.fat,
                consumed: gameState.todayFat,
                target: Double(gameState.dailyPlan.fatsG)
            )
        }
    }

    // MARK: - Section 3: activity row

    /// Bottom activity row from the last watch sync: a circular burn ring on
    /// the left and a steps tile on the right. Both show dashes until the
    /// first vitals snapshot arrives — real numbers only. `fixedSize` pins
    /// the row to its ideal height so both tiles (which stretch to fill)
    /// come out the same width and height.
    private var activityRow: some View {
        HStack(spacing: NQTheme.spaceM) {
            BurnRingTile(
                caloriesBurned: gameState.vitalsActivity?.activeCaloriesToday,
                progress: gameState.vitalsActivity?.burnProgress ?? 0
            )
            StepsTile(
                steps: gameState.vitalsActivity?.stepsToday,
                progress: gameState.vitalsActivity?.stepProgress ?? 0,
                tint: accent.accent
            )
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Day coin

/// One circle of the week strip. The coin fills bottom-up with the accent
/// color in proportion to that day's calorie-goal progress, and becomes a
/// fully filled coin with a checkmark once the goal is reached. Today's
/// coin is ringed in ink; future days sit faint.
private struct DayCoin: View {
    let label: String
    /// Full day name, used only for the accessibility label.
    let dayName: String
    /// 0...1 progress toward the daily calorie goal.
    let progress: Double
    let isToday: Bool
    let isFuture: Bool
    let tint: Color

    /// Coin diameter in points.
    private let size: CGFloat = 38

    /// True once the day's calorie goal has been reached.
    private var achieved: Bool { progress >= 1 }

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                Circle()
                    .fill(NQTheme.surface)
                if achieved {
                    Circle()
                        .fill(tint)
                        .padding(NQTheme.spaceXS)
                    Image(systemName: "checkmark")
                        .font(.system(size: NQLayout.iconS, weight: .heavy))
                        .foregroundStyle(tint.readableTextColor())
                } else if progress > 0 {
                    // Liquid fill: the coin fills from the bottom as the
                    // day's calories climb toward the goal.
                    Circle()
                        .fill(tint.opacity(0.85))
                        .padding(3)
                        .mask(
                            VStack(spacing: 0) {
                                Spacer(minLength: 0)
                                Rectangle()
                                    .frame(height: size * progress)
                            }
                        )
                }
                Circle()
                    .strokeBorder(
                        isToday ? NQTheme.inkDeep.opacity(0.55) : NQTheme.hairline,
                        lineWidth: isToday ? 2 : 1.5
                    )
            }
            .frame(width: size, height: size)
            .opacity(isFuture ? 0.4 : 1)

            Text(label)
                .font(NQText.micro.font)
                .foregroundStyle(isToday ? NQTheme.ink : NQTheme.inkMuted)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    /// Spoken summary of the day's goal state.
    private var accessibilityText: String {
        if isFuture { return "\(dayName), upcoming" }
        if achieved { return "\(dayName), goal reached" }
        return "\(dayName), \(Int(progress * 100)) percent of calorie goal"
    }
}

// MARK: - Mascot idle bob (shared)

/// Gentle idle bob for mascots. Lives here historically; still used by the
/// character detail sheet.
struct MascotIdleBob: ViewModifier {
    var enabled: Bool
    @State private var up = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Applies the repeating vertical bob when enabled and motion is allowed.
    func body(content: Content) -> some View {
        content
            .offset(y: up && !reduceMotion ? -5 : 0)
            .animation(
                reduceMotion ? nil : .easeInOut(duration: 1.8).repeatForever(autoreverses: true),
                value: up
            )
            .onAppear { up = enabled }
    }
}

// MARK: - Macro tile

/// One macro allowance column inside the nutrition card: remaining grams as
/// the headline, a "left" or "over" caption, and a progress ring filled by
/// today's logged amount.
private struct MacroTile: View {
    let name: String
    /// SF Symbol shown in the ring's center.
    let icon: String
    let tint: Color
    /// Grams logged today.
    let consumed: Double
    /// The plan's daily grams for this macro.
    let target: Double

    /// True once today's intake exceeds the plan's allowance.
    private var over: Bool { consumed > target }

    /// Grams remaining (or exceeded, when over).
    private var remaining: Int { Int(abs(target - consumed).rounded()) }

    /// Ring sweep, 0...1.
    private var progress: Double {
        guard target > 0 else { return 0 }
        return over ? 1 : min(consumed / target, 1)
    }

    var body: some View {
        VStack(spacing: NQTheme.spaceS) {
            Text("\(remaining)g")
                .font(NQFont.heading.font(20))
                .foregroundStyle(NQTheme.ink)
                .monospacedDigit()
            Text(over ? "\(name) over" : "\(name) left")
                .font(NQText.captionS.font)
                .foregroundStyle(over ? NQTheme.overBudget : NQTheme.inkMuted)

            ZStack {
                Circle()
                    .stroke(NQTheme.hairline, lineWidth: 7)
                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(
                        over ? NQTheme.overBudget : tint,
                        style: StrokeStyle(lineWidth: 7, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
                    .animation(.easeOut(duration: 0.4), value: progress)
                Image(systemName: icon)
                    .font(.system(size: NQLayout.iconM, weight: .semibold))
                    .foregroundStyle(over ? NQTheme.overBudget : tint)
            }
            .frame(width: 56, height: 56)
            .padding(.top, 2)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            over
            ? "\(name): \(remaining) grams over the \(Int(target)) gram target"
            : "\(name): \(remaining) grams left of the \(Int(target)) gram target"
        )
    }
}

// MARK: - Burn ring tile

/// Circular calories-burned widget for the Home activity row. A ring fills
/// toward the daily burn goal with the burned kilocalories in the center;
/// shows a dash until the watch's first vitals snapshot arrives.
private struct BurnRingTile: View {
    /// Active kilocalories burned today, nil before the first watch sync.
    let caloriesBurned: Int?
    /// 0...1 progress toward `VitalsActivity.burnGoalCalories`.
    let progress: Double

    /// Headline text: the burned total, or a dash before the first sync.
    private var valueText: String {
        caloriesBurned.map { $0.formatted() } ?? "-"
    }

    var body: some View {
        VStack(spacing: NQTheme.spaceS) {
            ZStack {
                Circle()
                    .stroke(NQTheme.hairline, lineWidth: 8)
                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(
                        NQTheme.flame,
                        style: StrokeStyle(lineWidth: 8, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
                    .animation(.easeOut(duration: 0.4), value: progress)
                VStack(spacing: 1) {
                    NQIcon.flame.view
                        .frame(width: 14, height: 14)
                        .foregroundStyle(NQTheme.flame)
                    Text(valueText)
                        .font(NQFont.heading.font(19))
                        .foregroundStyle(NQTheme.ink)
                        .monospacedDigit()
                    Text("CAL")
                        .font(NQText.micro.font)
                        .foregroundStyle(NQTheme.inkFaint)
                }
            }
            .frame(width: 86, height: 86)

            Text("Burned today")
                .font(NQText.captionS.font)
                .foregroundStyle(NQTheme.inkMuted)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .nqPadding(.card)
        .nqSurface(.sticker)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            caloriesBurned.map { "\($0) calories burned today" }
            ?? "Calories burned today: waiting for watch sync"
        )
    }
}

// MARK: - Steps tile

/// Steps widget for the Home activity row: today's step count with a capsule
/// bar filling toward the 10,000-step goal. Shows a dash until the watch's
/// first vitals snapshot arrives.
private struct StepsTile: View {
    /// Steps taken today, nil before the first watch sync.
    let steps: Int?
    /// 0...1 progress toward `VitalsActivity.stepGoal`.
    let progress: Double
    /// Accent color from the parent screen's theme.
    let tint: Color

    /// Headline text: today's step count, or a dash before the first sync.
    private var valueText: String {
        steps.map { $0.formatted() } ?? "-"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: NQTheme.spaceS) {
            ZStack {
                Circle()
                    .fill(tint.opacity(0.14))
                    .frame(width: 34, height: 34)
                Image(systemName: "figure.walk")
                    .font(.system(size: NQLayout.iconM, weight: .semibold))
                    .foregroundStyle(tint)
            }

            Text(valueText)
                .font(NQFont.heading.font(24))
                .foregroundStyle(NQTheme.ink)
                .monospacedDigit()
            Text("Steps today")
                .font(NQText.captionS.font)
                .foregroundStyle(NQTheme.inkMuted)

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(NQTheme.surface)
                    Capsule()
                        .strokeBorder(NQTheme.hairline, lineWidth: 1.5)
                    if progress > 0 {
                        Capsule()
                            .fill(tint)
                            .frame(width: max(10, geo.size.width * progress))
                            .animation(.easeOut(duration: 0.4), value: progress)
                    }
                }
            }
            .frame(height: 10)

            Text("Goal \(VitalsActivity.stepGoal.formatted())")
                .font(NQText.micro.font)
                .foregroundStyle(NQTheme.inkFaint)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .nqPadding(.card)
        .nqSurface(.sticker)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            steps.map { "\($0) steps today of a \(VitalsActivity.stepGoal) step goal" }
            ?? "Steps today: waiting for watch sync"
        )
    }
}
