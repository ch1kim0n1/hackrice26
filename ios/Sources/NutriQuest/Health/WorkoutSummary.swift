import Foundation

/// One completed workout, flattened to plain values for JSON.
///
/// Deliberately Foundation-only: the HealthKit conversion lives in
/// `HealthKitManager`, so this stays testable off-device.
struct WorkoutSummary: Codable, Equatable, Identifiable {

    /// Start time is unique enough per workout for list diffing.
    var id: String { "\(activityType)-\(start.timeIntervalSince1970)" }

    /// Human-readable activity, e.g. "Running", "Functional Strength Training".
    let activityType: String
    let start: Date
    let end: Date
    let durationMinutes: Double

    // Any of these can be absent: an indoor walk has no distance, a workout
    // logged without the Watch on has no heart rate.
    let activeCalories: Double?
    let distanceMeters: Double?
    let averageHeartRateBPM: Double?
    let maxHeartRateBPM: Double?

    enum CodingKeys: String, CodingKey {
        case activityType
        case start
        case end
        case durationMinutes
        case activeCalories
        case distanceMeters
        case averageHeartRateBPM = "averageHeartRateBpm"
        case maxHeartRateBPM = "maxHeartRateBpm"
    }

    /// Explicit nulls for the same reason as `HealthSnapshot`: a missing value
    /// should arrive as `null`, not vanish from the payload.
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(activityType, forKey: .activityType)
        try container.encode(start, forKey: .start)
        try container.encode(end, forKey: .end)
        try container.encode(durationMinutes, forKey: .durationMinutes)
        try container.encode(activeCalories, forKey: .activeCalories)
        try container.encode(distanceMeters, forKey: .distanceMeters)
        try container.encode(averageHeartRateBPM, forKey: .averageHeartRateBPM)
        try container.encode(maxHeartRateBPM, forKey: .maxHeartRateBPM)
    }
}
