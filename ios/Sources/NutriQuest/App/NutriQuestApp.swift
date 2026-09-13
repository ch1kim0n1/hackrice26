import SwiftUI
import UIKit
import NutriQuestUI

@main
struct NutriQuestApp: App {
    init() {
        Self.installNavChrome()
    }

    var body: some Scene {
        WindowGroup {
            LaunchGateView()
                .modifier(RarityAuraDemoLauncher())
                // The whole app is dark-themed (navy pages, cream ink) — pin
                // dark so nav titles and system controls render light instead
                // of defaulting to black over the scene art.
                .preferredColorScheme(.dark)
        }
    }

    /// Baloo titles and gold back chevrons on a clear bar, so every pushed
    /// screen still reads as the game rather than stock UIKit.
    private static func installNavChrome() {
        let appearance = UINavigationBarAppearance()
        appearance.configureWithTransparentBackground()
        appearance.backgroundColor = .clear
        appearance.shadowColor = .clear
        let titleFont = UIFont(name: "Baloo 2", size: 20) ?? .systemFont(ofSize: 20, weight: .heavy)
        let ink = UIColor(hex: 0xFFF5DA)
        appearance.titleTextAttributes = [
            .foregroundColor: ink,
            .font: titleFont
        ]
        appearance.largeTitleTextAttributes = [
            .foregroundColor: ink,
            .font: UIFont(name: "Baloo 2", size: 32) ?? .systemFont(ofSize: 32, weight: .heavy)
        ]
        UINavigationBar.appearance().standardAppearance = appearance
        UINavigationBar.appearance().scrollEdgeAppearance = appearance
        UINavigationBar.appearance().compactAppearance = appearance
        UINavigationBar.appearance().tintColor = UIColor(hex: 0xFFCC2E)
    }
}
