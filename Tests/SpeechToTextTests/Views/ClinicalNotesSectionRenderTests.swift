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
        let view = ClinicalNotesSection(viewModel: viewModel)
        XCTAssertNotNil(view)
    }

    func test_clinicalNotesSection_canBeInspected() throws {
        let viewModel = makeViewModel()
        let view = ClinicalNotesSection(viewModel: viewModel)
        // ViewInspector forces SwiftUI's body to be evaluated; if any
        // @Observable + actor existential issue exists in the VM, this is
        // where it surfaces (EXC_BAD_ACCESS). Just touching the body counts.
        XCTAssertNoThrow(try view.inspect().findAll(ViewType.ScrollView.self))
    }

    func test_clinicalNotesSection_disconnectedState_rendersWithoutCrash() {
        let viewModel = makeViewModel()
        // Default state — no credentials saved.
        XCTAssertFalse(viewModel.hasStoredCredentials)
        let view = ClinicalNotesSection(viewModel: viewModel)
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

        let view = ClinicalNotesSection(viewModel: viewModel)
        XCTAssertNoThrow(try view.inspect().findAll(ViewType.SecureField.self))
    }
}
