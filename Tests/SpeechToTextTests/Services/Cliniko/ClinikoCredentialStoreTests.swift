import Foundation
import Testing
@testable import SpeechToText

@Suite("ClinikoCredentialStore", .tags(.fast))
struct ClinikoCredentialStoreTests {

    /// A fresh in-memory `UserDefaults` suite per test, so concurrent tests
    /// never collide on the shared standard suite. Mirrors the pattern called
    /// out by issue #32.
    private func makeUserDefaults() -> UserDefaults {
        let suiteName = "ClinikoCredentialStoreTests-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            preconditionFailure("UserDefaults(suiteName:) unexpectedly nil")
        }
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    private func makeStore(
        secureStore: any SecureStore = InMemorySecureStore(),
        userDefaults: UserDefaults? = nil
    ) -> ClinikoCredentialStore {
        ClinikoCredentialStore(
            secureStore: secureStore,
            userDefaults: userDefaults ?? makeUserDefaults()
        )
    }

    // MARK: - Empty state

    @Test("loadCredentials returns nil when nothing is stored")
    func loadCredentialsEmpty() async throws {
        let store = makeStore()
        let creds = try await store.loadCredentials()
        #expect(creds == nil)
    }

    @Test("hasAPIKey returns false when nothing is stored")
    func hasAPIKeyEmpty() async throws {
        let store = makeStore()
        let present = try await store.hasAPIKey()
        #expect(present == false)
    }

    @Test("loadShard defaults to ClinikoShard.default")
    func loadShardDefault() {
        // `loadShard` is `nonisolated` — no `await` needed.
        let store = makeStore()
        let shard = store.loadShard()
        #expect(shard == .default)
    }

    // MARK: - Save / load round-trip

    @Test("saveCredentials stores key in SecureStore + shard in UserDefaults")
    func saveRoundTrip() async throws {
        let secureStore = InMemorySecureStore()
        let userDefaults = makeUserDefaults()
        let store = makeStore(secureStore: secureStore, userDefaults: userDefaults)

        try await store.saveCredentials(apiKey: "MS-secret-uk2", shard: .uk2)

        let storedRaw = try await secureStore.getString(forKey: ClinikoCredentialStore.apiKeyAccount)
        #expect(storedRaw == "MS-secret-uk2")

        let storedShard = userDefaults.string(forKey: ClinikoCredentialStore.shardUserDefaultsKey)
        #expect(storedShard == "uk2")

        let creds = try await store.loadCredentials()
        let expected = try ClinikoCredentials(apiKey: "MS-secret-uk2", shard: .uk2)
        #expect(creds == expected)
    }

    @Test("hasAPIKey reflects current state")
    func hasAPIKeyReflectsState() async throws {
        let store = makeStore()
        try await store.saveCredentials(apiKey: "k", shard: .au1)
        let present = try await store.hasAPIKey()
        #expect(present == true)
    }

    // MARK: - Validation

    @Test("saveCredentials rejects empty key with .missingAPIKey")
    func rejectsEmptyKey() async {
        let store = makeStore()
        await #expect(throws: ClinikoCredentialStore.Failure.self) {
            try await store.saveCredentials(apiKey: "", shard: .au1)
        }
    }

    @Test("saveCredentials rejects whitespace-only key")
    func rejectsWhitespace() async {
        let store = makeStore()
        await #expect(throws: ClinikoCredentialStore.Failure.self) {
            try await store.saveCredentials(apiKey: "   \n\t  ", shard: .au1)
        }
    }

    @Test("saveCredentials trims whitespace before storing")
    func trimsWhitespace() async throws {
        let secureStore = InMemorySecureStore()
        let store = makeStore(secureStore: secureStore)
        try await store.saveCredentials(apiKey: "  MS-key-au1  \n", shard: .au1)
        let storedRaw = try await secureStore.getString(forKey: ClinikoCredentialStore.apiKeyAccount)
        #expect(storedRaw == "MS-key-au1")
    }

    @Test("hasAPIKey treats empty / whitespace-only stored value as absent")
    func emptyStoredValueTreatedAsAbsent() async throws {
        let secureStore = InMemorySecureStore()
        try await secureStore.setString("   ", forKey: ClinikoCredentialStore.apiKeyAccount)
        let store = makeStore(secureStore: secureStore)
        #expect(try await store.hasAPIKey() == false)
        #expect(try await store.loadCredentials() == nil)
    }

    // MARK: - Update / delete

    @Test("updateShard persists without touching the API key")
    func updateShardOnly() async throws {
        let secureStore = InMemorySecureStore()
        let userDefaults = makeUserDefaults()
        let store = makeStore(secureStore: secureStore, userDefaults: userDefaults)
        try await store.saveCredentials(apiKey: "k", shard: .au1)
        // `updateShard` is `nonisolated` — no `await` needed.
        store.updateShard(.uk2)

        let stored = userDefaults.string(forKey: ClinikoCredentialStore.shardUserDefaultsKey)
        #expect(stored == "uk2")
        let key = try await secureStore.getString(forKey: ClinikoCredentialStore.apiKeyAccount)
        #expect(key == "k")
    }

    @Test("deleteCredentials removes both the key and the shard")
    func deleteCredentials() async throws {
        let secureStore = InMemorySecureStore()
        let userDefaults = makeUserDefaults()
        let store = makeStore(secureStore: secureStore, userDefaults: userDefaults)
        try await store.saveCredentials(apiKey: "k", shard: .uk1)

        try await store.deleteCredentials()

        #expect(try await store.hasAPIKey() == false)
        let storedShard = userDefaults.string(forKey: ClinikoCredentialStore.shardUserDefaultsKey)
        #expect(storedShard == nil)
        let creds = try await store.loadCredentials()
        #expect(creds == nil)
    }

    @Test("deleteCredentials on empty store is a no-op")
    func deleteEmptyIsNoOp() async {
        let store = makeStore()
        do {
            try await store.deleteCredentials()
        } catch {
            Issue.record("deleteCredentials should not throw on an empty store: \(error)")
        }
    }

    @Test("deleteCredentials retains the shard when SecureStore.delete throws")
    func deleteCredentialsRetainsShardOnSecureStoreFailure() async throws {
        // Pre-seed the shard via a working store, then swap in a throwing
        // SecureStore that shares the same UserDefaults instance.
        let userDefaults = makeUserDefaults()
        userDefaults.set("uk2", forKey: ClinikoCredentialStore.shardUserDefaultsKey)

        let store = ClinikoCredentialStore(
            secureStore: ThrowingSecureStore(mode: .alwaysThrow),
            userDefaults: userDefaults
        )

        await #expect(throws: ClinikoCredentialStore.Failure.self) {
            try await store.deleteCredentials()
        }
        // On Keychain failure the shard MUST remain — the API key is still
        // there too, and clearing the shard alone would amputate the pair so
        // that `loadCredentials` returns au1 (the default) against the user's
        // real uk2 key, which would 401. Retaining both halves preserves
        // user intent until a retry succeeds.
        let storedShard = userDefaults.string(forKey: ClinikoCredentialStore.shardUserDefaultsKey)
        #expect(storedShard == "uk2", "shard must be retained when Keychain delete fails")
    }

    // MARK: - Contact email (#89)

    @Test("loadContactEmail returns nil when nothing is stored")
    func loadContactEmailEmpty() {
        let store = makeStore()
        #expect(store.loadContactEmail() == nil)
    }

    @Test("updateContactEmail + loadContactEmail round-trip")
    func contactEmailRoundTrip() {
        let userDefaults = makeUserDefaults()
        let store = makeStore(userDefaults: userDefaults)

        store.updateContactEmail("doctor@example.test")
        #expect(store.loadContactEmail() == "doctor@example.test")
        #expect(userDefaults.string(forKey: ClinikoCredentialStore.contactEmailUserDefaultsKey)
                == "doctor@example.test")
    }

    @Test("updateContactEmail trims whitespace before storing")
    func contactEmailTrims() {
        let userDefaults = makeUserDefaults()
        let store = makeStore(userDefaults: userDefaults)

        store.updateContactEmail("  doctor@example.test  \n")
        #expect(store.loadContactEmail() == "doctor@example.test")
    }

    @Test("updateContactEmail with nil clears the stored value")
    func contactEmailNilClears() {
        let userDefaults = makeUserDefaults()
        let store = makeStore(userDefaults: userDefaults)

        store.updateContactEmail("doctor@example.test")
        store.updateContactEmail(nil)
        #expect(store.loadContactEmail() == nil)
        #expect(userDefaults.object(forKey: ClinikoCredentialStore.contactEmailUserDefaultsKey) == nil)
    }

    @Test("updateContactEmail with whitespace-only clears the stored value")
    func contactEmailWhitespaceClears() {
        let userDefaults = makeUserDefaults()
        let store = makeStore(userDefaults: userDefaults)

        store.updateContactEmail("doctor@example.test")
        store.updateContactEmail("   \t\n  ")
        // Whitespace-only must be treated the same as nil — otherwise the
        // UA builder would emit `"mac-speech-to-text (   )"`.
        #expect(store.loadContactEmail() == nil)
    }

    @Test("static loadContactEmail(from:) reads the same key as the instance method")
    func contactEmailStaticReadMatchesInstance() {
        let userDefaults = makeUserDefaults()
        let store = makeStore(userDefaults: userDefaults)

        store.updateContactEmail("ops@example.test")
        // The static convenience is what `ClinikoUserAgent.defaultProvider()`
        // calls — it must agree with the instance method that the UI uses
        // to write, otherwise the UA would diverge from what the user typed.
        #expect(ClinikoCredentialStore.loadContactEmail(from: userDefaults) == "ops@example.test")
    }

    @Test("deleteCredentials does NOT clear the contact email")
    func deleteCredentialsPreservesContactEmail() async throws {
        // The contact email is a preference about who Cliniko should contact,
        // not material tied to the API key. Rotating credentials shouldn't
        // make the doctor re-enter their own contact.
        let userDefaults = makeUserDefaults()
        let store = makeStore(userDefaults: userDefaults)
        try await store.saveCredentials(apiKey: "k", shard: .au1)
        store.updateContactEmail("doctor@example.test")

        try await store.deleteCredentials()

        #expect(store.loadContactEmail() == "doctor@example.test",
                "contact email should survive credential removal")
    }

    // MARK: - Service / account constants are pinned

    @Test("service + account constants match the Cliniko reference doc")
    func pinConstants() {
        #expect(ClinikoCredentialStore.serviceName == "com.speechtotext.cliniko")
        #expect(ClinikoCredentialStore.apiKeyAccount == "api_key")
        #expect(ClinikoCredentialStore.shardUserDefaultsKey == "cliniko.shard")
        #expect(ClinikoCredentialStore.contactEmailUserDefaultsKey == "cliniko.contactEmail")
    }

    // MARK: - SecureStore failure surfacing

    @Test("SecureStore read failures surface as .readFailed with underlying error")
    func secureStoreReadFailureWrapped() async {
        let store = makeStore(secureStore: ThrowingSecureStore(mode: .alwaysThrow))
        do {
            _ = try await store.loadCredentials()
            Issue.record("expected loadCredentials to throw")
        } catch let failure as ClinikoCredentialStore.Failure {
            guard case .readFailed = failure else {
                Issue.record("expected .readFailed, got \(failure)")
                return
            }
        } catch {
            Issue.record("unexpected error type \(type(of: error))")
        }

        do {
            _ = try await store.hasAPIKey()
            Issue.record("expected hasAPIKey to throw")
        } catch let failure as ClinikoCredentialStore.Failure {
            guard case .readFailed = failure else {
                Issue.record("expected .readFailed for hasAPIKey, got \(failure)")
                return
            }
        } catch {
            Issue.record("unexpected error type \(type(of: error))")
        }
    }

    @Test("SecureStore write failures surface as .writeFailed")
    func secureStoreWriteFailureWrapped() async {
        let store = makeStore(secureStore: ThrowingSecureStore(mode: .alwaysThrow))
        do {
            try await store.saveCredentials(apiKey: "k", shard: .au1)
            Issue.record("expected saveCredentials to throw")
        } catch let failure as ClinikoCredentialStore.Failure {
            guard case .writeFailed = failure else {
                Issue.record("expected .writeFailed, got \(failure)")
                return
            }
        } catch {
            Issue.record("unexpected error type \(type(of: error))")
        }
    }

    @Test("SecureStore delete failures surface as .deleteFailed")
    func secureStoreDeleteFailureWrapped() async {
        let store = makeStore(secureStore: ThrowingSecureStore(mode: .alwaysThrow))
        do {
            try await store.deleteCredentials()
            Issue.record("expected deleteCredentials to throw")
        } catch let failure as ClinikoCredentialStore.Failure {
            guard case .deleteFailed = failure else {
                Issue.record("expected .deleteFailed, got \(failure)")
                return
            }
        } catch {
            Issue.record("unexpected error type \(type(of: error))")
        }
    }

    @Test("missing API key surfaces as .missingAPIKey")
    func missingAPIKeyCase() async {
        let store = makeStore()
        do {
            try await store.saveCredentials(apiKey: "", shard: .au1)
            Issue.record("expected saveCredentials to throw")
        } catch ClinikoCredentialStore.Failure.missingAPIKey {
            // expected
        } catch {
            Issue.record("expected .missingAPIKey, got \(type(of: error))")
        }
    }
}

// MARK: - Test fakes

/// `SecureStore` fake that throws on every call. Used to verify failure
/// surfacing without depending on a real Keychain error path.
private actor ThrowingSecureStore: SecureStore {
    enum Mode { case alwaysThrow }

    struct Boom: Error, Equatable {}

    private let mode: Mode
    init(mode: Mode) { self.mode = mode }

    func set(_ data: Data, forKey key: String) async throws { throw Boom() }
    func get(forKey key: String) async throws -> Data? { throw Boom() }
    func delete(forKey key: String) async throws { throw Boom() }
    func deleteAll() async throws { throw Boom() }
}
