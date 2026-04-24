import Foundation
import os.log
import Security

/// Real Keychain-backed implementation of `SecureStore`. Uses
/// `kSecClassGenericPassword` scoped by a service identifier that namespaces
/// every item belonging to this store (e.g. `"com.speechtotext.cliniko"`).
///
/// Accessibility is pinned to
/// `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` to prevent secrets from
/// syncing via iCloud Keychain — important for credentials tied to a specific
/// practitioner's workstation.
///
/// Item values are never logged. Error-path logs include the service and key
/// name but never the value.
public actor KeychainSecureStore: SecureStore {
    public enum Failure: Swift.Error, CustomStringConvertible, Equatable, Sendable {
        case osStatus(OSStatus, Operation)

        public enum Operation: String, Sendable {
            case set, get, delete, deleteAll
        }

        public var description: String {
            switch self {
            case let .osStatus(status, op):
                return "KeychainSecureStore: \(op.rawValue) failed (OSStatus \(status))"
            }
        }
    }

    private let service: String
    private let logger = Logger(subsystem: "com.speechtotext", category: "KeychainSecureStore")

    public init(service: String) {
        self.service = service
    }

    public func set(_ data: Data, forKey key: String) async throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
        let attributesToUpdate: [String: Any] = [
            kSecValueData as String: data
        ]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributesToUpdate as CFDictionary)

        switch updateStatus {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            var addQuery = query
            addQuery[kSecValueData as String] = data
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            if addStatus != errSecSuccess {
                logger.error("set failed (add) service=\(self.service, privacy: .public) key=\(key, privacy: .public) status=\(addStatus)")
                throw Failure.osStatus(addStatus, .set)
            }
        default:
            logger.error("set failed (update) service=\(self.service, privacy: .public) key=\(key, privacy: .public) status=\(updateStatus)")
            throw Failure.osStatus(updateStatus, .set)
        }
    }

    public func get(forKey key: String) async throws -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            return item as? Data
        case errSecItemNotFound:
            return nil
        default:
            logger.error("get failed service=\(self.service, privacy: .public) key=\(key, privacy: .public) status=\(status)")
            throw Failure.osStatus(status, .get)
        }
    }

    public func delete(forKey key: String) async throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            logger.error("delete failed service=\(self.service, privacy: .public) key=\(key, privacy: .public) status=\(status)")
            throw Failure.osStatus(status, .delete)
        }
    }

    public func deleteAll() async throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            logger.error("deleteAll failed service=\(self.service, privacy: .public) status=\(status)")
            throw Failure.osStatus(status, .deleteAll)
        }
    }
}
