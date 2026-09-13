import Foundation
import HealthKit

/// The phone-side producer for `POST /vitals`: reads HealthKit, uploads the
/// snapshot, and reports whether anything was sent. Owns no UI state — the
/// screens and GameState decide what to show.
///
/// Foreground-only by design (no `HKObserverQuery` / background delivery):
/// `GameState.syncHealthIfLinked()` runs it on launch and whenever the app
/// returns to the foreground, which is when the watch has just synced anyway.
@MainActor
final class HealthSyncService {

    static let shared = HealthSyncService()

    private let healthKit = HealthKitManager.shared
    private let api = APIClient.shared

    /// `-mockHealthKit` launch argument: upload a fixed snapshot instead of
    /// reading HealthKit, so the simulator (no watch, empty queries) can
    /// exercise the connect → upload → multiplier path for QA screenshots.
    private let useMockSnapshot = ProcessInfo.processInfo.arguments.contains("-mockHealthKit")

    private init() {}

    var isHealthDataAvailable: Bool {
        useMockSnapshot || healthKit.isHealthDataAvailable
    }

    /// Whether the system permission sheet has been shown for the current
    /// set of read types. HealthKit never reveals *read* grants, so this is
    /// the closest thing to "connected" the phone can know.
    var hasRequestedAuthorization: Bool {
        useMockSnapshot || healthKit.hasRequestedAuthorization
    }

    /// Reads the current snapshot and uploads it.
    ///
    /// Returns `true` when a snapshot was sent. Returns `false` when HealthKit
    /// had nothing at all (permission declined, or simply no data yet) — that
    /// is not an error, and an all-null snapshot is deliberately not uploaded
    /// so `/vitals/latest` keeps the last real reading.
    @discardableResult
    func sync(requestAuthorizationIfNeeded: Bool) async throws -> Bool {
        let snapshot: HealthKitSnapshot
        if useMockSnapshot {
            snapshot = .mock()
        } else {
            guard healthKit.isHealthDataAvailable else { throw HealthKitError.notAvailable }
            if requestAuthorizationIfNeeded, !healthKit.hasRequestedAuthorization {
                try await healthKit.requestAuthorization()
            }
            snapshot = try await healthKit.fetchCurrentSnapshot()
        }

        guard !snapshot.hasNoMetrics else { return false }
        _ = try await api.uploadVitals(snapshot)
        return true
    }
}
