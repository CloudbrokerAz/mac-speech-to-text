import Foundation
@testable import SpeechToText

/// In-memory fake for `SecureStore` used in unit tests. Never touches the
/// real Keychain. Thread-safe via actor isolation.
///
/// Use this anywhere a test needs a credentials store — the real
/// `KeychainSecureStore` is only exercised via manual smoke tests, not in CI.
public actor InMemorySecureStore: SecureStore {
    private var storage: [String: Data]

    public init(initial: [String: Data] = [:]) {
        self.storage = initial
    }

    public func set(_ data: Data, forKey key: String) async throws {
        storage[key] = data
    }

    public func get(forKey key: String) async throws -> Data? {
        storage[key]
    }

    public func delete(forKey key: String) async throws {
        storage.removeValue(forKey: key)
    }

    public func deleteAll() async throws {
        storage.removeAll(keepingCapacity: false)
    }

    // MARK: - Test helpers

    /// Number of items currently held. Test-only.
    public func count() async -> Int { storage.count }

    /// Sorted list of keys currently held. Test-only.
    public func keys() async -> [String] { storage.keys.sorted() }
}
