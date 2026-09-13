import XCTest
@testable import NutriQuest

/// The wire contract for `POST /vitals` lives in
/// `backend/src/vitals/validateSnapshot.ts`; these pin the phone-side half of
/// it: key casing, explicit nulls, ISO-8601 dates, and in-range mock values.
final class HealthKitSnapshotTests: XCTestCase {

    private func encode(_ snapshot: HealthKitSnapshot) throws -> [String: Any] {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(snapshot)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testMissingMetricsEncodeAsExplicitNull() throws {
        let snapshot = HealthKitSnapshot(
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            heartRateBPM: nil, restingHeartRateBPM: nil, hrvMilliseconds: nil,
            stepsToday: 1234, activeCaloriesToday: nil,
            exerciseMinutesToday: nil, exerciseGoalMinutes: nil,
            standHoursToday: nil, standGoalHours: nil,
            recentWorkouts: []
        )
        let json = try encode(snapshot)

        for key in ["heartRateBpm", "restingHeartRateBpm", "hrvMs", "activeCaloriesToday",
                    "exerciseMinutesToday", "exerciseGoalMinutes", "standHoursToday", "standGoalHours"] {
            XCTAssertTrue(json.keys.contains(key), "\(key) must be present")
            XCTAssertTrue(json[key] is NSNull, "\(key) must be null, got \(String(describing: json[key]))")
        }
        XCTAssertEqual(json["stepsToday"] as? Double, 1234)
        XCTAssertEqual(json["timestamp"] as? String, "2023-11-14T22:13:20Z")
        XCTAssertNil(json["testerId"], "main app never sends a tester id")
        XCTAssertEqual((json["recentWorkouts"] as? [Any])?.count, 0)
        XCTAssertFalse(snapshot.hasNoMetrics)
    }

    func testEmptySnapshotIsNotUploadable() {
        let empty = HealthKitSnapshot(
            timestamp: Date(),
            heartRateBPM: nil, restingHeartRateBPM: nil, hrvMilliseconds: nil,
            stepsToday: nil, activeCaloriesToday: nil,
            exerciseMinutesToday: nil, exerciseGoalMinutes: nil,
            standHoursToday: nil, standGoalHours: nil,
            recentWorkouts: []
        )
        XCTAssertTrue(empty.hasNoMetrics)
    }

    func testWorkoutKeysMatchBackendCasing() throws {
        let json = try encode(.mock(now: Date(timeIntervalSince1970: 1_700_000_000)))
        let workout = try XCTUnwrap((json["recentWorkouts"] as? [[String: Any]])?.first)
        XCTAssertEqual(workout["activityType"] as? String, "Running")
        XCTAssertEqual(workout["averageHeartRateBpm"] as? Double, 148)
        XCTAssertEqual(workout["maxHeartRateBpm"] as? Double, 171)
        XCTAssertEqual(workout["start"] as? String, "2023-11-14T19:13:20Z")
        XCTAssertEqual(workout["end"] as? String, "2023-11-14T19:41:20Z")
        XCTAssertEqual(workout["durationMinutes"] as? Double, 28)
    }

    /// Mirrors the range table in validateSnapshot.ts so `-mockHealthKit`
    /// can never produce a 422.
    func testMockSnapshotIsWithinBackendRanges() {
        let m = HealthKitSnapshot.mock()
        XCTAssertTrue((20...250).contains(m.heartRateBPM!))
        XCTAssertTrue((20...150).contains(m.restingHeartRateBPM!))
        XCTAssertTrue((0...500).contains(m.hrvMilliseconds!))
        XCTAssertTrue((0...200_000).contains(m.stepsToday!))
        XCTAssertTrue((0...20_000).contains(m.activeCaloriesToday!))
        XCTAssertTrue((0...1440).contains(m.exerciseMinutesToday!))
        XCTAssertTrue((0...1440).contains(m.exerciseGoalMinutes!))
        XCTAssertTrue((0...24).contains(m.standHoursToday!))
        XCTAssertTrue((0...24).contains(m.standGoalHours!))
        XCTAssertLessThanOrEqual(m.recentWorkouts.count, 50)
        for w in m.recentWorkouts {
            XCTAssertTrue((0...1440).contains(w.durationMinutes))
            XCTAssertTrue((1...64).contains(w.activityType.count))
            XCTAssertLessThan(w.start, w.end)
        }
    }
}
