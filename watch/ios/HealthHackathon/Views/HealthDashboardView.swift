import SwiftUI

/// Drives the dashboard. Owns all state the UI shows and delegates the real work
/// to `HealthKitManager` and `APIClient`.
@MainActor
final class HealthDashboardViewModel: ObservableObject {

    enum AuthorizationState: Equatable {
        case unavailable        // HealthKit not supported on this device
        case notRequested       // permission sheet not shown yet
        case requested          // sheet shown; HealthKit never tells us the answer
    }

    enum UploadState: Equatable {
        case idle
        case sending
        case succeeded(String)
        case failed(String, retryable: Bool)
    }

    @Published private(set) var authorizationState: AuthorizationState
    @Published private(set) var snapshot: HealthSnapshot?
    @Published private(set) var isLoadingHealthData = false
    @Published private(set) var uploadState: UploadState = .idle
    @Published private(set) var healthErrorMessage: String?
    @Published var backendBaseURL: String = AppConfig.backendBaseURL

    let testerID = AppConfig.testerID

    private let healthKit: HealthKitManager
    private let api: APIClient

    init(healthKit: HealthKitManager = .shared, api: APIClient = .shared) {
        self.healthKit = healthKit
        self.api = api

        if !healthKit.isHealthDataAvailable {
            authorizationState = .unavailable
        } else if healthKit.hasRequestedAuthorization {
            authorizationState = .requested
        } else {
            authorizationState = .notRequested
        }
    }

    var canRequestAuthorization: Bool {
        authorizationState == .notRequested
    }

    /// Shows the system permission sheet once, then loads data.
    /// Not re-shown on later launches: iOS would silently ignore it anyway.
    func connectAppleHealth() async {
        healthErrorMessage = nil
        do {
            try await healthKit.requestAuthorization()
            authorizationState = .requested
            await refresh()
        } catch {
            healthErrorMessage = error.localizedDescription
            if let healthKitError = error as? HealthKitError,
               case .notAvailable = healthKitError {
                authorizationState = .unavailable
            }
        }
    }

    func refresh() async {
        guard authorizationState != .unavailable else {
            healthErrorMessage = HealthKitError.notAvailable.localizedDescription
            return
        }

        isLoadingHealthData = true
        healthErrorMessage = nil
        defer { isLoadingHealthData = false }

        do {
            let fetched = try await healthKit.fetchCurrentSnapshot(testerID: testerID)
            snapshot = fetched
            if fetched.hasNoMetrics {
                healthErrorMessage = """
                No health data was returned. Grant this app access in \
                Settings › Privacy & Security › Health, and make sure your Apple Watch \
                has synced to this iPhone.
                """
            }
        } catch {
            healthErrorMessage = error.localizedDescription
        }
    }

    func sendToBackend() async {
        guard let snapshot else { return }

        AppConfig.backendBaseURL = backendBaseURL
        uploadState = .sending
        do {
            let response = try await api.send(snapshot, baseURL: backendBaseURL)
            uploadState = .succeeded(response.message ?? "Snapshot received")
        } catch let error as APIError {
            uploadState = .failed(error.localizedDescription, retryable: error.isRetryable)
        } catch {
            uploadState = .failed(error.localizedDescription, retryable: true)
        }
    }
}

struct HealthDashboardView: View {

    @StateObject private var viewModel = HealthDashboardViewModel()

    var body: some View {
        NavigationStack {
            Form {
                authorizationSection
                metricsSection
                workoutsSection
                backendSection
            }
            .navigationTitle("Hackathon Health Data")
            .disclaimerFooter()
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private var authorizationSection: some View {
        Section("Apple Health") {
            switch viewModel.authorizationState {
            case .unavailable:
                Label("Health data is unavailable on this device.", systemImage: "xmark.circle")
                    .foregroundStyle(.secondary)
            case .notRequested:
                Button("Connect Apple Health") {
                    Task { await viewModel.connectAppleHealth() }
                }
            case .requested:
                Label("Health access requested", systemImage: "checkmark.circle")
                    .foregroundStyle(.secondary)
            }

            if let message = viewModel.healthErrorMessage {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        }
    }

    @ViewBuilder
    private var metricsSection: some View {
        Section("Latest Snapshot") {
            if viewModel.isLoadingHealthData && viewModel.snapshot == nil {
                HStack {
                    ProgressView()
                    Text("Reading Health data…").foregroundStyle(.secondary)
                }
            } else {
                MetricRow(title: "Heart Rate",
                          value: viewModel.snapshot?.heartRateBPM,
                          unit: "BPM",
                          fractionDigits: 0)
                MetricRow(title: "Resting HR",
                          value: viewModel.snapshot?.restingHeartRateBPM,
                          unit: "BPM",
                          fractionDigits: 0)
                MetricRow(title: "HRV",
                          value: viewModel.snapshot?.hrvMilliseconds,
                          unit: "ms",
                          fractionDigits: 0)
                MetricRow(title: "Steps Today",
                          value: viewModel.snapshot?.stepsToday,
                          unit: nil,
                          fractionDigits: 0)
                MetricRow(title: "Active Calories",
                          value: viewModel.snapshot?.activeCaloriesToday,
                          unit: "kcal",
                          fractionDigits: 0)
                MetricRow(title: "Exercise",
                          value: viewModel.snapshot?.exerciseMinutesToday,
                          unit: goalSuffix(viewModel.snapshot?.exerciseGoalMinutes, unit: "min"),
                          fractionDigits: 0)
                MetricRow(title: "Stand Hours",
                          value: viewModel.snapshot?.standHoursToday,
                          unit: goalSuffix(viewModel.snapshot?.standGoalHours, unit: "hr"),
                          fractionDigits: 0)
            }

            Button {
                Task { await viewModel.refresh() }
            } label: {
                if viewModel.isLoadingHealthData {
                    HStack { ProgressView(); Text("Refreshing…") }
                } else {
                    Text("Refresh Health Data")
                }
            }
            .disabled(viewModel.isLoadingHealthData
                      || viewModel.authorizationState == .unavailable)
        }
    }

    /// Renders "min" or "of 30 min" so the ring goal shows when HealthKit has one.
    private func goalSuffix(_ goal: Double?, unit: String) -> String {
        guard let goal, goal > 0 else { return unit }
        return "of \(goal.formatted(.number.precision(.fractionLength(0)))) \(unit)"
    }

    @ViewBuilder
    private var workoutsSection: some View {
        Section("Recent Workouts") {
            let workouts = viewModel.snapshot?.recentWorkouts ?? []
            if workouts.isEmpty {
                Text(viewModel.snapshot == nil
                     ? "Refresh to load workouts."
                     : "No workouts in the last 7 days.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(workouts) { workout in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(workout.activityType).fontWeight(.medium)
                            Spacer()
                            Text(workout.start, format: .dateTime.month().day().hour().minute())
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Text(workoutDetail(workout))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }

    /// One line of whatever this workout actually recorded. Indoor workouts have
    /// no distance; a workout logged without the Watch has no heart rate.
    private func workoutDetail(_ workout: WorkoutSummary) -> String {
        var parts: [String] = [
            "\(workout.durationMinutes.formatted(.number.precision(.fractionLength(0)))) min"
        ]
        if let calories = workout.activeCalories {
            parts.append("\(calories.formatted(.number.precision(.fractionLength(0)))) kcal")
        }
        if let meters = workout.distanceMeters, meters > 0 {
            let km = meters / 1000
            parts.append("\(km.formatted(.number.precision(.fractionLength(2)))) km")
        }
        if let averageHR = workout.averageHeartRateBPM {
            parts.append("avg \(averageHR.formatted(.number.precision(.fractionLength(0)))) BPM")
        }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var backendSection: some View {
        Section("Backend") {
            LabeledContent("Tester ID", value: viewModel.testerID)
                .font(.footnote)

            TextField("http://192.168.1.42:8000", text: $viewModel.backendBaseURL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)

            Button {
                Task { await viewModel.sendToBackend() }
            } label: {
                if viewModel.uploadState == .sending {
                    HStack { ProgressView(); Text("Sending…") }
                } else {
                    Text("Send to Backend")
                }
            }
            .disabled(viewModel.snapshot == nil || viewModel.uploadState == .sending)

            switch viewModel.uploadState {
            case .idle, .sending:
                EmptyView()
            case .succeeded(let message):
                Label(message, systemImage: "checkmark.circle")
                    .font(.footnote)
                    .foregroundStyle(.green)
            case .failed(let message, let retryable):
                VStack(alignment: .leading, spacing: 4) {
                    Label(message, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                    if retryable {
                        Text("Check that the backend is running and reachable from this iPhone, then tap Send again.")
                            .foregroundStyle(.secondary)
                    }
                }
                .font(.footnote)
            }
        }
    }
}

/// One metric row. Renders "Unavailable" rather than `0` when HealthKit has no
/// sample, because 0 BPM is a very different statement from "no data".
private struct MetricRow: View {
    let title: String
    let value: Double?
    let unit: String?
    let fractionDigits: Int

    var body: some View {
        LabeledContent(title) {
            if let value {
                Text(formatted(value))
            } else {
                Text("Unavailable").foregroundStyle(.secondary)
            }
        }
    }

    private func formatted(_ value: Double) -> String {
        let number = value.formatted(.number.precision(.fractionLength(fractionDigits)))
        guard let unit else { return number }
        return "\(number) \(unit)"
    }
}

private extension View {
    func disclaimerFooter() -> some View {
        safeAreaInset(edge: .bottom) {
            Text("Experimental hackathon prototype. Not a medical device and not medical advice.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity)
                .background(.bar)
        }
    }
}

#Preview {
    HealthDashboardView()
}
