import Foundation
import Security

/// Tiny wrapper over the iOS Keychain (generic passwords, this device only).
enum Keychain {
    private static let service = "com.github.andrewgrayyouneek.deathterminal.ios"

    static func set(_ value: String, for account: String) {
        guard let data = value.data(using: .utf8) else { return }
        delete(account)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecValueData as String: data,
        ]
        SecItemAdd(query as CFDictionary, nil)
    }

    static func get(_ account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(_ account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }

    // Account names
    static func password(_ host: UUID) -> String { "host-password-\(host.uuidString)" }
    static func keyText(_ key: UUID) -> String { "key-\(key.uuidString)" }
    static func keyPassphrase(_ key: UUID) -> String { "key-passphrase-\(key.uuidString)" }
}
