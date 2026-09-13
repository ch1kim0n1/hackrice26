import Foundation
import HealthKit

enum HealthKitError: LocalizedError {
    case notAvailable
    case authorizationFailed(String)

    var errorDescription: String? {
        switch self {
        case .notAvailable:
            return "Health data is unavailable on this device."
        case .authorizationFailed(let reason):
            return "Could not request Health permissions: \(reason)"
        }
    }
}

/// Owns the app's single `HKHealthStore` and turns HealthKit samples into plain
/// Swift values. Deliberately contains no SwiftUI or networking code.
final class HealthKitManager {

    static let shared = HealthKitManager()

    private let healthStore = HKHealthStore()
    private let requestedTypesKey = "healthkit.requestedTypeIdentifiers"

    /// Only the types this prototype actually reads. Requesting more would be
    /// asking testers for data we never use.
    private let readTypes: Set<HKObjectType> = [
        HKQuantityType(.heartRate),
        HKQuantityType(.restingHeartRate),
        HKQuantityType(.heartRateVariabilitySDNN),
        HKQuantityType(.stepCount),
        HKQuantityType(.activeEnergyBurned),
        // Distance types are read only to report workout distance.
        HKQuantityType(.distanceWalkingRunning),
        HKQuantityType(.distanceCycling),
        // The Fitness app's rings (exercise minutes, stand hours, and goals).
        HKObjectType.activitySummaryType(),
        // Completed workouts.
        HKObjectType.workoutType()
    ]

    private init() {}

    var isHealthDataAvailable: Bool {
        HKHealthStore.isHealthDataAvailable()
    }

    /// Stable fingerprint of the types we currently ask for.
    private var readTypeFingerprint: String {
        readTypes.map(\.identifier).sorted().joined(separator: ",")
    }

    /// HealthKit intentionally never reports *read* permission (that would leak
    /// whether the user has data), so all we can track is whether the system
    /// sheet has already been shown. Used to avoid re-prompting on every launch.
    ///
    /// This records *which* types were requested, not merely that we asked. When
    /// a new metric is added to `readTypes` the fingerprint changes and the app
    /// asks again -- otherwise the new types would never be authorized and would
    /// silently read back as empty, which looks identical to "no data".
    var hasRequestedAuthorization: Bool {
        UserDefaults.standard.string(forKey: requestedTypesKey) == readTypeFingerprint
    }

    // MARK: - Authorization

    func requestAuthorization() async throws {
        guard isHealthDataAvailable else { throw HealthKitError.notAvailable }

        do {
            try await healthStore.requestAuthorization(toShare: [], read: readTypes)
            UserDefaults.standard.set(readTypeFingerprint, forKey: requestedTypesKey)
        } catch {
            throw HealthKitError.authorizationFailed(error.localizedDescription)
        }
    }

    // MARK: - Individual metrics

    /// Most recent heart-rate sample, in BPM.
    func latestHeartRate() async -> Double? {
        await latestQuantity(HKQuantityType(.heartRate),
                             unit: .count().unitDivided(by: .minute()))
    }

    /// Most recent resting heart rate, in BPM. Watch-derived, usually one per day.
    func restingHeartRate() async -> Double? {
        await latestQuantity(HKQuantityType(.restingHeartRate),
                             unit: .count().unitDivided(by: .minute()))
    }

    /// Most recent HRV (SDNN) sample, in milliseconds.
    func latestHRV() async -> Double? {
        await latestQuantity(HKQuantityType(.heartRateVariabilitySDNN),
                             unit: .secondUnit(with: .milli))
    }

    /// Steps from the start of the current local calendar day until now.
    func stepsToday() async -> Double? {
        await sumSinceStartOfDay(HKQuantityType(.stepCount), unit: .count())
    }

    /// Active energy burned since the start of the current local day, in kcal.
    func activeCaloriesToday() async -> Double? {
        await sumSinceStartOfDay(HKQuantityType(.activeEnergyBurned), unit: .kilocalorie())
    }

    // MARK: - Activity rings

    /// Today's Activity summary: the same numbers the Fitness app draws.
    ///
    /// Preferred over querying `appleExerciseTime` / `appleStandTime` directly
    /// because it also carries the user's goals, and because the ring's stand
    /// figure is a count of *hours* -- `appleStandTime` is minutes spent
    /// standing, which is a different number that will not match the watch.
    func todaysActivitySummary() async -> HKActivitySummary? {
        await withCheckedContinuation { continuation in
            let calendar = Calendar.current
            var components = calendar.dateComponents([.year, .month, .day], from: Date())
            components.calendar = calendar

            let predicate = HKQuery.predicateForActivitySummary(with: components)
            let query = HKActivitySummaryQuery(predicate: predicate) { _, summaries, _ in
                continuation.resume(returning: summaries?.first)
            }
            healthStore.execute(query)
        }
    }

    // MARK: - Workouts

    /// Most recently completed workouts, newest first.
    ///
    /// Note this is finished workouts only. A workout currently being tracked on
    /// the Watch is not visible to us: HealthKit publishes the sample when the
    /// session ends and syncs. Live data would require our own watchOS app
    /// running an `HKWorkoutSession`, which the MVP deliberately does not do.
    func recentWorkouts(limit: Int = 5, withinDays days: Int = 7) async -> [WorkoutSummary] {
        await withCheckedContinuation { continuation in
            let now = Date()
            let start = Calendar.current.date(byAdding: .day, value: -days, to: now) ?? now
            let predicate = HKQuery.predicateForSamples(withStart: start, end: now, options: [])
            let newestFirst = NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)

            let query = HKSampleQuery(
                sampleType: HKObjectType.workoutType(),
                predicate: predicate,
                limit: limit,
                sortDescriptors: [newestFirst]
            ) { _, samples, _ in
                let workouts = (samples as? [HKWorkout] ?? []).map(WorkoutSummary.init(workout:))
                continuation.resume(returning: workouts)
            }
            healthStore.execute(query)
        }
    }

    // MARK: - Snapshot

    /// Fetches every supported metric and returns one snapshot.
    ///
    /// The metrics are independent, so they run concurrently: a slow query for
    /// one type does not hold up the others. A metric that is missing or
    /// inaccessible yields `nil` instead of failing the whole snapshot.
    func fetchCurrentSnapshot(testerID: String) async throws -> HealthSnapshot {
        guard isHealthDataAvailable else { throw HealthKitError.notAvailable }

        async let heartRate = self.latestHeartRate()
        async let resting = self.restingHeartRate()
        async let hrv = self.latestHRV()
        async let steps = self.stepsToday()
        async let activeCalories = self.activeCaloriesToday()
        async let summary = self.todaysActivitySummary()
        async let workouts = self.recentWorkouts()

        let rings = await summary
        let minute = HKUnit.minute()
        let count = HKUnit.count()

        return await HealthSnapshot(
            timestamp: Date(),
            testerID: testerID,
            heartRateBPM: heartRate,
            restingHeartRateBPM: resting,
            hrvMilliseconds: hrv,
            stepsToday: steps,
            activeCaloriesToday: activeCalories,
            exerciseMinutesToday: rings?.appleExerciseTime.doubleValue(for: minute),
            exerciseGoalMinutes: rings?.exerciseTimeGoal?.doubleValue(for: minute),
            standHoursToday: rings?.appleStandHours.doubleValue(for: count),
            standGoalHours: rings?.standHoursGoal?.doubleValue(for: count),
            recentWorkouts: workouts
        )
    }

    // MARK: - Query helpers

    /// Newest single sample of a quantity type, or `nil` if there is none.
    private func latestQuantity(_ type: HKQuantityType, unit: HKUnit) async -> Double? {
        await withCheckedContinuation { continuation in
            let newestFirst = NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)
            let query = HKSampleQuery(
                sampleType: type,
                predicate: nil,
                limit: 1,
                sortDescriptors: [newestFirst]
            ) { _, samples, _ in
                // An error here (typically "no permission") is not exceptional
                // for us: the metric is simply unavailable.
                let value = (samples?.first as? HKQuantitySample)?.quantity.doubleValue(for: unit)
                continuation.resume(returning: value)
            }
            healthStore.execute(query)
        }
    }

    /// Cumulative total for a quantity type from local midnight until now.
    ///
    /// Uses an anchored statistics *collection* query rather than a plain
    /// statistics query. The reason is boundary samples: a walk that starts at
    /// 11:58pm and ends at 12:03am belongs partly to today. A predicate with
    /// `.strictStartDate` drops that sample outright (its start is yesterday),
    /// which undercounts the day. Anchoring a one-day interval at midnight makes
    /// HealthKit apportion such samples across the boundary, which is how the
    /// Health app arrives at its own daily figure.
    private func sumSinceStartOfDay(_ type: HKQuantityType, unit: HKUnit) async -> Double? {
        await withCheckedContinuation { continuation in
            let now = Date()
            let startOfDay = Calendar.current.startOfDay(for: now)

            // No `.strictStartDate` here: we want samples that merely overlap
            // today, and let the collection query split them.
            let predicate = HKQuery.predicateForSamples(
                withStart: startOfDay,
                end: now,
                options: []
            )

            let query = HKStatisticsCollectionQuery(
                quantityType: type,
                quantitySamplePredicate: predicate,
                options: .cumulativeSum,
                anchorDate: startOfDay,
                intervalComponents: DateComponents(day: 1)
            )

            query.initialResultsHandler = { _, collection, _ in
                let total = collection?
                    .statistics(for: startOfDay)?
                    .sumQuantity()?
                    .doubleValue(for: unit)
                continuation.resume(returning: total)
            }

            healthStore.execute(query)
        }
    }
}

// MARK: - HealthKit conversions

private extension WorkoutSummary {

    /// Reads totals via `statistics(for:)` rather than `totalEnergyBurned` /
    /// `totalDistance`, which Apple deprecated in iOS 18.
    init(workout: HKWorkout) {
        let bpm = HKUnit.count().unitDivided(by: .minute())
        let heartRate = workout.statistics(for: HKQuantityType(.heartRate))

        // Whichever distance type this activity recorded, if any.
        let distance = workout.statistics(for: HKQuantityType(.distanceWalkingRunning))?.sumQuantity()
            ?? workout.statistics(for: HKQuantityType(.distanceCycling))?.sumQuantity()

        self.init(
            activityType: workout.workoutActivityType.displayName,
            start: workout.startDate,
            end: workout.endDate,
            durationMinutes: workout.duration / 60,
            activeCalories: workout.statistics(for: HKQuantityType(.activeEnergyBurned))?
                .sumQuantity()?.doubleValue(for: .kilocalorie()),
            distanceMeters: distance?.doubleValue(for: .meter()),
            averageHeartRateBPM: heartRate?.averageQuantity()?.doubleValue(for: bpm),
            maxHeartRateBPM: heartRate?.maximumQuantity()?.doubleValue(for: bpm)
        )
    }
}

private extension HKWorkoutActivityType {

    /// Names for the activities people actually log on an Apple Watch. The enum
    /// has ~80 cases; anything unlisted falls back to "Workout" rather than
    /// leaking a raw integer into the payload.
    var displayName: String {
        switch self {
        case .running: return "Running"
        case .walking: return "Walking"
        case .hiking: return "Hiking"
        case .cycling: return "Cycling"
        case .swimming: return "Swimming"
        case .elliptical: return "Elliptical"
        case .rowing: return "Rowing"
        case .stairClimbing: return "Stair Climbing"
        case .highIntensityIntervalTraining: return "HIIT"
        case .functionalStrengthTraining: return "Functional Strength Training"
        case .traditionalStrengthTraining: return "Traditional Strength Training"
        case .coreTraining: return "Core Training"
        case .yoga: return "Yoga"
        case .pilates: return "Pilates"
        case .barre: return "Barre"
        case .dance, .cardioDance, .socialDance: return "Dance"
        case .mixedCardio: return "Mixed Cardio"
        case .flexibility: return "Flexibility"
        case .cooldown: return "Cooldown"
        case .basketball: return "Basketball"
        case .soccer: return "Soccer"
        case .tennis: return "Tennis"
        case .golf: return "Golf"
        case .americanFootball: return "Football"
        case .baseball: return "Baseball"
        case .volleyball: return "Volleyball"
        case .badminton: return "Badminton"
        case .tableTennis: return "Table Tennis"
        case .boxing, .kickboxing: return "Boxing"
        case .martialArts: return "Martial Arts"
        case .climbing: return "Climbing"
        case .skatingSports: return "Skating"
        case .snowSports, .downhillSkiing, .snowboarding: return "Snow Sports"
        case .surfingSports: return "Surfing"
        case .paddleSports: return "Paddle Sports"
        case .wheelchairWalkPace, .wheelchairRunPace: return "Wheelchair"
        case .crossTraining: return "Cross Training"
        case .preparationAndRecovery: return "Preparation & Recovery"
        case .other: return "Workout"
        default: return "Workout"
        }
    }
}
