import SwiftUI
import NutriQuestUI

/// Cold-launch splash: adventure-blue sky, logo lockup, then into the game.
struct LaunchSplashView: View {
    @State private var visible = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            NQAdventureBackdrop().ignoresSafeArea()
            NQFloatingSparkles(count: 10, color: NQTheme.gold)

            VStack(spacing: NQTheme.spaceM) {
                NQAssetImage("logo")
                    .frame(width: 180, height: 180)
                Text("NutriQuest")
                    .font(NQText.display.font)
                    .foregroundStyle(NQTheme.gold)
                    .shadow(color: NQTheme.inkDeep, radius: 0, y: 3)
            }
            .opacity(visible ? 1 : 0)
            .scaleEffect(visible ? 1 : 0.92)
        }
        .accessibilityHidden(true)
        .onAppear {
            guard !reduceMotion else {
                visible = true
                return
            }
            withAnimation(.spring(response: 0.5, dampingFraction: 0.72)) {
                visible = true
            }
        }
    }
}
