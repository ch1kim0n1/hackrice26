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

    var body: some View {
        NavigationStack {
            Group {
                if let url = HumanGateWebView.url(mode: .signup) {
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

/// Which account screen the embedded gate opens on. Signup runs the reflex
/// human check; login runs the Persona identity check.
enum HumanGateMode: String {
    case signup, login
}

/// The web gate in a WKWebView. Hands the session the page posts back to
/// `SessionStore`, then calls `onAuth`. Shared by the Profile sheet and the
/// onboarding account step.
struct HumanGateWebView: UIViewRepresentable {
    let url: URL
    let onAuth: () -> Void

    /// Gate URL for a mode, with the app's backend forwarded so the page
    /// registers and logs in against the same server the app talks to.
    static func url(mode: HumanGateMode) -> URL? {
        guard var components = URLComponents(string: AppConfig.humanGateURL) else { return nil }
        components.queryItems = (components.queryItems ?? []) + [
            URLQueryItem(name: "api", value: AppConfig.backendBaseURL),
            URLQueryItem(name: "mode", value: mode.rawValue)
        ]
        return components.url
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onAuth: onAuth)
    }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.userContentController.add(context.coordinator, name: "nutriquest")
        // Persona's liveness check streams the camera inline.
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.uiDelegate = context.coordinator
        webView.scrollView.bounces = false
        webView.scrollView.isScrollEnabled = false
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKScriptMessageHandler, WKUIDelegate {
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

        /// Camera access for Persona still goes through the app's own camera
        /// permission; this only stops the page asking a second time.
        func webView(
            _ webView: WKWebView,
            requestMediaCapturePermissionFor origin: WKSecurityOrigin,
            initiatedByFrame frame: WKFrameInfo,
            type: WKMediaCaptureType,
            decisionHandler: @escaping (WKPermissionDecision) -> Void
        ) {
            decisionHandler(.grant)
        }
    }
}
