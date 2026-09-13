import SwiftUI

@main
struct NutriQuestApp: App {
    var body: some Scene {
        WindowGroup {
            LaunchGateView()
                // The whole app is dark-themed (navy pages, cream ink) — pin
                // dark so nav titles and system controls render light instead
                // of defaulting to black over the scene art.
                .preferredColorScheme(.dark)
        }
    }
}
