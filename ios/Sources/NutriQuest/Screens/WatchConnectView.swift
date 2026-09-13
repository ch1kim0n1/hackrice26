import SwiftUI
import NutriQuestUI

enum WatchConnectStep { case prompt, searching, connected, failed }

struct WatchConnectView: View {
    var step: WatchConnectStep

    /// Links the watch so Profile can show Connected, then loads real vitals
    /// (dashes if the watch app has not synced yet — never fake numbers).
    @State private var localStep: WatchConnectStep?
    @State private var failureReason: String?
    @State private var pulse = false
    @Environment(\.nqAccent) private var accent
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @EnvironmentObject private var gameState: GameState

    private var currentStep: WatchConnectStep {
        if localStep == nil, gameState.watchLinked { return .connected }
        return localStep ?? step
    }

    var body: some View {
        VStack(spacing: NQTheme.spaceXL - 8) {
            watchGlyph
            Spacer()
            switch currentStep {
            case .prompt: promptBody
            case .searching: searchingBody
            case .connected: connectedBody
            case .failed: failedBody
            }
            Spacer()
            actionArea
        }
        .padding(NQTheme.spaceL)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .nqPageBackground()
        .navigationTitle("Connected Devices")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { pulse = true }
        .animation(NQMotion.springy, value: currentStep)
    }

    private var watchGlyph: some View {
        ZStack {
            if currentStep == .searching && !reduceMotion {
                ForEach(0..<2, id: \.self) { i in
                    Circle()
                        .stroke(accent.accent.opacity(0.35), lineWidth: 2)
                        .frame(width: pulse ? 140 : 80, height: pulse ? 140 : 80)
                        .opacity(pulse ? 0 : 1)
                        .animation(
                            .easeOut(duration: 1.4).repeatForever(autoreverses: false).delay(Double(i) * 0.6),
                            value: pulse
                        )
                }
            }
            RoundedRectangle(cornerRadius: NQTheme.radiusL + 2)
                .fill(NQTheme.ink)
                .frame(width: 72, height: 88)
            RoundedRectangle(cornerRadius: 2)
                .fill(NQTheme.ink)
                .frame(width: 10, height: 16)
                .offset(y: -50)
            RoundedRectangle(cornerRadius: 2)
                .fill(NQTheme.ink)
                .frame(width: 10, height: 16)
                .offset(y: 50)
            if currentStep == .connected {
                Circle()
                    .fill(accent.accent)
                    .frame(width: 26, height: 26)
                    .overlay {
                        NQIcon.checkCircle.view
                            .frame(width: 13, height: 13)
                            .foregroundStyle(accent.accent.readableTextColor())
                    }
                    .offset(x: 24, y: -34)
            }
            if currentStep == .failed {
                Circle()
                    .fill(NQTheme.warning)
                    .frame(width: 26, height: 26)
                    .overlay {
                        Image(systemName: "exclamationmark")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(.white)
                    }
                    .offset(x: 24, y: -34)
            }
        }
        .frame(height: 140)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            currentStep == .connected ? "Watch connected"
            : currentStep == .failed ? "Connection failed"
            : currentStep == .searching ? "Linking health data"
            : "Watch not connected"
        )
    }

    private var healthAvailable: Bool { HealthSyncService.shared.isHealthDataAvailable }

    private var promptBody: some View {
        VStack(spacing: NQTheme.spaceS) {
            Text(healthAvailable ? "Connect your watch" : "Health data unavailable")
                .font(NQText.displayL.font)
                .foregroundStyle(NQTheme.ink)
                .multilineTextAlignment(.center)
            Text(healthAvailable
                 ? "Sync steps, heart rate & workouts from Apple Health to boost your daily stats."
                 : "This device can't read Apple Health. Connect from an iPhone paired with your Apple Watch.")
                .font(NQText.captionS.font)
                .foregroundStyle(NQTheme.inkMuted)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
        }
    }

    private var searchingBody: some View {
        VStack(spacing: NQTheme.spaceS) {
            Text("Pulling your latest activity…")
                .font(NQText.displayL.font)
                .foregroundStyle(NQTheme.ink)
            Text("Allow access in the Health sheet, then we read today's steps, exercise, and stand hours from your last watch sync.")
                .font(NQText.captionS.font)
                .foregroundStyle(NQTheme.inkMuted)
                .multilineTextAlignment(.center)
        }
    }

    private var connectedBody: some View {
        VStack(spacing: NQTheme.spaceL) {
            Text("Watch connected")
                .font(NQText.displayL.font)
                .foregroundStyle(NQTheme.ink)
            Text("Your stats will now sync automatically.")
                .font(NQText.captionS.font)
                .foregroundStyle(NQTheme.inkMuted)
            Text("Steps and workouts feed your Daily Multiplier, up to +10%.")
                .font(NQText.captionS.font)
                .foregroundStyle(accent.accentDark)
            HStack(spacing: NQTheme.spaceS + 2) {
                sampleStat(icon: .battle, tint: accent.accent, value: stepsLabel, label: "Steps")
                sampleStat(icon: .flame, tint: NQTheme.flame, value: exerciseLabel, label: "Exercise")
                sampleStat(icon: .watch, tint: NQTheme.info, value: standLabel, label: "Stand")
            }
            if let activity = gameState.vitalsActivity {
                VStack(spacing: NQTheme.spaceS) {
                    NQStatBar(label: "Steps", value: activity.stepProgress, valueText: "\(Int(activity.stepProgress * 100))%")
                    NQStatBar(label: "Exercise", value: activity.exerciseProgress, valueText: "\(Int(activity.exerciseProgress * 100))%")
                    NQStatBar(label: "Stand", value: activity.standProgress, valueText: "\(Int(activity.standProgress * 100))%")
                }
                .nqPadding(.card)
                .nqPlate(RoundedRectangle(cornerRadius: NQTheme.radiusL), elevation: .soft)
            }
            if gameState.vitalsActivity?.stepsToday == nil {
                Text("No activity yet today. Wear your watch, then tap Sync now.")
                    .font(NQText.captionS.font)
                    .foregroundStyle(NQTheme.inkMuted)
                    .multilineTextAlignment(.center)
            }
        }
        .transition(NQTransition.summon)
    }

    /// Reached when Health data is unavailable, the permission sheet failed,
    /// or the upload to the backend failed — `failureReason` carries which.
    private var failedBody: some View {
        VStack(spacing: NQTheme.spaceS) {
            Text("Couldn't connect")
                .font(NQText.displayL.font)
                .foregroundStyle(NQTheme.ink)
            Text(failureReason ?? "Something went wrong reading Apple Health.")
                .font(NQText.captionS.font)
                .foregroundStyle(NQTheme.inkMuted)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
            Text("You can also allow access in Settings › Health › Data Access & Devices › NutriQuest.")
                .font(NQText.captionS.font)
                .foregroundStyle(NQTheme.inkMuted)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
        }
        .transition(NQTransition.pop)
    }

    @ViewBuilder private var actionArea: some View {
        switch currentStep {
        case .prompt:
            VStack(spacing: NQTheme.spaceM) {
                if healthAvailable {
                    NQButton("Connect Apple Watch", icon: .watch) {
                        beginConnect()
                    }
                }
                Button("Maybe Later") { dismiss() }
                    .font(NQText.captionS.font.weight(.bold))
                    .foregroundStyle(NQTheme.inkMuted)
            }
        case .searching:
            Button("Cancel") { localStep = .prompt }
                .font(NQText.captionS.font.weight(.bold))
                .foregroundStyle(NQTheme.inkMuted)
        case .connected:
            VStack(spacing: NQTheme.spaceM) {
                NQButton("Done") { dismiss() }
                Button(gameState.isSyncingHealth ? "Syncing…" : "Sync now") {
                    Task { await gameState.syncHealthIfLinked(force: true) }
                }
                .font(NQText.captionS.font.weight(.bold))
                .foregroundStyle(NQTheme.inkMuted)
                .disabled(gameState.isSyncingHealth)
            }
        case .failed:
            NQButton("Try Again", icon: .watch) { beginConnect() }
        }
    }

    /// Real connect: Health permission sheet (first time) → read today's
    /// snapshot → POST /vitals → mark linked. Cancel only hides the spinner;
    /// a completed sync still lands so Profile shows Connected.
    private func beginConnect() {
        localStep = .searching
        failureReason = nil
        Task {
            do {
                try await gameState.connectAppleWatch()
                localStep = .connected
                NQHaptic.success()
            } catch {
                failureReason = error.localizedDescription
                localStep = .failed
                NQHaptic.error()
            }
        }
    }

    private var stepsLabel: String {
        gameState.vitalsActivity?.stepsToday.map { $0.formatted() } ?? "—"
    }

    private var exerciseLabel: String {
        gameState.vitalsActivity?.exerciseMinutesToday.map { "\($0)m" } ?? "—"
    }

    private var standLabel: String {
        gameState.vitalsActivity?.standHoursToday.map { "\($0)h" } ?? "—"
    }

    private func sampleStat(icon: NQIcon, tint: Color, value: String, label: String) -> some View {
        VStack(spacing: 4) {
            icon.view
                .frame(width: 16, height: 16)
                .foregroundStyle(tint)
            Text(value)
                .font(NQText.heading.font)
                .foregroundStyle(NQTheme.ink)
            Text(label)
                .font(NQText.microXS.font)
                .foregroundStyle(NQTheme.inkMuted)
        }
        .frame(maxWidth: .infinity)
        .nqPadding(.badge)
        .padding(.vertical, 6)
        .nqPlate(RoundedRectangle(cornerRadius: NQTheme.radiusM + 2), elevation: .soft)
        .accessibilityElement(children: .combine)
    }
}
