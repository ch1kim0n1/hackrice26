import SwiftUI
import WebKit
import NutriQuestUI

/// In-app host for the "Prove You're Human" signup gate (persona-challenge/).
/// The web app runs the reflex game and calls the backend itself — this view
/// passes the app's backend URL via `?api=` and listens for the `nutriquest`
/// script message the page posts once /auth/register succeeds, then persists
/// the session and dismisses.
struct HumanGateView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.nqAccent) private var accent

    /// Gate URL with the backend address forwarded so the web app registers
    /// against the same server the app talks to.
    private var gateURL: URL? {
        guard var components = URLComponents(string: AppConfig.humanGateURL) else { return nil }
        components.queryItems = (components.queryItems ?? []) + [
            URLQueryItem(name: "api", value: AppConfig.backendBaseURL)
        ]
        return components.url
    }

    var body: some View {
        NavigationStack {
            Group {
                if let url = gateURL {
                    HumanGateWebView(url: url, onAuth: { dismiss() })
                        .ignoresSafeArea(edges: .bottom)
                } else {
                    VStack(spacing: NQTheme.spaceS) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 28))
                            .foregroundStyle(NQTheme.warning)
                        Text("Invalid gate URL")
                            .font(NQText.headingL.font.weight(.bold))
                            .foregroundStyle(NQTheme.ink)
                        Text(AppConfig.humanGateURL)
                            .font(NQText.caption.font)
                            .foregroundStyle(NQTheme.inkMuted)
                    }
                }
            }
            .navigationTitle("Prove You're Human")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close") { dismiss() }
                        .foregroundStyle(accent.accentDark)
                }
            }
        }
    }
}

private struct HumanGateWebView: UIViewRepresentable {
    let url: URL
    let onAuth: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onAuth: onAuth)
    }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.userContentController.add(context.coordinator, name: "nutriquest")
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.scrollView.bounces = false
        webView.scrollView.isScrollEnabled = false
        webView.isOpaque = false
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKScriptMessageHandler {
        let onAuth: () -> Void

        init(onAuth: @escaping () -> Void) {
            self.onAuth = onAuth
        }

        func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            guard let body = message.body as? [String: Any],
                  body["type"] as? String == "auth",
                  let token = body["token"] as? String,
                  let playerId = body["playerId"] as? String
            else { return }
            let username = body["username"] as? String ?? ""
            let displayName = body["displayName"] as? String ?? ""
            Task { @MainActor in
                SessionStore.shared.save(
                    token: token,
                    playerID: playerId,
                    username: username,
                    displayName: displayName
                )
                onAuth()
            }
        }
    }
}
