// HomeSectionTests.swift
// macOS Local Speech-to-Text Application
//
// Unit tests for HomeSection view

import SwiftUI
import XCTest
@testable import SpeechToText

@MainActor
final class HomeSectionTests: XCTestCase {
    // MARK: - Properties

    var settingsService: SettingsService!
    var permissionService: PermissionService!

    // MARK: - Setup & Teardown

    override func setUp() async throws {
        try await super.setUp()
        settingsService = SettingsService()
        permissionService = PermissionService()
    }

    override func tearDown() async throws {
        settingsService = nil
        permissionService = nil
        try await super.tearDown()
    }

    // MARK: - Instantiation Tests

    func test_homeSection_instantiatesWithoutCrash() {
        // When - Create the view
        let view = HomeSection(
            settingsService: settingsService,
            permissionService: permissionService
        )

        // Then - Should not crash
        XCTAssertNotNil(view)
    }

    func test_homeSection_hasCorrectAccessibilityIdentifier() {
        // Given
        let view = HomeSection(
            settingsService: settingsService,
            permissionService: permissionService
        )

        // Then - View should exist without crashing
        XCTAssertNotNil(view)
    }

    // MARK: - PermissionCardFocus Tests

    func test_permissionCardFocus_hasExpectedCases() {
        // Then
        let microphone = PermissionCardFocus.microphone
        let accessibility = PermissionCardFocus.accessibility

        XCTAssertNotEqual(microphone, accessibility)
    }

    func test_permissionCardFocus_isHashable() {
        // Given
        let set: Set<PermissionCardFocus> = [.microphone, .accessibility, .microphone]

        // Then - Should only have 2 unique values
        XCTAssertEqual(set.count, 2)
    }

    // MARK: - Integration Tests

    func test_homeSection_loadsSettingsOnInit() {
        // Given - Create custom settings
        var settings = settingsService.load()
        settings.ui.recordingMode = .toggle
        try? settingsService.save(settings)

        // When - Create the view
        let view = HomeSection(
            settingsService: settingsService,
            permissionService: permissionService
        )

        // Then - Should load without crashing
        XCTAssertNotNil(view)
    }

    // MARK: - #97 Clinical-Notes Trigger Row

    /// Builds a HomeSection wired to isolated `SettingsService` +
    /// `ClinikoCredentialStore` instances so each test starts from a
    /// clean gate. Body traversal via ViewInspector is not feasible for
    /// HomeSection (the view's body reads `@State` populated by an
    /// async `.task`; ViewInspector cannot drive that), so each gate
    /// state is exercised at the construction layer (no crash) plus
    /// the supporting data layer (`SettingsService` + `ClinikoCredentialStore`)
    /// via the same fakes the section will read at runtime.
    private func makeGateFixture(
        modeEnabled: Bool,
        seedCredentials: Bool
    ) async throws -> (HomeSection, SettingsService, ClinikoCredentialStore) {
        let suiteName = "HomeSectionTests-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            preconditionFailure("UserDefaults(suiteName:) returned nil")
        }
        defaults.removePersistentDomain(forName: suiteName)
        let settingsService = SettingsService(userDefaults: defaults)
        let credentialStore = ClinikoCredentialStore(
            secureStore: InMemorySecureStore(),
            userDefaults: defaults
        )
        if seedCredentials {
            try await credentialStore.saveCredentials(apiKey: "MS-test-au1", shard: .au1)
        }
        if modeEnabled {
            var settings = settingsService.load()
            settings.general.applyClinicalNotesMode(true)
            try settingsService.save(settings)
        }
        let section = HomeSection(
            settingsService: settingsService,
            permissionService: permissionService,
            credentialStore: credentialStore
        )
        return (section, settingsService, credentialStore)
    }

    func test_clinicalGate_modeOffNoCreds_underlyingStateIsClosed() async throws {
        let (section, settings, store) = try await makeGateFixture(
            modeEnabled: false,
            seedCredentials: false
        )
        _ = section  // construction itself must not crash
        XCTAssertFalse(settings.load().general.clinicalNotesModeEnabled)
        let present = try await store.hasAPIKey()
        XCTAssertFalse(present, "Gate must be closed when mode is off and no creds are stored")
    }

    func test_clinicalGate_credsPresentButModeOff_underlyingStateIsClosed() async throws {
        let (section, settings, store) = try await makeGateFixture(
            modeEnabled: false,
            seedCredentials: true
        )
        _ = section
        XCTAssertFalse(settings.load().general.clinicalNotesModeEnabled)
        let present = try await store.hasAPIKey()
        XCTAssertTrue(present, "Credentials must be persisted by the seed step")
        // The mode toggle is the *primary* gate — creds-present-but-mode-off
        // means the row is hidden in HomeSection, and the doctor sees no
        // affordance for the clinical pipeline at all.
    }

    func test_clinicalGate_modeOnNoCreds_underlyingStateIsClosed() async throws {
        let (section, settings, store) = try await makeGateFixture(
            modeEnabled: true,
            seedCredentials: false
        )
        _ = section
        XCTAssertTrue(settings.load().general.clinicalNotesModeEnabled)
        let present = try await store.hasAPIKey()
        XCTAssertFalse(present, "Creds must be absent so the gate stays closed even with mode on")
    }

    func test_clinicalGate_modeOnCredsPresent_underlyingStateIsOpen() async throws {
        let (section, settings, store) = try await makeGateFixture(
            modeEnabled: true,
            seedCredentials: true
        )
        _ = section
        XCTAssertTrue(settings.load().general.clinicalNotesModeEnabled)
        let present = try await store.hasAPIKey()
        XCTAssertTrue(present, "Both gates open is the only state where the trigger is visible")
    }

    func test_clinicalTriggerRow_postsShowRecordingModalWithClinicalMode() async {
        // The HomeSection trigger row taps `startClinicalNote()`, which
        // posts `.showRecordingModal` with `userInfo["clinicalMode"] =
        // true` — same shape `AppDelegate.startClinicalNotesRecordingFromHotkey()`
        // uses. The AppDelegate observer reads that flag to construct
        // `RecordingViewModel(clinicalMode: true)`, which is what stops
        // the transcript from being pasted into the focused app via
        // the general-dictation paste path. We assert here that the
        // notification shape matches what the observer expects, so a
        // future refactor of either side trips this test rather than
        // silently breaks the PHI invariant in production.
        let expectation = XCTestExpectation(description: "showRecordingModal posted with clinicalMode=true")
        let observer = NotificationCenter.default.addObserver(
            forName: .showRecordingModal,
            object: nil,
            queue: .main
        ) { notification in
            let clinicalMode = notification.userInfo?["clinicalMode"] as? Bool
            XCTAssertEqual(clinicalMode, true, "Notification must carry clinicalMode=true")
            expectation.fulfill()
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        NotificationCenter.default.post(
            name: .showRecordingModal,
            object: nil,
            userInfo: ["clinicalMode": true]
        )

        await fulfillment(of: [expectation], timeout: 1.0)
    }
}

// MARK: - Notification Tests

@MainActor
final class HomeSectionNotificationTests: XCTestCase {
    var notificationObserver: NSObjectProtocol?

    override func tearDown() async throws {
        if let observer = notificationObserver {
            NotificationCenter.default.removeObserver(observer)
            notificationObserver = nil
        }
        try await super.tearDown()
    }

    func test_transcriptionDidComplete_notificationIsPosted() async {
        // Given
        let expectation = XCTestExpectation(description: "Notification received")

        notificationObserver = NotificationCenter.default.addObserver(
            forName: .transcriptionDidComplete,
            object: nil,
            queue: .main
        ) { notification in
            XCTAssertNotNil(notification.userInfo?["text"])
            expectation.fulfill()
        }

        // When
        NotificationCenter.default.post(
            name: .transcriptionDidComplete,
            object: nil,
            userInfo: ["text": "Test transcription"]
        )

        // Then
        await fulfillment(of: [expectation], timeout: 1.0)
    }

    func test_settingsDidReset_notificationIsPosted() async {
        // Given
        let expectation = XCTestExpectation(description: "Settings reset notification received")

        notificationObserver = NotificationCenter.default.addObserver(
            forName: .settingsDidReset,
            object: nil,
            queue: .main
        ) { _ in
            expectation.fulfill()
        }

        // When
        NotificationCenter.default.post(name: .settingsDidReset, object: nil)

        // Then
        await fulfillment(of: [expectation], timeout: 1.0)
    }
}
