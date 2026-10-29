import Foundation
import Security

/// Where connectors' secrets are kept: the keychain in the app, memory in tests.
protocol ConnectorSecrets: Sendable {
    func secret(for id: UUID) -> String?
    func save(_ secret: String, for id: UUID) throws
    /// Removing one that isn't there is fine.
    func remove(for id: UUID) throws
}

/// Generic passwords in the user's keychain, service "LocalFlow Connectors", one per
/// connector under its id.
struct KeychainConnectorSecrets: ConnectorSecrets {
    static let service = "LocalFlow Connectors"
    static let label = "LocalFlow connector"

    func secret(for id: UUID) -> String? {
        let search = query(id).merging([kSecReturnData as String: true,
                                        kSecMatchLimit as String: kSecMatchLimitOne]) { _, new in new }
        var result: CFTypeRef?
        guard SecItemCopyMatching(search as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func save(_ secret: String, for id: UUID) throws {
        let data = Data(secret.utf8)
        let updated = SecItemUpdate(query(id) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        guard updated == errSecItemNotFound else {
            guard updated == errSecSuccess else { throw ConnectorProblem.keychain(updated) }
            return
        }
        let item = query(id).merging([kSecValueData as String: data,
                                      kSecAttrLabel as String: Self.label]) { _, new in new }
        let added = SecItemAdd(item as CFDictionary, nil)
        guard added == errSecSuccess else { throw ConnectorProblem.keychain(added) }
    }

    func remove(for id: UUID) throws {
        let status = SecItemDelete(query(id) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw ConnectorProblem.keychain(status) }
    }

    private func query(_ id: UUID) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: Self.service,
         kSecAttrAccount as String: id.uuidString]
    }
}
