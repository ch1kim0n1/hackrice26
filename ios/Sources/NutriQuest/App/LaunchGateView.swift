import SwiftUI
import NutriQuestUI

/// Hosts the launch splash over RootTabView, then dismisses it after a fixed
/// hold so cold start doesn't cut straight to Home. RootTabView mounts (and
/// starts its own .task network calls) immediately underneath -- the splash
/// is purely a cosmetic overlay, never a data-loading gate.
struct LaunchGateView: View {
    @StateObject private var gameState = GameState()
    @State private var showSplash = true

    private let holdDuration: Duration = .milliseconds(1300)

    var body: some View {
        ZStack {
            RootTabView()
                .environmentObject(gameState)

            if showSplash {
                LaunchSplashView()
                    .transition(.opacity.combined(with: .scale(scale: 1.06)))
            }
        }
        .task {
            try? await Task.sleep(for: holdDuration)
            withAnimation(.easeOut(duration: 0.4)) {
                showSplash = false
            }
        }
    }
}
