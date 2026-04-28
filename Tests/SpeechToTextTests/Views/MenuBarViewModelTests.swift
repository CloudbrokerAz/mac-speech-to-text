// MenuBarViewModelTests.swift
// macOS Local Speech-to-Text Application
//
// Unit tests for MenuBarViewModel (Ultra-minimal version)

import XCTest
@testable import SpeechToText

@MainActor
final class MenuBarViewModelTests: XCTestCase {
    // MARK: - Properties

    var sut: MenuBarViewModel!
    var notificationObserver: NSObjectProtocol?

    // MARK: - Setup & Teardown

    override func setUp() async throws {
        try await super.setUp()
        sut = MenuBarViewModel()

        // Wait for init task to complete (permission check)
        try await Task.sleep(nanoseconds: 100_000_000)
    }

    override func tearDown() async throws {
        if let observer = notificationObserver {
            NotificationCenter.default.removeObserver(observer)
            notificationObserver = nil
        }
        sut = nil
        try await super.tearDown()
    }

    // MARK: - Initialization Tests

    func test_initialization_setsDefaultState() {
        let viewModel = MenuBarViewModel()

        // Then - check initial state
        XCTAssertFalse(viewModel.isRecording)
        // hasPermission depends on system state, so we don't assert on it
    }

    // MARK: - Status Icon Tests

    func test_statusIcon_returnsMicSlashWhenNoPermission() {
        // Given
        sut.hasPermission = false

        // Then
        XCTAssertEqual(sut.statusIcon, "mic.slash")
    }

    func test_statusIcon_returnsMicFillWhenHasPermission() {
        // Given
        sut.hasPermission = true
        sut.isRecording = false

        // Then
        XCTAssertEqual(sut.statusIcon, "mic.fill")
    }

    func test_statusIcon_returnsMicFillWhenRecording() {
        // Given
        sut.hasPermission = true
        sut.isRecording = true

        // Then
        XCTAssertEqual(sut.statusIcon, "mic.fill")
    }

    // MARK: - Icon Color Tests

    func test_iconColor_returnsGrayWhenNoPermission() {
        // Given
        sut.hasPermission = false

        // Then
        XCTAssertEqual(sut.iconColor, .gray)
    }

    func test_iconColor_returnsRedWhenRecording() {
        // Given
        sut.hasPermission = true
        sut.isRecording = true

        // Then
        XCTAssertEqual(sut.iconColor, .red)
    }

    // MARK: - openMainView Tests

    func test_openMainView_postsShowMainViewNotification() {
        // Given
        var notificationReceived = false
        notificationObserver = NotificationCenter.default.addObserver(
            forName: .showMainView,
            object: nil,
            queue: .main
        ) { _ in
            notificationReceived = true
        }

        // When
        sut.openMainView()

        // Then
        XCTAssertTrue(notificationReceived)
    }

    // MARK: - #92 Clinical Notes gate

    /// Builds a VM with isolated SettingsService + ClinikoCredentialStore so
    /// each test starts from a clean gate.
    private func makeIsolatedViewModel() -> MenuBarViewModel {
        let suiteName = "MenuBarViewModelTests-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            preconditionFailure("UserDefaults(suiteName:) returned nil")
        }
        defaults.removePersistentDomain(forName: suiteName)
        let settingsService = SettingsService(userDefaults: defaults)
        let credentialStore = ClinikoCredentialStore(
            secureStore: InMemorySecureStore(),
            userDefaults: defaults
        )
        return MenuBarViewModel(
            permissionService: PermissionService(),
            settingsService: settingsService,
            credentialStore: credentialStore
        )
    }

    func test_canStartClinicalNote_falseWhenModeOffAndCredsAbsent() async {
        let vm = makeIsolatedViewModel()
        await vm.refreshState()
        XCTAssertFalse(vm.clinicalNotesModeEnabled)
        XCTAssertFalse(vm.hasStoredCredentials)
        XCTAssertFalse(vm.canStartClinicalNote)
    }

    func test_canStartClinicalNote_falseWhenCredsPresentButModeOff() async throws {
        let suiteName = "MenuBarViewModelTests-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            preconditionFailure("UserDefaults(suiteName:) returned nil")
        }
        defaults.removePersistentDomain(forName: suiteName)
        let settingsService = SettingsService(userDefaults: defaults)
        let credentialStore = ClinikoCredentialStore(
            secureStore: InMemorySecureStore(),
            userDefaults: defaults
        )
        try await credentialStore.saveCredentials(apiKey: "MS-test-au1", shard: .au1)

        let vm = MenuBarViewModel(
            permissionService: PermissionService(),
            settingsService: settingsService,
            credentialStore: credentialStore
        )
        await vm.refreshState()

        XCTAssertTrue(vm.hasStoredCredentials)
        XCTAssertFalse(vm.clinicalNotesModeEnabled)
        XCTAssertFalse(vm.canStartClinicalNote, "Mode-off should hide the menu item even with creds")
    }

    func test_canStartClinicalNote_trueWhenModeOnAndCredsPresent() async throws {
        let suiteName = "MenuBarViewModelTests-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            preconditionFailure("UserDefaults(suiteName:) returned nil")
        }
        defaults.removePersistentDomain(forName: suiteName)
        let settingsService = SettingsService(userDefaults: defaults)
        let credentialStore = ClinikoCredentialStore(
            secureStore: InMemorySecureStore(),
            userDefaults: defaults
        )
        try await credentialStore.saveCredentials(apiKey: "MS-test-au1", shard: .au1)
        var settings = settingsService.load()
        settings.general.applyClinicalNotesMode(true)
        try settingsService.save(settings)

        let vm = MenuBarViewModel(
            permissionService: PermissionService(),
            settingsService: settingsService,
            credentialStore: credentialStore
        )
        await vm.refreshState()

        XCTAssertTrue(vm.clinicalNotesModeEnabled)
        XCTAssertTrue(vm.hasStoredCredentials)
        XCTAssertTrue(vm.canStartClinicalNote)
    }

    func test_startClinicalNote_postsShowRecordingModalNotification() {
        // Given
        var notificationReceived = false
        notificationObserver = NotificationCenter.default.addObserver(
            forName: .showRecordingModal,
            object: nil,
            queue: .main
        ) { _ in
            notificationReceived = true
        }

        // When
        sut.startClinicalNote()

        // Then
        XCTAssertTrue(notificationReceived)
    }
}
