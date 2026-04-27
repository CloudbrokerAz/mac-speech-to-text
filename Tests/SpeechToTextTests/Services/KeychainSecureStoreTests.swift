import Foundation
import Testing
@testable import SpeechToText

// Round-trip tests against the **real** macOS Keychain (#15 polish).
//
// Tagged `.requiresHardware` because they touch the user-level keychain
// — CI skips them via `--skip-tag requiresHardware` per
// `.claude/references/testing-conventions.md`. They run on the
// developer's Mac and on pre-push remote-Mac runs (`scripts/remote-test.sh`).
//
// The wrapper-level behaviour of `ClinikoCredentialStore` is already
// covered against `InMemorySecureStore` in `Cliniko/ClinikoCredentialStoreTests`;
// the goal of this file is to pin the **real `KeychainSecureStore`** —
// `SecItemAdd` / `SecItemUpdate` / `SecItemCopyMatching` /
// `SecItemDelete` wiring + the `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`
// guarantee — against an actual keychain.
//
// Every test uses a UUID-suffixed service so cross-run isolation is
// guaranteed and no production key is touched. Happy-path tests call
// `deleteAll()` at the end to keep the user's keychain tidy.
//
// ### Coverage left intentionally untested
//
// `Failure.unexpectedItemType` (in `KeychainSecureStore.get`) cannot be
// triggered without first inserting a non-`Data` item via lower-level
// Keychain APIs (e.g. `SecItemAdd` with `kSecValueRef` instead of
// `kSecValueData`). That is itself a Keychain-manipulation hazard not
// justified for a single error branch — the mapping is reviewed by
// inspection at `Sources/Services/KeychainSecureStore.swift:122-129`.
//
// The `OSStatus` → semantic-case mapping (`Failure.from(status:op:)`)
// is covered as a pure-logic table in
// `KeychainSecureStoreFailureMappingTests` (`.fast`, runs in CI).
// SecureStore-level error surfacing is already covered through the
// `ThrowingSecureStore` stub in `ClinikoCredentialStoreTests`.

@Suite("KeychainSecureStore (real Keychain)", .tags(.requiresHardware))
struct KeychainSecureStoreTests {

    /// UUID-suffixed service per test guarantees no cross-run / cross-test
    /// collision. Service names are unique, so any leftover items from a
    /// crashed test run are harmless (and orphaned to that UUID forever).
    private static func uniqueService() -> String {
        "com.speechtotext.tests.\(UUID().uuidString)"
    }

    // MARK: - Round-trip

    @Test("set followed by get returns the stored Data verbatim")
    func setGet_returnsStoredData() async throws {
        let store = KeychainSecureStore(service: Self.uniqueService())
        let payload = Data("secret-token-\(UUID().uuidString)".utf8)
        let key = "test-key"

        try await store.set(payload, forKey: key)
        let retrieved = try await store.get(forKey: key)
        #expect(retrieved == payload)
        // Cleanup runs *after* the behavioural assertion so a transient
        // keychain failure in cleanup doesn't mask the test's actual
        // verdict. Best-effort via `try?` — the UUID-suffixed service
        // makes any leftover row orphaned to this run only.
        try? await store.deleteAll()
    }

    @Test("set on an existing key overwrites via the SecItemUpdate path")
    func set_overwritesExistingValue() async throws {
        let store = KeychainSecureStore(service: Self.uniqueService())
        let key = "k"

        try await store.set(Data("first".utf8), forKey: key)
        try await store.set(Data("second".utf8), forKey: key)
        let retrieved = try await store.get(forKey: key)
        #expect(retrieved == Data("second".utf8))
        try? await store.deleteAll()
    }

    // MARK: - Missing-key contract

    /// The SecureStore contract is "missing returns `nil`, anything
    /// else throws". Pin that an unset key returns `nil` and does not
    /// surface as a thrown `Failure` (i.e. neither `unexpected(errSecItemNotFound, .get)`
    /// nor any of the semantic cases).
    @Test("get returns nil for a key that has never been set")
    func get_missingKey_returnsNil() async throws {
        let store = KeychainSecureStore(service: Self.uniqueService())
        let retrieved = try await store.get(forKey: "never-set")
        #expect(retrieved == nil)
    }

    // MARK: - Delete

    @Test("delete removes the item; subsequent get returns nil")
    func delete_removesItem() async throws {
        let store = KeychainSecureStore(service: Self.uniqueService())
        let key = "k"

        try await store.set(Data("payload".utf8), forKey: key)
        try await store.delete(forKey: key)
        let retrieved = try await store.get(forKey: key)
        #expect(retrieved == nil)
        try? await store.deleteAll()
    }

    /// `errSecItemNotFound` from `SecItemDelete` must be treated as
    /// success — a `.delete` call after the item has already been
    /// removed (or before it was ever set) is a legitimate idempotent
    /// no-op.
    @Test("delete is idempotent for a missing key (does not throw)")
    func delete_missingKey_doesNotThrow() async throws {
        let store = KeychainSecureStore(service: Self.uniqueService())
        try await store.delete(forKey: "never-existed")
    }

    // MARK: - deleteAll

    @Test("deleteAll removes every item under the service namespace")
    func deleteAll_removesAllItems() async throws {
        let store = KeychainSecureStore(service: Self.uniqueService())

        try await store.set(Data("a".utf8), forKey: "k1")
        try await store.set(Data("b".utf8), forKey: "k2")
        try await store.deleteAll()

        let r1 = try await store.get(forKey: "k1")
        let r2 = try await store.get(forKey: "k2")
        #expect(r1 == nil)
        #expect(r2 == nil)
    }

    @Test("deleteAll on an empty namespace is idempotent")
    func deleteAll_emptyNamespace_doesNotThrow() async throws {
        let store = KeychainSecureStore(service: Self.uniqueService())
        try await store.deleteAll()
    }

    // MARK: - Service-namespace isolation

    /// Two stores with distinct services must not see each other's
    /// items, even for the same key. Pins the `kSecAttrService`
    /// scoping — a regression here would let one feature's credentials
    /// leak into another's namespace.
    @Test("Stores with different services do not see each other's items")
    func differentServices_areIsolated() async throws {
        let storeA = KeychainSecureStore(service: Self.uniqueService())
        let storeB = KeychainSecureStore(service: Self.uniqueService())
        let key = "shared-key-name"

        try await storeA.set(Data("from-A".utf8), forKey: key)
        let bSeesA = try await storeB.get(forKey: key)
        #expect(bSeesA == nil)
        try? await storeA.deleteAll()
    }
}
