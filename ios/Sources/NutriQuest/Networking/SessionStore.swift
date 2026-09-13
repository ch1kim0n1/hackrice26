import Foundation

/// Session store for the account system backbone.
///
/// Persists the bearer token + player identity across launches. The token is
/// stored in the Keychain (not UserDefaults) so it survives app reinstall
/// and isn't readable from the app's sandboxed preferences.
///
/// Anonymous play still works: `token == nil` -> APIClient sends the legacy
/// `X-Player-ID` header instead, and the backend treats it as a guest scope.
@MainActor
final class SessionStore: ObservableObject {

    static let shared = SessionStore()

    @Published private(set) var token: String?
    @Published private(set) var playerID: String?
    @Published private(set) var username: String?
    @Published private(set) var displayName: String?

    var isAuthenticated: Bool { token != nil }

    /// Synchronous token read for APIClient's request pipeline — reads the
    /// Keychain directly so it works off the main actor.
    nonisolated static var currentToken: String? {
        Keychain.get(key: "auth.token")
    }

    private init() {
        token = Keychain.get(key: "auth.token")
        playerID = Keychain.get(key: "auth.playerID")
        username = Keychain.get(key: "auth.username")
        displayName = Keychain.get(key: "auth.displayName")
    }

    /// Persist a session returned by /auth/register or /auth/login.
    func save(token: String, playerID: String, username: String, displayName: String) {
        self.token = token
        self.playerID = playerID
        self.username = username
        self.displayName = displayName
        Keychain.set(key: "auth.token", value: token)
        Keychain.set(key: "auth.playerID", value: playerID)
        Keychain.set(key: "auth.username", value: username)
        Keychain.set(key: "auth.displayName", value: displayName)
    }

    /// Clear the local session — called on logout and on SESSION_EXPIRED 401s.
    func clear() {
        token = nil
        playerID = nil
        username = nil
        displayName = nil
        for key in ["auth.token", "auth.playerID", "auth.username", "auth.displayName"] {
            Keychain.delete(key: key)
        }
    }
}

// MARK: - Minimal Keychain wrapper (no external deps)

private enum Keychain {
    static func set(key: String, value: String) {
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecValueData as String: data
        ]
        SecItemDelete(query as CFDictionary)
        SecItemAdd(query as CFDictionary, nil)
    }

    static func get(key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key
        ]
        SecItemDelete(query as CFDictionary)
    }
}
