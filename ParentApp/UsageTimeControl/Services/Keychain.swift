import Foundation
import Security

/// Simple Keychain wrapper for storing auth token securely.
enum KeychainHelper {
    private static let service = "com.usagetime.control"
    private static let tokenKey = "auth_token"
    private static let serverKey = "server_url"

    static func saveToken(_ token: String) {
        save(key: tokenKey, value: token)
    }

    static func getToken() -> String? {
        get(key: tokenKey)
    }

    static func deleteToken() {
        delete(key: tokenKey)
    }

    static func saveServerURL(_ url: String) {
        save(key: serverKey, value: url)
    }

    static func getServerURL() -> String {
        get(key: serverKey) ?? "https://my.nestimer.com"
    }

    // MARK: - Private

    private static func save(key: String, value: String) {
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]

        // Try update first, then add if not found
        let updateAttrs: [String: Any] = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(query as CFDictionary, updateAttrs as CFDictionary)

        if updateStatus == errSecItemNotFound {
            var addQuery = query
            addQuery[kSecValueData as String] = data
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            if addStatus != errSecSuccess {
                NSLog("[UsageTimeControl] Keychain save failed: \(addStatus)")
            }
        } else if updateStatus != errSecSuccess {
            NSLog("[UsageTimeControl] Keychain update failed: \(updateStatus)")
        }
    }

    private static func get(key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func delete(key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
