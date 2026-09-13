import Foundation

/// Hackathon configuration. Nothing secret lives here: the backend URL is a
/// development address and the tester ID is a random, project-local string.
enum AppConfig {

    private static let baseURLKey = "config.backendBaseURL"
    private static let testerIDKey = "config.testerID"

    /// Compiled-in default, set by the `BACKEND_BASE_URL` build setting so it can
    /// be changed per machine without editing code.
    private static var defaultBaseURLString: String {
        let fromPlist = Bundle.main.object(forInfoDictionaryKey: "BackendBaseURL") as? String
        let trimmed = fromPlist?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? "http://localhost:4000" : trimmed
    }

    /// Backend base URL, overridable at runtime from the dashboard.
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

    /// Stable-per-install random identifier so the backend can tell testers
    /// apart without us sending any personal information.
    static var testerID: String {
        if let existing = UserDefaults.standard.string(forKey: testerIDKey), !existing.isEmpty {
            return existing
        }
        let generated = "tester_" + UUID().uuidString.prefix(8).lowercased()
        UserDefaults.standard.set(generated, forKey: testerIDKey)
        return generated
    }
}
