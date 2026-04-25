import Foundation
import XCTest
@testable import SpeechToText

/// VM-level tests for `ClinicalNotesSectionViewModel`. Use the in-memory
/// SecureStore fake + the URLProtocolStub-backed session to exercise
/// save/test/remove without touching the real Keychain or the network.
@MainActor
final class ClinicalNotesSectionViewModelTests: XCTestCase {

    override func tearDown() {
        URLProtocolStub.reset()
        super.tearDown()
    }

    // MARK: - Helpers

    private func makeUserDefaults() -> UserDefaults {
        let suiteName = "ClinicalNotesSectionVMTests-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("UserDefaults(suiteName:) returned nil")
            preconditionFailure("UserDefaults(suiteName:) returned nil")
        }
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    private func makeStore(
        secureStore: any SecureStore = InMemorySecureStore(),
        userDefaults: UserDefaults? = nil
    ) -> (ClinikoCredentialStore, any SecureStore, UserDefaults) {
        let userDefaults = userDefaults ?? makeUserDefaults()
        let store = ClinikoCredentialStore(secureStore: secureStore, userDefaults: userDefaults)
        return (store, secureStore, userDefaults)
    }

    private func makeProbe(
        responder: @escaping URLProtocolStub.Responder
    ) -> ClinikoAuthProbe {
        let config = URLProtocolStub.install(responder)
        let session = URLSession(configuration: config)
        return ClinikoAuthProbe(session: session, userAgent: "vm-tests/1.0")
    }

    private func neverInvokedProbe(file: StaticString = #file, line: UInt = #line) -> ClinikoAuthProbe {
        makeProbe { _ in
            XCTFail("probe must not be invoked", file: file, line: line)
            throw URLError(.cannotConnectToHost)
        }
    }

    private func httpResponseProbe(status: Int) -> ClinikoAuthProbe {
        makeProbe { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: status,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, Data())
        }
    }

    // MARK: - Initial state

    func test_initial_state_isClean() {
        let (store, _, _) = makeStore()
        let vm = ClinicalNotesSectionViewModel(credentialStore: store, authProbe: neverInvokedProbe())
        XCTAssertEqual(vm.apiKeyDraft, "")
        XCTAssertEqual(vm.selectedShard, .default)
        XCTAssertFalse(vm.hasStoredCredentials)
        XCTAssertFalse(vm.isApiKeyDraftValid)
        XCTAssertEqual(vm.credentialState, .unknown)
        XCTAssertEqual(vm.verificationStatus, .absent)
        XCTAssertEqual(vm.connectionStatus, .idle)
        XCTAssertNil(vm.statusMessage)
        XCTAssertFalse(vm.isBusy)
    }

    func test_isApiKeyDraftValid_reflectsTrimmedDraft() {
        let (store, _, _) = makeStore()
        let vm = ClinicalNotesSectionViewModel(credentialStore: store, authProbe: neverInvokedProbe())

        XCTAssertFalse(vm.isApiKeyDraftValid, "empty draft is invalid")

        vm.apiKeyDraft = "   "
        XCTAssertFalse(vm.isApiKeyDraftValid, "whitespace-only draft is invalid")

        vm.apiKeyDraft = "MS-test-au1"
        XCTAssertTrue(vm.isApiKeyDraftValid)

        vm.apiKeyDraft = "  MS-trim  "
        XCTAssertTrue(vm.isApiKeyDraftValid, "trimmable non-empty draft is valid")
    }

    // MARK: - Refresh

    func test_refresh_loadsExistingCredentialsState() async throws {
        let secureStore = InMemorySecureStore()
        let userDefaults = makeUserDefaults()
        let (store, _, _) = makeStore(secureStore: secureStore, userDefaults: userDefaults)
        try await store.saveCredentials(apiKey: "MS-key-uk2", shard: .uk2)

        let vm = ClinicalNotesSectionViewModel(credentialStore: store, authProbe: neverInvokedProbe())
        await vm.refreshState()

        XCTAssertTrue(vm.hasStoredCredentials)
        XCTAssertEqual(vm.credentialState, .present)
        XCTAssertEqual(vm.verificationStatus, .unverified, "freshly loaded credentials are 'unverified' until probe succeeds")
        XCTAssertEqual(vm.selectedShard, .uk2)
        XCTAssertEqual(vm.apiKeyDraft, "", "draft must never be hydrated from the keychain")
    }

    func test_refresh_keychainReadFailure_doesNotCollapseToAbsent() async {
        let (store, _, _) = makeStore(secureStore: ThrowingSecureStore())
        let vm = ClinicalNotesSectionViewModel(credentialStore: store, authProbe: neverInvokedProbe())

        await vm.refreshState()

        // Critical: a Keychain read error must NOT silently flip
        // hasStoredCredentials to `false` — that would silently disable
        // Clinical Notes Mode (#11) on a transiently locked Keychain.
        XCTAssertEqual(vm.credentialState, .readFailed)
        XCTAssertFalse(vm.hasStoredCredentials, "hasStoredCredentials is computed; read-failure surface is .readFailed not .absent")
        XCTAssertEqual(vm.verificationStatus, .readError)
        XCTAssertEqual(vm.connectionStatus, .failure)
        XCTAssertNotNil(vm.statusMessage)
        XCTAssertEqual(vm.statusCardDisplay.title, "Could not read stored credentials")
    }

    func test_refresh_emptyStore_marksAbsent() async {
        let (store, _, _) = makeStore()
        let vm = ClinicalNotesSectionViewModel(credentialStore: store, authProbe: neverInvokedProbe())

        await vm.refreshState()

        XCTAssertEqual(vm.credentialState, .absent)
        XCTAssertEqual(vm.verificationStatus, .absent)
        XCTAssertFalse(vm.hasStoredCredentials)
        XCTAssertEqual(vm.statusCardDisplay.title, "No Cliniko credentials")
    }

    // MARK: - Save flow

    func test_saveAndTest_withValidKey_storesAndReportsSuccess() async throws {
        let secureStore = InMemorySecureStore()
        let (store, _, userDefaults) = makeStore(secureStore: secureStore)
        let vm = ClinicalNotesSectionViewModel(credentialStore: store, authProbe: httpResponseProbe(status: 200))
        vm.apiKeyDraft = "MS-test-au1"
        vm.selectedShard = .au1

        await vm.saveAndTest()

        XCTAssertTrue(vm.hasStoredCredentials)
        XCTAssertEqual(vm.verificationStatus, .verified)
        XCTAssertEqual(vm.connectionStatus, .success)
        XCTAssertEqual(vm.apiKeyDraft, "", "draft must be cleared after a successful save")
        XCTAssertEqual(vm.statusCardDisplay.title, "Connected to Cliniko")

        let storedKey = try await secureStore.getString(forKey: ClinikoCredentialStore.apiKeyAccount)
        XCTAssertEqual(storedKey, "MS-test-au1")
        XCTAssertEqual(userDefaults.string(forKey: ClinikoCredentialStore.shardUserDefaultsKey), "au1")
    }

    func test_saveAndTest_with401_keepsKeyButReportsFailureAndStaysUnverified() async throws {
        let secureStore = InMemorySecureStore()
        let (store, _, _) = makeStore(secureStore: secureStore)
        let vm = ClinicalNotesSectionViewModel(credentialStore: store, authProbe: httpResponseProbe(status: 401))
        vm.apiKeyDraft = "MS-bad-au1"

        await vm.saveAndTest()

        // Save succeeded; probe rejected. We keep what they typed (operators
        // sometimes paste while offline) but the status card MUST NOT show
        // green just because the key is now in the keychain.
        XCTAssertTrue(vm.hasStoredCredentials)
        XCTAssertEqual(vm.verificationStatus, .unverified, "probe failure must keep card in unverified state")
        XCTAssertEqual(vm.connectionStatus, .failure)
        XCTAssertNotNil(vm.statusMessage)
        XCTAssertEqual(vm.apiKeyDraft, "")
        XCTAssertEqual(vm.statusCardDisplay.title, "Saved but not yet verified")

        let storedKey = try await secureStore.getString(forKey: ClinikoCredentialStore.apiKeyAccount)
        XCTAssertEqual(storedKey, "MS-bad-au1")
    }

    func test_saveAndTest_with500_keepsKeyAndShowsHTTPMessage() async throws {
        let secureStore = InMemorySecureStore()
        let (store, _, _) = makeStore(secureStore: secureStore)
        let vm = ClinicalNotesSectionViewModel(credentialStore: store, authProbe: httpResponseProbe(status: 500))
        vm.apiKeyDraft = "MS-test-au1"

        await vm.saveAndTest()

        XCTAssertTrue(vm.hasStoredCredentials)
        XCTAssertEqual(vm.verificationStatus, .unverified)
        XCTAssertEqual(vm.connectionStatus, .failure)
        XCTAssertEqual(vm.statusCardDisplay.title, "Saved but not yet verified")
        XCTAssertNotNil(vm.statusMessage)
        XCTAssertTrue(vm.statusMessage?.contains("500") == true)
    }

    func test_saveAndTest_offlineProbe_keepsKeyAndOffersNetworkGuidance() async throws {
        let secureStore = InMemorySecureStore()
        let (store, _, _) = makeStore(secureStore: secureStore)
        let probe = makeProbe { _ in throw URLError(.notConnectedToInternet) }
        let vm = ClinicalNotesSectionViewModel(credentialStore: store, authProbe: probe)
        vm.apiKeyDraft = "MS-test-au1"

        await vm.saveAndTest()

        XCTAssertTrue(vm.hasStoredCredentials)
        XCTAssertEqual(vm.verificationStatus, .unverified)
        XCTAssertEqual(vm.connectionStatus, .failure)
        XCTAssertEqual(vm.statusMessage, "You appear to be offline. Reconnect and try again.")
    }

    func test_saveAndTest_dnsFailure_offersRegionHint() async throws {
        let secureStore = InMemorySecureStore()
        let (store, _, _) = makeStore(secureStore: secureStore)
        let probe = makeProbe { _ in throw URLError(.cannotFindHost) }
        let vm = ClinicalNotesSectionViewModel(credentialStore: store, authProbe: probe)
        vm.apiKeyDraft = "MS-test-au1"
        vm.selectedShard = .au1

        await vm.saveAndTest()

        XCTAssertEqual(vm.verificationStatus, .unverified)
        XCTAssertNotNil(vm.statusMessage)
        XCTAssertTrue(vm.statusMessage?.contains("region correct") == true,
                      "DNS failure should suggest checking the shard; got: \(vm.statusMessage ?? "<nil>")")
    }

    func test_saveAndTest_emptyKey_failsWithoutWriting() async throws {
        let secureStore = InMemorySecureStore()
        let (store, _, _) = makeStore(secureStore: secureStore)
        let vm = ClinicalNotesSectionViewModel(credentialStore: store, authProbe: neverInvokedProbe())
        vm.apiKeyDraft = "  "

        await vm.saveAndTest()

        XCTAssertFalse(vm.hasStoredCredentials)
        XCTAssertEqual(vm.connectionStatus, .failure)
        let storedKey = try await secureStore.getString(forKey: ClinikoCredentialStore.apiKeyAccount)
        XCTAssertNil(storedKey)
    }

    func test_saveAndTest_secureStoreWriteFailure_reportsFailureNoKeyStored() async {
        let (store, _, _) = makeStore(secureStore: ThrowingSecureStore())
        let vm = ClinicalNotesSectionViewModel(credentialStore: store, authProbe: neverInvokedProbe())
        vm.apiKeyDraft = "MS-test-au1"

        await vm.saveAndTest()

        XCTAssertFalse(vm.hasStoredCredentials)
        XCTAssertEqual(vm.verificationStatus, .absent)
        XCTAssertEqual(vm.connectionStatus, .failure)
        XCTAssertNotNil(vm.statusMessage)
    }

    // MARK: - Test connection (separate button)

    func test_testConnection_onSavedCredentials_succeeds() async throws {
        let secureStore = InMemorySecureStore()
        let (store, _, _) = makeStore(secureStore: secureStore)
        try await store.saveCredentials(apiKey: "MS-test-uk1", shard: .uk1)

        let vm = ClinicalNotesSectionViewModel(
            credentialStore: store,
            authProbe: makeProbe { request in
                XCTAssertEqual(request.url?.absoluteString, "https://api.uk1.cliniko.com/v1/users/me")
                let response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )!
                return (response, Data())
            }
        )
        await vm.refreshState()

        await vm.testConnection()

        XCTAssertEqual(vm.verificationStatus, .verified)
        XCTAssertEqual(vm.connectionStatus, .success)
    }

    func test_testConnection_withoutCredentials_reportsFailure() async {
        let (store, _, _) = makeStore()
        let vm = ClinicalNotesSectionViewModel(credentialStore: store, authProbe: neverInvokedProbe())

        await vm.testConnection()

        XCTAssertEqual(vm.connectionStatus, .failure)
        XCTAssertNotNil(vm.statusMessage)
    }

    // MARK: - Remove

    func test_remove_clearsKeyShardAndDraft() async throws {
        let secureStore = InMemorySecureStore()
        let userDefaults = makeUserDefaults()
        let (store, _, _) = makeStore(secureStore: secureStore, userDefaults: userDefaults)
        try await store.saveCredentials(apiKey: "MS-test-au2", shard: .au2)

        let vm = ClinicalNotesSectionViewModel(credentialStore: store, authProbe: neverInvokedProbe())
        await vm.refreshState()
        vm.apiKeyDraft = "leftover"

        await vm.removeCredentials()

        XCTAssertFalse(vm.hasStoredCredentials)
        XCTAssertEqual(vm.credentialState, .absent)
        XCTAssertEqual(vm.verificationStatus, .absent)
        XCTAssertEqual(vm.selectedShard, .default)
        XCTAssertEqual(vm.apiKeyDraft, "")
        XCTAssertEqual(vm.connectionStatus, .idle)
        let storedKey = try await secureStore.getString(forKey: ClinikoCredentialStore.apiKeyAccount)
        XCTAssertNil(storedKey)
        XCTAssertNil(userDefaults.string(forKey: ClinikoCredentialStore.shardUserDefaultsKey))
    }

    func test_remove_keychainFailure_retainsShardAndShowsBanner() async throws {
        // Pre-seed the shard but back the store with a throwing SecureStore.
        let userDefaults = makeUserDefaults()
        userDefaults.set("uk2", forKey: ClinikoCredentialStore.shardUserDefaultsKey)
        let store = ClinikoCredentialStore(
            secureStore: ThrowingSecureStore(),
            userDefaults: userDefaults
        )

        let vm = ClinicalNotesSectionViewModel(credentialStore: store, authProbe: neverInvokedProbe())
        vm.apiKeyDraft = "leftover"
        // Refresh will fail (read failure) and mark .readFailed.
        await vm.refreshState()
        XCTAssertEqual(vm.credentialState, .readFailed)

        await vm.removeCredentials()

        XCTAssertEqual(vm.connectionStatus, .failure)
        XCTAssertNotNil(vm.statusMessage)
        // On Keychain delete failure the store retains the shard so the
        // surviving API key + shard remain a valid pair the user can either
        // retry or keep using. The VM's banner tells the user the key may
        // still be in Keychain; the shard just stays consistent with that.
        XCTAssertEqual(userDefaults.string(forKey: ClinikoCredentialStore.shardUserDefaultsKey), "uk2",
                       "shard must be retained when Keychain delete fails so the on-disk pair stays consistent")
    }

    // MARK: - Shard picker

    func test_shardPickerChange_persistsShardWhenCredentialsExist() async throws {
        let userDefaults = makeUserDefaults()
        let secureStore = InMemorySecureStore()
        let (store, _, _) = makeStore(secureStore: secureStore, userDefaults: userDefaults)
        try await store.saveCredentials(apiKey: "k", shard: .au1)

        let vm = ClinicalNotesSectionViewModel(credentialStore: store, authProbe: neverInvokedProbe())
        await vm.refreshState()
        XCTAssertEqual(vm.selectedShard, .au1)

        vm.selectedShard = .uk2

        // didSet on selectedShard hits the nonisolated UserDefaults write
        // synchronously, so we can assert without yielding.
        XCTAssertEqual(userDefaults.string(forKey: ClinikoCredentialStore.shardUserDefaultsKey), "uk2")
        // Pointing at a different tenant invalidates the prior probe.
        XCTAssertEqual(vm.verificationStatus, .unverified)
    }

    func test_shardPickerChange_doesNotPersistBeforeCredentialsSaved() {
        let userDefaults = makeUserDefaults()
        let (store, _, _) = makeStore(userDefaults: userDefaults)
        let vm = ClinicalNotesSectionViewModel(credentialStore: store, authProbe: neverInvokedProbe())

        vm.selectedShard = .uk2

        // No credentials yet — picker change should not write to UserDefaults.
        // The shard will be persisted alongside the API key on save.
        XCTAssertNil(userDefaults.string(forKey: ClinikoCredentialStore.shardUserDefaultsKey))
    }
}

// MARK: - Test fakes

/// `SecureStore` fake that throws on every call. Used to verify failure
/// surfacing without depending on a real Keychain error path.
private actor ThrowingSecureStore: SecureStore {
    struct Boom: Error, Equatable {}

    func set(_ data: Data, forKey key: String) async throws { throw Boom() }
    func get(forKey key: String) async throws -> Data? { throw Boom() }
    func delete(forKey key: String) async throws { throw Boom() }
    func deleteAll() async throws { throw Boom() }
}
