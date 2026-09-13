import SwiftUI
import NutriQuestUI

/// Month calendar of the player's health activity for the Journey view: each
/// day is shaded by how much was worked out, and tapping a day lists the
/// workouts and step/calorie counters the watch reported for it.
struct JourneyActivityCalendar: View {
    let days: [JourneyActivityDay]

    @Environment(\.nqAccent) private var accent
    @Environment(\.calendar) private var calendar

    /// First of the month currently on screen.
    @State private var monthStart: Date = .distantPast
    @State private var selectedKey: String?

    var body: some View {
        // Bucket once per render; the DTO is small (≤100 snapshots' worth).
        let buckets = ActivityBuckets(days: days, calendar: calendar)
        VStack(alignment: .leading, spacing: NQTheme.spaceS) {
            Text("ACTIVITY CALENDAR")
                .font(NQText.microXS.font)
                .tracking(0.4)
                .foregroundStyle(NQTheme.inkMuted)
                .padding(.leading, NQTheme.spaceXS)

            NQCard {
                VStack(spacing: NQTheme.spaceM) {
                    monthHeader(buckets)
                    weekdayRow
                    monthGrid(buckets)
                    Divider().foregroundStyle(NQTheme.hairline)
                    dayDetail(buckets)
                }
            }
        }
        .onAppear {
            guard monthStart == .distantPast else { return }
            // Open on the most recent day that has anything to show.
            let initialKey = buckets.latestActiveKey ?? buckets.key(for: Date())
            selectedKey = initialKey
            monthStart = startOfMonth(buckets.date(for: initialKey) ?? Date())
        }
    }

    // MARK: - Month header

    private func monthHeader(_ buckets: ActivityBuckets) -> some View {
        let thisMonth = startOfMonth(Date())
        let earliest = startOfMonth(buckets.earliestDate ?? Date())
        return HStack {
            monthButton("chevron.left", label: "Previous month", enabled: monthStart > earliest) {
                shiftMonth(by: -1)
            }
            Spacer()
            Text(monthStart, format: .dateTime.month(.wide).year())
                .font(NQText.heading.font)
                .foregroundStyle(NQTheme.ink)
            Spacer()
            monthButton("chevron.right", label: "Next month", enabled: monthStart < thisMonth) {
                shiftMonth(by: 1)
            }
        }
    }

    private func monthButton(_ symbol: String, label: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: NQLayout.iconS, weight: .bold))
                .foregroundStyle(enabled ? accent.accentDark : NQTheme.inkFaint)
                .frame(width: NQLayout.controlMinHeight - NQTheme.spaceS,
                       height: NQLayout.controlMinHeight - NQTheme.spaceS)
                .background(
                    Circle().fill(enabled ? accent.accentSoft : NQTheme.track)
                )
        }
        .buttonStyle(.nqPressable(scale: 0.92, haptic: false))
        .disabled(!enabled)
        .accessibilityLabel(label)
    }

    private func shiftMonth(by delta: Int) {
        guard let next = calendar.date(byAdding: .month, value: delta, to: monthStart) else { return }
        withAnimation(.easeInOut(duration: 0.2)) {
            monthStart = next
        }
    }

    // MARK: - Grid

    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: NQTheme.spaceXS), count: 7)
    }

    private var weekdayRow: some View {
        // Rotate so the row starts on the locale's first weekday.
        let symbols = calendar.veryShortStandaloneWeekdaySymbols
        let shift = calendar.firstWeekday - 1
        let ordered = Array(symbols[shift...] + symbols[..<shift])
        return LazyVGrid(columns: columns, spacing: 0) {
            ForEach(Array(ordered.enumerated()), id: \.offset) { _, symbol in
                Text(symbol)
                    .font(NQText.microXS.font)
                    .foregroundStyle(NQTheme.inkMuted)
                    .frame(maxWidth: .infinity)
            }
        }
        .accessibilityHidden(true)
    }

    private func monthGrid(_ buckets: ActivityBuckets) -> some View {
        let cells = monthCells()
        let today = buckets.key(for: Date())
        return LazyVGrid(columns: columns, spacing: NQTheme.spaceXS) {
            ForEach(Array(cells.enumerated()), id: \.offset) { _, date in
                if let date {
                    let key = buckets.key(for: date)
                    dayCell(
                        date: date,
                        bucket: buckets[key],
                        isToday: key == today,
                        isSelected: key == selectedKey,
                        isFuture: date > Date()
                    ) {
                        withAnimation(.easeOut(duration: 0.15)) { selectedKey = key }
                    }
                } else {
                    Color.clear.frame(height: cellHeight)
                }
            }
        }
    }

    private let cellHeight: CGFloat = NQLayout.controlMinHeight - NQTheme.spaceXS

    /// Leading `nil`s pad the first week so day 1 lands on its weekday.
    private func monthCells() -> [Date?] {
        guard let range = calendar.range(of: .day, in: .month, for: monthStart) else { return [] }
        let weekday = calendar.component(.weekday, from: monthStart)
        let leading = (weekday - calendar.firstWeekday + 7) % 7
        let days: [Date?] = range.compactMap { day in
            calendar.date(byAdding: .day, value: day - 1, to: monthStart)
        }
        return Array(repeating: nil, count: leading) + days
    }

    private func dayCell(
        date: Date,
        bucket: ActivityBucket?,
        isToday: Bool,
        isSelected: Bool,
        isFuture: Bool,
        onTap: @escaping () -> Void
    ) -> some View {
        let intensity = bucket?.intensity ?? 0
        let dayNumber = calendar.component(.day, from: date)
        let hasWorkout = !(bucket?.workouts.isEmpty ?? true)
        let hasMovement = (bucket?.hasActivity ?? false) && !hasWorkout
        return Button(action: onTap) {
            VStack(spacing: 2) {
                Text("\(dayNumber)")
                    .font(NQText.captionS.font.weight(isToday ? .heavy : .semibold))
                    .foregroundStyle(
                        isFuture ? NQTheme.inkFaint
                            : hasWorkout && intensity > 0.6 ? NQTheme.inkDeep
                            : isToday ? accent.accentDark
                            : NQTheme.ink
                    )
                // Steps-only days get a dot; workout days shade the whole cell.
                Circle()
                    .fill(hasMovement ? NQTheme.leaf : Color.clear)
                    .frame(width: NQTheme.spaceXS, height: NQTheme.spaceXS)
            }
            .frame(maxWidth: .infinity, minHeight: cellHeight)
            .background(
                RoundedRectangle(cornerRadius: NQTheme.radiusXS, style: .continuous)
                    .fill(hasWorkout ? accent.accent.opacity(0.3 + 0.7 * intensity) : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: NQTheme.radiusXS, style: .continuous)
                    .strokeBorder(
                        isSelected ? NQTheme.ink : isToday ? accent.accent : Color.clear,
                        lineWidth: NQLayout.hairlineWidth
                    )
            )
        }
        .buttonStyle(.nqPressable(scale: 0.94, haptic: false))
        .disabled(isFuture)
        .accessibilityLabel(accessibilityLabel(for: date, bucket: bucket))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func accessibilityLabel(for date: Date, bucket: ActivityBucket?) -> String {
        let day = date.formatted(.dateTime.weekday(.wide).month().day())
        guard let bucket, bucket.hasActivity else { return "\(day), no activity" }
        var parts = [day]
        if !bucket.workouts.isEmpty {
            parts.append("\(bucket.workouts.count) workouts, \(Int(bucket.workoutMinutes.rounded())) minutes")
        }
        if let steps = bucket.steps, steps > 0 { parts.append("\(steps) steps") }
        return parts.joined(separator: ", ")
    }

    // MARK: - Day detail

    @ViewBuilder
    private func dayDetail(_ buckets: ActivityBuckets) -> some View {
        let key = selectedKey ?? buckets.key(for: Date())
        let bucket = buckets[key]
        VStack(alignment: .leading, spacing: NQTheme.spaceM) {
            HStack {
                Text((buckets.date(for: key) ?? Date()).formatted(.dateTime.weekday(.wide).month(.abbreviated).day()))
                    .font(NQText.bodyL.font.weight(.semibold))
                    .foregroundStyle(NQTheme.ink)
                Spacer()
                if let bucket, !bucket.workouts.isEmpty {
                    NQChip("\(Int(bucket.workoutMinutes.rounded())) min", icon: .flame, filled: true)
                }
            }

            if let bucket, bucket.hasActivity {
                counterRow(bucket)
                if bucket.workouts.isEmpty {
                    Text("No workouts logged — just everyday movement.")
                        .font(NQText.caption.font)
                        .foregroundStyle(NQTheme.inkMuted)
                } else {
                    VStack(spacing: NQTheme.spaceS) {
                        ForEach(bucket.workouts) { workout in
                            workoutRow(workout)
                        }
                    }
                }
            } else {
                Text("Rest day — nothing recorded by your watch.")
                    .font(NQText.caption.font)
                    .foregroundStyle(NQTheme.inkMuted)
            }
        }
        .id(key)
        .transition(.opacity)
    }

    private func counterRow(_ bucket: ActivityBucket) -> some View {
        HStack(spacing: NQTheme.spaceS) {
            if let steps = bucket.steps, steps > 0 {
                counterTile("figure.walk", value: steps.formatted(), label: "steps", tint: NQTheme.leaf)
            }
            if let kcal = bucket.activeCalories, kcal > 0 {
                counterTile("flame.fill", value: kcal.formatted(), label: "kcal", tint: NQTheme.flame)
            }
            if let minutes = bucket.exerciseMinutes, minutes > 0 {
                counterTile("bolt.heart.fill", value: minutes.formatted(), label: "exercise min", tint: NQTheme.teal)
            }
        }
    }

    private func counterTile(_ symbol: String, value: String, label: String, tint: Color) -> some View {
        VStack(spacing: 2) {
            Image(systemName: symbol)
                .font(.system(size: NQLayout.iconS, weight: .bold))
                .foregroundStyle(tint)
            Text(value)
                .font(NQText.heading.font)
                .foregroundStyle(NQTheme.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(label)
                .font(NQText.microXS.font)
                .foregroundStyle(NQTheme.inkMuted)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, NQTheme.spaceS)
        .background(
            RoundedRectangle(cornerRadius: NQTheme.radiusS, style: .continuous)
                .fill(NQTheme.track)
        )
        .accessibilityElement(children: .combine)
    }

    private func workoutRow(_ workout: JourneyWorkout) -> some View {
        HStack(spacing: NQTheme.spaceM) {
            ZStack {
                RoundedRectangle(cornerRadius: NQTheme.radiusS, style: .continuous)
                    .fill(accent.accentSoft)
                    .frame(width: NQTheme.spaceXL, height: NQTheme.spaceXL)
                Image(systemName: workout.symbolName)
                    .font(.system(size: NQLayout.iconM, weight: .bold))
                    .foregroundStyle(accent.accentDark)
            }
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(workout.activityType)
                    .font(NQText.bodyL.font.weight(.semibold))
                    .foregroundStyle(NQTheme.ink)
                Text(workout.detailLine)
                    .font(NQText.microS.font)
                    .foregroundStyle(NQTheme.inkMuted)
            }
            Spacer()
            Text("\(Int(workout.durationMinutes.rounded())) min")
                .font(NQText.captionS.font.weight(.heavy))
                .foregroundStyle(NQTheme.gold)
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: - Helpers

    private func startOfMonth(_ date: Date) -> Date {
        calendar.date(from: calendar.dateComponents([.year, .month], from: date)) ?? date
    }
}

// MARK: - Buckets

/// One local calendar day, merged from the server's per-day counters and the
/// workouts whose start falls on that day.
private struct ActivityBucket {
    var workouts: [JourneyWorkout] = []
    var steps: Int?
    var activeCalories: Int?
    var exerciseMinutes: Int?

    var workoutMinutes: Double { workouts.reduce(0) { $0 + $1.durationMinutes } }

    var hasActivity: Bool {
        !workouts.isEmpty || (steps ?? 0) > 0 || (activeCalories ?? 0) > 0 || (exerciseMinutes ?? 0) > 0
    }

    /// 0…1 shading for the calendar cell; an hour of workouts is "full".
    var intensity: Double {
        min(1, workoutMinutes / 60)
    }
}

/// The server groups by UTC day. Workouts carry a full timestamp, so re-key
/// them by the phone's local day; the day counters keep the server's key.
private struct ActivityBuckets {
    private var byKey: [String: ActivityBucket] = [:]
    private let formatter: DateFormatter

    init(days: [JourneyActivityDay], calendar: Calendar) {
        let f = DateFormatter()
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        formatter = f

        for day in days {
            byKey[day.date, default: ActivityBucket()].steps = day.steps
            byKey[day.date, default: ActivityBucket()].activeCalories = day.activeCalories
            byKey[day.date, default: ActivityBucket()].exerciseMinutes = day.exerciseMinutes
            for workout in day.workouts {
                let key = workout.startDate.map(f.string(from:)) ?? day.date
                byKey[key, default: ActivityBucket()].workouts.append(workout)
            }
        }
        for key in byKey.keys {
            byKey[key]?.workouts.sort { $0.start < $1.start }
        }
    }

    subscript(key: String) -> ActivityBucket? { byKey[key] }

    func key(for date: Date) -> String { formatter.string(from: date) }
    func date(for key: String) -> Date? { formatter.date(from: key) }

    var latestActiveKey: String? {
        byKey.filter { $0.value.hasActivity }.keys.max()
    }

    var earliestDate: Date? {
        byKey.keys.min().flatMap(date(for:))
    }
}

// MARK: - Workout presentation

private extension JourneyWorkout {
    /// SF Symbol for the HealthKit activity name; all of these ship in iOS 16.
    var symbolName: String {
        let type = activityType.lowercased()
        if type.contains("run") { return "figure.run" }
        if type.contains("walk") { return "figure.walk" }
        if type.contains("hik") { return "figure.hiking" }
        if type.contains("cycl") || type.contains("bik") { return "figure.outdoor.cycle" }
        if type.contains("swim") { return "figure.pool.swim" }
        if type.contains("strength") || type.contains("weight") { return "dumbbell.fill" }
        if type.contains("yoga") || type.contains("pilates") { return "figure.yoga" }
        if type.contains("interval") || type.contains("hiit") { return "figure.highintensity.intervaltraining" }
        if type.contains("row") { return "figure.rower" }
        if type.contains("ellip") { return "figure.elliptical" }
        if type.contains("stair") { return "figure.stairs" }
        if type.contains("core") { return "figure.core.training" }
        return "figure.mixed.cardio"
    }

    /// "7:02 AM · 280 kcal · 5.1 km · 148 bpm" with whatever is present.
    var detailLine: String {
        var parts: [String] = []
        if let start = startDate {
            parts.append(start.formatted(.dateTime.hour().minute()))
        }
        if let kcal = activeCalories, kcal > 0 {
            parts.append("\(Int(kcal.rounded())) kcal")
        }
        if let meters = distanceMeters, meters > 0 {
            let km = Measurement(value: meters, unit: UnitLength.meters).converted(to: .kilometers)
            parts.append(km.formatted(.measurement(width: .abbreviated, usage: .road)))
        }
        if let bpm = averageHeartRateBpm, bpm > 0 {
            parts.append("\(Int(bpm.rounded())) bpm")
        }
        return parts.joined(separator: " · ")
    }
}
