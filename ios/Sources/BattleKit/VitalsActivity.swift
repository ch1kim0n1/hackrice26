import Foundation

/// One HealthKit snapshot's gameplay-relevant activity, distilled from the
/// watch → backend vitals pipeline (backend/src/vitals). Feeds the Daily
/// Party Multiplier so Watch Connect visibly affects play (issue #27).
public struct VitalsActivity: Sendable, Equatable {
    public let stepsToday: Int?
    public let exerciseMinutesToday: Int?
    public let standHoursToday: Int?
    /// Active energy burned today in kilocalories, from the watch's
    /// HealthKit snapshot. nil when the snapshot omitted the metric.
    public let activeCaloriesToday: Int?

    /// Creates a snapshot of today's watch activity; any metric the watch
    /// did not report should be passed as nil.
    public init(
        stepsToday: Int?,
        exerciseMinutesToday: Int?,
        standHoursToday: Int?,
        activeCaloriesToday: Int? = nil
    ) {
        self.stepsToday = stepsToday
        self.exerciseMinutesToday = exerciseMinutesToday
        self.standHoursToday = standHoursToday
        self.activeCaloriesToday = activeCaloriesToday
    }

    /// Goals mirror backend/src/vitals/vitalsAnalysis.ts:
    /// 10,000 steps / 30 exercise minutes / 12 stand hours.
    public static let stepGoal = 10_000
    public static let exerciseGoalMinutes = 30
    public static let standGoalHours = 12
    /// Daily active-burn goal in kilocalories for the Home burn ring.
    /// Display-only — it does not feed the multiplier bonus.
    public static let burnGoalCalories = 500

    /// Additive bonus for the Daily Party Multiplier, capped at +0.10 so a
    /// perfect activity day can never outweigh nutrition (food is the core
    /// loop; movement is the tiebreaker). Missing metrics contribute 0 —
    /// a partial snapshot still earns what it earned.
    public var bonus: Double {
        let steps = stepsToday.map { min(Double($0) / Double(Self.stepGoal), 1) * 0.06 } ?? 0
        let exercise = exerciseMinutesToday.map { min(Double($0) / Double(Self.exerciseGoalMinutes), 1) * 0.06 } ?? 0
        let stand = standHoursToday.map { min(Double($0) / Double(Self.standGoalHours), 1) * 0.03 } ?? 0
        return min(steps + exercise + stand, 0.10)
    }

    /// Progress 0...1 per ring, for the Home card's activity row.
    public var stepProgress: Double { stepsToday.map { min(Double($0) / Double(Self.stepGoal), 1) } ?? 0 }
    public var exerciseProgress: Double { exerciseMinutesToday.map { min(Double($0) / Double(Self.exerciseGoalMinutes), 1) } ?? 0 }
    public var standProgress: Double { standHoursToday.map { min(Double($0) / 12, 1) } ?? 0 }
    /// Progress 0...1 toward the daily active-burn goal, for the Home burn ring.
    public var burnProgress: Double { activeCaloriesToday.map { min(Double($0) / Double(Self.burnGoalCalories), 1) } ?? 0 }

    /// No snapshot received yet.
    public static let none = VitalsActivity(stepsToday: nil, exerciseMinutesToday: nil, standHoursToday: nil)
}
