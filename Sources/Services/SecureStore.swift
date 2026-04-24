import Foundation

/// Abstraction over the system Keychain so services can be unit-tested with an
/// in-memory fake without touching the real login keychain.
///
/// Implementations must be thread-safe and `Sendable`. Reads of a missing key
/// return `nil` rather than throwing; `throws` is reserved for underlying OS
/// errors (e.g. access denied) that should propagate.
public protocol SecureStore: Sendable {
    /// Store `data` under `key`, overwriting any existing value.
    func set(_ data: Data, forKey key: String) async throws

    /// Retrieve the value for `key`, or `nil` if not present.
    func get(forKey key: String) async throws -> Data?

    /// Remove the value for `key`. No-op if missing.
    func delete(forKey key: String) async throws

    /// Remove every item owned by this store's namespace. Intended for "log
    /// out" / "clear credentials" flows and for tests.
    func deleteAll() async throws
}

public extension SecureStore {
    /// Convenience: store a UTF-8 string.
    func setString(_ string: String, forKey key: String) async throws {
        try await set(Data(string.utf8), forKey: key)
    }

    /// Convenience: retrieve a UTF-8 string, or `nil` if missing.
    func getString(forKey key: String) async throws -> String? {
        guard let data = try await get(forKey: key) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
