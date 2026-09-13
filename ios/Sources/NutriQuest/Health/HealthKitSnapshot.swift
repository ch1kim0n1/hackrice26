import Foundation

/// One point-in-time reading of the HealthKit metrics the game uses. This is
/// the body of `POST /vitals`; `backend/src/types.ts` mirrors it 1:1.
///
/// Every metric is optional on purpose: HealthKit may simply have no sample for
/// a given type (no Apple Watch worn today, permission not granted, metric not
/// supported by the device). `nil` means "unavailable", which is semantically
/// different from `0`, so we never substitute zeros.
struct HealthKitSnapshot: Codable, Equatable {

    let timestamp: Date

    let heartRateBPM: Double?
    let restingHeartRateBPM: Double?
    let hrvMilliseconds: Double?
    let stepsToday: Double?
    let activeCaloriesToday: Double?

    // Activity ring figures, straight from the Fitness app's own summary.
    // `standHoursToday` is the ring's hour count (goal 12), not minutes spent
    // standing -- those are different HealthKit values with similar names.
    let exerciseMinutesToday: Double?
    let exerciseGoalMinutes: Double?
    let standHoursToday: Double?
    let standGoalHours: Double?

    /// Most recent completed workouts. Empty means none were found in the
    /// lookback window; a workout only lands here after it ends and syncs.
    let recentWorkouts: [WorkoutSummary]

    /// Wire names are camelCase to match `backend/src/types.ts`. Only the
    /// acronym casing differs from the Swift property names (BPM -> Bpm), so
    /// the mapping is spelled out rather than derived.
    enum CodingKeys: String, CodingKey {
        case timestamp
        case heartRateBPM = "heartRateBpm"
        case restingHeartRateBPM = "restingHeartRateBpm"
        case hrvMilliseconds = "hrvMs"
        case stepsToday
        case activeCaloriesToday
        case exerciseMinutesToday
        case exerciseGoalMinutes
        case standHoursToday
        case standGoalHours
        case recentWorkouts
    }

    /// True when HealthKit returned nothing at all, which usually means the user
    /// declined the permission sheet or has no data on this device. Such a
    /// snapshot is not uploaded — it would only pollute the vitals history.
    var hasNoMetrics: Bool {
        heartRateBPM == nil
            && restingHeartRateBPM == nil
            && hrvMilliseconds == nil
            && stepsToday == nil
            && activeCaloriesToday == nil
            && exerciseMinutesToday == nil
            && standHoursToday == nil
            && recentWorkouts.isEmpty
    }

    /// The synthesized encoder uses `encodeIfPresent` for optionals, which would
    /// drop missing metrics from the JSON entirely. The backend contract expects
    /// an explicit `null`, so encode every key.
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(timestamp, forKey: .timestamp)
        try container.encode(heartRateBPM, forKey: .heartRateBPM)
        try container.encode(restingHeartRateBPM, forKey: .restingHeartRateBPM)
        try container.encode(hrvMilliseconds, forKey: .hrvMilliseconds)
        try container.encode(stepsToday, forKey: .stepsToday)
        try container.encode(activeCaloriesToday, forKey: .activeCaloriesToday)
        try container.encode(exerciseMinutesToday, forKey: .exerciseMinutesToday)
        try container.encode(exerciseGoalMinutes, forKey: .exerciseGoalMinutes)
        try container.encode(standHoursToday, forKey: .standHoursToday)
        try container.encode(standGoalHours, forKey: .standGoalHours)
        try container.encode(recentWorkouts, forKey: .recentWorkouts)
    }
}

extension HealthKitSnapshot {
    /// Fixed, plausible numbers for the `-mockHealthKit` launch argument so
    /// the simulator (which has no watch data) can exercise the whole
    /// Connect → upload → multiplier path.
    static func mock(now: Date = Date()) -> HealthKitSnapshot {
        HealthKitSnapshot(
            timestamp: now,
            heartRateBPM: 72,
            restingHeartRateBPM: 58,
            hrvMilliseconds: 48,
            stepsToday: 6400,
            activeCaloriesToday: 320,
            exerciseMinutesToday: 22,
            exerciseGoalMinutes: 30,
            standHoursToday: 7,
            standGoalHours: 12,
            recentWorkouts: [
                WorkoutSummary(
                    activityType: "Running",
                    start: now.addingTimeInterval(-3 * 60 * 60),
                    end: now.addingTimeInterval(-3 * 60 * 60 + 28 * 60),
                    durationMinutes: 28,
                    activeCalories: 245,
                    distanceMeters: 4200,
                    averageHeartRateBPM: 148,
                    maxHeartRateBPM: 171
                )
            ]
        )
    }
}
