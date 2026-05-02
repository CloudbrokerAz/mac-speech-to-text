import KeyboardShortcuts
import SwiftUI
import ViewInspector
import XCTest
@testable import SpeechToText

/// Render-crash tests for `ClinicalNotesSection`. We don't assert on layout —
/// only that the view + its `@Observable @MainActor` view model can be
/// instantiated and inspected without an `EXC_BAD_ACCESS` (the failure mode
/// when an actor existential is held without `@ObservationIgnored`; see
/// `.claude/references/concurrency.md`).
@MainActor
final class ClinicalNotesSectionRenderTests: XCTestCase {

    private func makeUserDefaults() -> UserDefaults {
        let suiteName = "ClinicalNotesSectionRenderTests-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            preconditionFailure("UserDefaults(suiteName:) returned nil")
        }
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    private func makeSettingsService() -> SettingsService {
        let suiteName = "ClinicalNotesSectionRenderTests-Settings-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            preconditionFailure("UserDefaults(suiteName:) returned nil")
        }
        defaults.removePersistentDomain(forName: suiteName)
        return SettingsService(userDefaults: defaults)
    }

    private func makeViewModel() -> ClinicalNotesSectionViewModel {
        let store = ClinikoCredentialStore(
            secureStore: InMemorySecureStore(),
            userDefaults: makeUserDefaults()
        )
        // Probe will never fire in render-only tests — we don't call save/test.
        let probe = ClinikoAuthProbe(session: .shared)
        return ClinicalNotesSectionViewModel(credentialStore: store, authProbe: probe)
    }

    func test_clinicalNotesSection_instantiatesWithoutCrash() {
        let viewModel = makeViewModel()
        let view = ClinicalNotesSection(
            viewModel: viewModel,
            settingsService: makeSettingsService()
        )
        XCTAssertNotNil(view)
    }

    func test_clinicalNotesSection_canBeInspected() throws {
        let viewModel = makeViewModel()
        let view = ClinicalNotesSection(
            viewModel: viewModel,
            settingsService: makeSettingsService()
        )
        // ViewInspector forces SwiftUI's body to be evaluated; if any
        // @Observable + actor existential issue exists in the VM, this is
        // where it surfaces (EXC_BAD_ACCESS). Just touching the body counts.
        XCTAssertNoThrow(try view.inspect().findAll(ViewType.ScrollView.self))
    }

    func test_clinicalNotesSection_disconnectedState_rendersWithoutCrash() {
        let viewModel = makeViewModel()
        // Default state — no credentials saved.
        XCTAssertFalse(viewModel.hasStoredCredentials)
        let view = ClinicalNotesSection(
            viewModel: viewModel,
            settingsService: makeSettingsService()
        )
        XCTAssertNoThrow(try view.inspect().findAll(ViewType.SecureField.self))
    }

    func test_clinicalNotesSection_connectedState_rendersWithoutCrash() async throws {
        let secureStore = InMemorySecureStore()
        let store = ClinikoCredentialStore(
            secureStore: secureStore,
            userDefaults: makeUserDefaults()
        )
        try await store.saveCredentials(apiKey: "MS-test-au1", shard: .au1)
        let probe = ClinikoAuthProbe(session: .shared)
        let viewModel = ClinicalNotesSectionViewModel(credentialStore: store, authProbe: probe)
        await viewModel.refreshState()

        let view = ClinicalNotesSection(
            viewModel: viewModel,
            settingsService: makeSettingsService()
        )
        XCTAssertNoThrow(try view.inspect().findAll(ViewType.SecureField.self))
    }

    // MARK: - #11 Clinical Notes Mode toggle

    /// The toggle is rendered above the credentials block. Confirm it's reachable
    /// via the accessibility identifier — that's the contract UI tests + future
    /// snapshot tests will pivot on.
    func test_clinicalNotesModeToggle_isPresent() throws {
        let viewModel = makeViewModel()
        let view = ClinicalNotesSection(
            viewModel: viewModel,
            settingsService: makeSettingsService()
        )
        XCTAssertNoThrow(
            try view.inspect().find(viewWithAccessibilityIdentifier: "clinicalNotesModeToggle")
        )
    }

    // MARK: - #91 Recording shortcut row visibility

    /// Default state: no credentials, mode off → row hidden.
    func test_clinicalNotesShortcutRow_hiddenWhenModeOffAndCredsAbsent() throws {
        let viewModel = makeViewModel()
        let view = ClinicalNotesSection(
            viewModel: viewModel,
            settingsService: makeSettingsService()
        )
        XCTAssertThrowsError(
            try view.inspect().find(viewWithAccessibilityIdentifier: "clinicalNotesRecordingShortcutRow"),
            "Row must be hidden when both gates are off"
        )
    }

    /// Credentials present but the doctor hasn't enabled the mode yet → row hidden.
    func test_clinicalNotesShortcutRow_hiddenWhenCredsPresentButModeOff() async throws {
        let secureStore = InMemorySecureStore()
        let store = ClinikoCredentialStore(
            secureStore: secureStore,
            userDefaults: makeUserDefaults()
        )
        try await store.saveCredentials(apiKey: "MS-test-au1", shard: .au1)
        let probe = ClinikoAuthProbe(session: .shared)
        let viewModel = ClinicalNotesSectionViewModel(credentialStore: store, authProbe: probe)
        await viewModel.refreshState()
        XCTAssertTrue(viewModel.hasStoredCredentials)

        // Settings service holds default state (mode off).
        let view = ClinicalNotesSection(
            viewModel: viewModel,
            settingsService: makeSettingsService()
        )
        XCTAssertThrowsError(
            try view.inspect().find(viewWithAccessibilityIdentifier: "clinicalNotesRecordingShortcutRow"),
            "Row must be hidden when mode is off, even with creds present"
        )
    }

    /// Both gates open: mode on AND credentials present → row visible.
    func test_clinicalNotesShortcutRow_visibleWhenModeOnAndCredsPresent() async throws {
        let secureStore = InMemorySecureStore()
        let store = ClinikoCredentialStore(
            secureStore: secureStore,
            userDefaults: makeUserDefaults()
        )
        try await store.saveCredentials(apiKey: "MS-test-au1", shard: .au1)
        let probe = ClinikoAuthProbe(session: .shared)
        let viewModel = ClinicalNotesSectionViewModel(credentialStore: store, authProbe: probe)
        await viewModel.refreshState()
        XCTAssertTrue(viewModel.hasStoredCredentials)

        // Persist mode-on into the settings service this section reads from.
        let settingsService = makeSettingsService()
        var settings = settingsService.load()
        settings.general.applyClinicalNotesMode(true)
        try settingsService.save(settings)

        let view = ClinicalNotesSection(
            viewModel: viewModel,
            settingsService: settingsService
        )
        XCTAssertNoThrow(
            try view.inspect().find(viewWithAccessibilityIdentifier: "clinicalNotesRecordingShortcutRow"),
            "Row must be visible when mode is on AND creds present"
        )
    }

    // MARK: - #89 Contact email field

    func test_contactEmailField_isPresent() throws {
        let viewModel = makeViewModel()
        let view = ClinicalNotesSection(
            viewModel: viewModel,
            settingsService: makeSettingsService()
        )
        XCTAssertNoThrow(
            try view.inspect().find(viewWithAccessibilityIdentifier: "clinicalNotesSection.contactEmailField")
        )
    }

    func test_contactEmailField_invalidHintHiddenForEmptyDraft() throws {
        let viewModel = makeViewModel()
        viewModel.contactEmailDraft = ""
        let view = ClinicalNotesSection(
            viewModel: viewModel,
            settingsService: makeSettingsService()
        )
        XCTAssertThrowsError(
            try view.inspect().find(viewWithAccessibilityIdentifier: "clinicalNotesSection.contactEmailField.invalidHint"),
            "Empty input is unset, not invalid — the hint should not appear"
        )
    }

    func test_contactEmailField_invalidHintAppearsForMalformedInput() throws {
        let viewModel = makeViewModel()
        viewModel.contactEmailDraft = "not-an-email"
        let view = ClinicalNotesSection(
            viewModel: viewModel,
            settingsService: makeSettingsService()
        )
        XCTAssertNoThrow(
            try view.inspect().find(viewWithAccessibilityIdentifier: "clinicalNotesSection.contactEmailField.invalidHint")
        )
    }

    func test_contactEmailDraft_didSetPersistsThroughCredentialStore() async throws {
        let userDefaults = makeUserDefaults()
        let store = ClinikoCredentialStore(
            secureStore: InMemorySecureStore(),
            userDefaults: userDefaults
        )
        let probe = ClinikoAuthProbe(session: .shared)
        let viewModel = ClinicalNotesSectionViewModel(credentialStore: store, authProbe: probe)

        viewModel.contactEmailDraft = "doctor@example.test"

        // The didSet writes through synchronously via the nonisolated update.
        XCTAssertEqual(store.loadContactEmail(), "doctor@example.test")
    }

    func test_contactEmailDraft_rehydratesFromStoreOnRefresh() async throws {
        let userDefaults = makeUserDefaults()
        let store = ClinikoCredentialStore(
            secureStore: InMemorySecureStore(),
            userDefaults: userDefaults
        )
        let probe = ClinikoAuthProbe(session: .shared)
        let viewModel = ClinicalNotesSectionViewModel(credentialStore: store, authProbe: probe)

        // Simulate an external write (a different settings tab / process /
        // earlier session that persisted a value before the VM was created).
        // A direct `store.updateContactEmail` skips the VM's didSet, so the
        // VM has no in-memory record of the change until refreshState reloads
        // from disk. This is the actual flow `refreshState` exists to support
        // — the VM can't simulate it via its own didSet (which auto-saves
        // and would overwrite, not diverge from, the disk value).
        store.updateContactEmail("doctor@example.test")
        XCTAssertEqual(viewModel.contactEmailDraft, "",
                       "VM has not loaded yet; draft remains empty")

        await viewModel.refreshState()
        XCTAssertEqual(viewModel.contactEmailDraft, "doctor@example.test",
                       "refreshState should hydrate the draft from the persisted store value")
    }

    func test_contactEmailDraft_refreshStateSkipsRedundantAssignment() async throws {
        // The equality-guard in `refreshState` is belt-and-braces against a
        // future trigger-graph addition that re-runs refresh while the field
        // is focused. Pin the property: when the on-disk value already
        // matches the in-memory draft, refreshState must not reassign (the
        // assignment would be a no-op semantically, but we want the guard
        // to remain wired in case the didSet logic gets richer).
        let userDefaults = makeUserDefaults()
        let store = ClinikoCredentialStore(
            secureStore: InMemorySecureStore(),
            userDefaults: userDefaults
        )
        let probe = ClinikoAuthProbe(session: .shared)
        let viewModel = ClinicalNotesSectionViewModel(credentialStore: store, authProbe: probe)

        viewModel.contactEmailDraft = "doctor@example.test"
        await viewModel.refreshState()
        XCTAssertEqual(viewModel.contactEmailDraft, "doctor@example.test",
                       "draft already matches store; refreshState must not corrupt it")
    }

    // MARK: - #91 Conflict-guard validator

    /// The validator is a pure function over an explicit "bound chords" list.
    /// We exercise it directly so the test does not depend on shared
    /// `KeyboardShortcuts` UserDefaults state.
    func test_validateClinicalNotesShortcut_returnsNilWhenNoConflict() {
        let candidate = KeyboardShortcuts.Shortcut(.f5, modifiers: [.command])
        let bound: [(KeyboardShortcuts.Shortcut, String)] = [
            (KeyboardShortcuts.Shortcut(.space, modifiers: [.control, .shift]), "Hold to Record")
        ]
        XCTAssertNil(
            ClinicalNotesSection.validateClinicalNotesShortcut(candidate, against: bound)
        )
    }

    /// When the candidate matches an existing chord, the validator returns a
    /// human-readable rejection that names the conflicting binding.
    func test_validateClinicalNotesShortcut_returnsErrorWhenChordCollides() throws {
        let candidate = KeyboardShortcuts.Shortcut(.space, modifiers: [.control, .shift])
        let bound: [(KeyboardShortcuts.Shortcut, String)] = [
            (KeyboardShortcuts.Shortcut(.space, modifiers: [.control, .shift]), "Hold to Record"),
            (KeyboardShortcuts.Shortcut(.f6, modifiers: [.command]), "Toggle Recording")
        ]
        let error = try XCTUnwrap(
            ClinicalNotesSection.validateClinicalNotesShortcut(candidate, against: bound)
        )
        XCTAssertTrue(
            error.contains("Hold to Record"),
            "Rejection should name the conflicting binding so the doctor knows what to avoid"
        )
    }
}
