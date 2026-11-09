import Foundation
import Security

// MARK: - KeychainStore
//
// The printer's LAN access code is the only secret SlicePad holds. It lives
// in the iOS Keychain as a generic password — never in UserDefaults, never
// in a file. IP address and serial are not secret and are stored separately
// (UserDefaults, via AppModel).

enum KeychainStore {
    private static let service = "SlicePad"
    /// Key (account) for the printer LAN access code.
    static let accessCodeKey = "printerAccessCode"

    static func setAccessCode(_ code: String) {
        set(key: accessCodeKey, value: code)
    }

    static func accessCode() -> String? {
        get(key: accessCodeKey)
    }

    static func clearAccessCode() {
        delete(key: accessCodeKey)
    }

    // MARK: Generic password primitives

    static func set(key: String, value: String) {
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
        let attributes: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var addQuery = query
            addQuery[kSecValueData as String] = data
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            SecItemAdd(addQuery as CFDictionary, nil)
        }
    }

    static func get(key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
        SecItemDelete(query as CFDictionary)
    }
}
