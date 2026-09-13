import Foundation

/// Backend connection settings. Nothing secret lives here: the base URL is a
/// development address and the player ID is a random, install-local string.
enum AppConfig {

    private static let baseURLKey = "config.backendBaseURL"
    private static let humanGateURLKey = "config.humanGateURL"
    private static let playerIDKey = "config.playerID"

    private static var defaultBaseURLString: String {
        let fromPlist = Bundle.main.object(forInfoDictionaryKey: "BackendBaseURL") as? String
        let trimmed = fromPlist?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? "http://localhost:4000" : trimmed
    }

    private static var defaultHumanGateURLString: String {
        let fromPlist = Bundle.main.object(forInfoDictionaryKey: "HumanGateURL") as? String
        let trimmed = fromPlist?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? "http://localhost:8123" : trimmed
    }

    /// Backend base URL. Overridable at runtime (e.g. a debug settings row);
    /// defaults to the local dev server on :4000.
    ///
    /// Note: `localhost` on an iPhone means *the iPhone*. To reach a backend
    /// running on your Mac, use the Mac's LAN address, e.g.
    /// `http://192.168.1.42:4000` (both devices on the same Wi-Fi).
    static var backendBaseURL: String {
        get {
            let stored = UserDefaults.standard.string(forKey: baseURLKey) ?? ""
            return stored.isEmpty ? defaultBaseURLString : stored
        }
        set {
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            UserDefaults.standard.set(trimmed, forKey: baseURLKey)
        }
    }

    /// Base URL of the standalone "Prove You're Human" pre-gate web app.
    /// Production serves it from the backend itself at /gate; for local
    /// development run `python3 -m http.server 8123 -d backend/public/human-gate`.
    static var humanGateURL: String {
        get {
            let stored = UserDefaults.standard.string(forKey: humanGateURLKey) ?? ""
            return stored.isEmpty ? defaultHumanGateURLString : stored
        }
        set {
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            UserDefaults.standard.set(trimmed, forKey: humanGateURLKey)
        }
    }

    /// Stable-per-install random identifier sent as `X-Player-ID` on every
    /// request. The backend is moving to per-player scoped state keyed off
    /// this header; until then every install still gets its own identity, so
    /// never assume a single global player exists.
    static var playerID: String {
        if let existing = UserDefaults.standard.string(forKey: playerIDKey), !existing.isEmpty {
            return existing
        }
        let generated = "player_" + UUID().uuidString.prefix(8).lowercased()
        UserDefaults.standard.set(generated, forKey: playerIDKey)
        return generated
    }
}
