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
    /// Errors thrown by `KeychainSecureStore`.
    ///
    /// `Equatable` is intentionally asymmetric: two `.unexpected` values
    /// compare unequal when their `OSStatus` differs, but two
    /// `.authDenied` (or `.notAvailable`) values compare equal *regardless*
    /// of the originating `OSStatus`. The whole point of the semantic
    /// cases is information loss — collapsing `errSecAuthFailed` and
    /// `errSecUserCanceled` into one bucket the UI layer can act on. Do
    /// not write tests that try to "pin" a specific `OSStatus` via
    /// equality on a semantic case; assert on the case itself.
    public enum Failure: Swift.Error, CustomStringConvertible, Equatable, Sendable {
        /// User denied / cancelled the keychain prompt, or auth failed.
        /// Maps `errSecInteractionNotAllowed`, `errSecAuthFailed`,
        /// `errSecUserCanceled`. Callers can surface a "we need keychain
        /// access" affordance without re-deriving this from a raw OSStatus.
        case authDenied(Operation)
        /// The keychain itself isn't available to us. Maps
        /// `errSecNotAvailable`, `errSecMissingEntitlement`. Distinguishes
        /// "we can't reach the keychain at all" from a transient auth deny.
        case notAvailable(Operation)
        /// `SecItemCopyMatching` succeeded but returned a value that was not
        /// `Data`. Indicates keychain corruption or a cross-class match and
        /// MUST NOT be silently mapped to "missing".
        case unexpectedItemType(Operation)
        /// Any other `OSStatus` we don't have a semantic mapping for. Carries
        /// the raw status purely for diagnostics — callers should not switch
        /// on the integer value.
        case unexpected(OSStatus, Operation)

        public enum Operation: String, Sendable {
            case set, get, delete, deleteAll
        }

        /// Map a raw `OSStatus` from `SecItem*` to its semantic case.
        /// Done at throw-time so callers never need to interpret raw status
        /// codes — they switch on the case directly. Default access (internal)
        /// so the mapping-table tests can reach it via `@testable import`.
        static func from(status: OSStatus, op: Operation) -> Failure {
            switch status {
            case errSecInteractionNotAllowed, errSecAuthFailed, errSecUserCanceled:
                return .authDenied(op)
            case errSecNotAvailable, errSecMissingEntitlement:
                return .notAvailable(op)
            default:
                return .unexpected(status, op)
            }
        }

        public var description: String {
            switch self {
            case let .authDenied(op):
                return "KeychainSecureStore: \(op.rawValue) failed (auth denied / cancelled)"
            case let .notAvailable(op):
                return "KeychainSecureStore: \(op.rawValue) failed (keychain not available)"
            case let .unexpectedItemType(op):
                return "KeychainSecureStore: \(op.rawValue) returned a non-Data item"
            case let .unexpected(status, op):
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
        // Include accessibility in the update payload too. If an item already
        // exists with a looser policy (e.g. created by an older build before
        // the ThisDeviceOnly guard was introduced), `SecItemUpdate` otherwise
        // leaves `kSecAttrAccessible` unchanged and silently preserves the
        // looser policy — defeating the iCloud-sync guard.
        let attributesToUpdate: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributesToUpdate as CFDictionary)

        switch updateStatus {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            try addItem(key: key, data: data, query: query, retryOnDuplicate: true)
        default:
            logger.error("set failed (update) service=\(self.service, privacy: .public) key=\(key, privacy: .public) status=\(updateStatus)")
            throw Failure.from(status: updateStatus, op: .set)
        }
    }

    /// `SecItemAdd` with a one-shot retry when another process races us
    /// between our `SecItemUpdate` miss and `SecItemAdd`. The alternative
    /// (`errSecDuplicateItem` bubbling to the caller) is a flake that would
    /// rarely fire but ship to users.
    private func addItem(
        key: String,
        data: Data,
        query: [String: Any],
        retryOnDuplicate: Bool
    ) throws {
        var addQuery = query
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)

        switch addStatus {
        case errSecSuccess:
            return
        case errSecDuplicateItem where retryOnDuplicate:
            let updateStatus = SecItemUpdate(
                query as CFDictionary,
                [
                    kSecValueData as String: data,
                    kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
                ] as CFDictionary
            )
            if updateStatus != errSecSuccess {
                logger.error("set failed (retry-update) service=\(self.service, privacy: .public) key=\(key, privacy: .public) status=\(updateStatus)")
                throw Failure.from(status: updateStatus, op: .set)
            }
        default:
            logger.error("set failed (add) service=\(self.service, privacy: .public) key=\(key, privacy: .public) status=\(addStatus)")
            throw Failure.from(status: addStatus, op: .set)
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
            // Keychain said "success" but returned something other than Data
            // (class mismatch, corruption, etc.). The SecureStore contract is
            // "missing returns nil, anything else throws" — silently returning
            // nil here would hide a real problem.
            guard let data = item as? Data else {
                logger.error("get returned non-Data item service=\(self.service, privacy: .public) key=\(key, privacy: .public)")
                throw Failure.unexpectedItemType(.get)
            }
            return data
        case errSecItemNotFound:
            return nil
        default:
            logger.error("get failed service=\(self.service, privacy: .public) key=\(key, privacy: .public) status=\(status)")
            throw Failure.from(status: status, op: .get)
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
            throw Failure.from(status: status, op: .delete)
        }
    }

    public func deleteAll() async throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service
        ]
        // `SecItemDelete` on macOS removes only one matching item per call
        // even though the documentation says it "deletes all matching items"
        // — a long-standing legacy-keychain quirk. Loop until the keychain
        // reports `errSecItemNotFound` so a service namespace holding multiple
        // credentials is fully wiped on `deleteAll`. Caught by
        // `KeychainSecureStoreTests.deleteAll_removesAllItems` (the prior
        // single-call implementation left every item except the first).
        //
        // The loop is bounded as a defensive guard: an ACL bug, a daemon
        // edge case, or a concurrent process re-inserting items under the
        // same `service` could otherwise wedge the actor's executor and
        // silently fail every queued call behind it. 10_000 is far above
        // any plausible item count for one Cliniko-credential namespace.
        let maxIterations = 10_000
        for _ in 0..<maxIterations {
            let status = SecItemDelete(query as CFDictionary)
            switch status {
            case errSecSuccess:
                continue
            case errSecItemNotFound:
                return
            default:
                logger.error("deleteAll failed service=\(self.service, privacy: .public) status=\(status)")
                throw Failure.from(status: status, op: .deleteAll)
            }
        }
        logger.error("deleteAll exceeded \(maxIterations) iterations service=\(self.service, privacy: .public)")
        // Synthetic sentinel: no real `OSStatus` came back from Keychain
        // here — the loop hit its defensive iteration cap. We construct
        // `.unexpected` directly (bypassing `Failure.from(...)`) because
        // the integer is a fiction labelling "we exhausted retries", not
        // a Keychain return code. Indistinguishable at the type level
        // from a genuine `errSecInternalError`; if a future caller needs
        // to differentiate, promote this to its own case.
        throw Failure.unexpected(errSecInternalError, .deleteAll)
    }
}
