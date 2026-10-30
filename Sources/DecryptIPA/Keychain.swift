import Foundation
import Security

/// Minimal generic-password keychain wrapper. Secrets never land in the
/// device JSON store, they live under service "com.rogu.decryptipa.secrets".
enum Keychain {
    private static let service = "com.rogu.decryptipa.secrets"

    static func save(_ data: Data, account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)

        var attributes = query
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock

        SecItemAdd(attributes as CFDictionary, nil)
    }

    static func load(account: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess else { return nil }
        return item as? Data
    }

    static func delete(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }

    static func saveSecrets(_ secrets: DeviceSecrets, for id: UUID) {
        guard let data = try? JSONEncoder().encode(secrets) else { return }
        save(data, account: id.uuidString)
    }

    static func loadSecrets(for id: UUID) -> DeviceSecrets {
        guard let data = load(account: id.uuidString),
              let secrets = try? JSONDecoder().decode(DeviceSecrets.self, from: data) else {
            return DeviceSecrets()
        }
        return secrets
    }

    static func deleteSecrets(for id: UUID) {
        delete(account: id.uuidString)
    }
}
