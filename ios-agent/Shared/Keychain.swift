import Foundation
import NesTimerCore
import Security

/// Device token, server URL and TOTP secret, shared with the monitor extension through the
/// keychain access group. Never in UserDefaults or App Group files.
struct Keychain: SecretStore {
    static let service = "com.nestimer.child"
    static var accessGroup: String {
        // $(AppIdentifierPrefix) = team ID + "."
        "CBBC6T33XY.com.nestimer.child"
    }

    enum Key: String { case serverURL, apiToken, totpSecret }

    static func set(_ key: Key, _ value: String) {
        delete(key)
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.rawValue,
            kSecAttrAccessGroup as String: accessGroup,
            kSecValueData as String: Data(value.utf8),
            // Extensions run while the phone is locked; the item must stay readable then.
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        SecItemAdd(q as CFDictionary, nil)
    }

    static func get(_ key: Key) -> String? {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.rawValue,
            kSecAttrAccessGroup as String: accessGroup,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }

    static func delete(_ key: Key) {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.rawValue,
            kSecAttrAccessGroup as String: accessGroup,
        ]
        SecItemDelete(q as CFDictionary)
    }

    static var isPaired: Bool { Self.get(.apiToken) != nil && Self.get(.serverURL) != nil }

    func totpSecret() -> String? { Self.get(.totpSecret) }
}
