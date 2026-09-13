import SwiftUI
import NutriQuestUI

/// Cold-launch splash implemented from the Figma reference: an adventure-blue
/// screen with the centered "hackrice" lockup that fades in. Purely
/// presentational -- no data loading gates on it, so a slow network never
/// extends it.
struct LaunchSplashView: View {
    @State private var visible = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            NQAdventureBackdrop().ignoresSafeArea()

            NQAssetImage("logo")
                .frame(width: 180, height: 180)
                .opacity(visible ? 1 : 0)
                .scaleEffect(visible ? 1 : 0.94)
        }
        .accessibilityHidden(true)
        .onAppear {
            guard !reduceMotion else {
                visible = true
                return
            }
            withAnimation(.easeOut(duration: 0.45)) {
                visible = true
            }
        }
    }
}
