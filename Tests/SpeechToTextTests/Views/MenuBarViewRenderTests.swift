import SwiftUI
import XCTest
@testable import SpeechToText

/// Render-crash tests for `MenuBarView` (#92). The production menu bar is
/// presented via `MenuBarExtra(.window)`; these tests assert the view + its
/// `@Observable @MainActor` view model can be constructed without crashing
/// under each Clinical-Notes gate state. Body traversal via ViewInspector is
/// intentionally avoided: `MenuBarView` reads `AppState` via
/// `@Environment(AppState.self)`, and ViewInspector's `find()` triggers
/// SwiftUI body evaluation outside a real host hierarchy where the
/// `@Observable` environment lookup traps. The visibility gate is exercised
/// at the view-model layer in `MenuBarViewModelTests` (`canStartClinicalNote`
/// under each combination of mode toggle + credential presence).
@MainActor
final class MenuBarViewRenderTests: XCTestCase {

    private func makeUserDefaults() -> UserDefaults {
        let suiteName = "MenuBarViewRenderTests-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            preconditionFailure("UserDefaults(suiteName:) returned nil")
        }
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    private func makeViewModel(
        modeEnabled: Bool,
        seedCredentials: Bool
    ) async throws -> MenuBarViewModel {
        let defaults = makeUserDefaults()
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
        let vm = MenuBarViewModel(
            permissionService: PermissionService(),
            settingsService: settingsService,
            credentialStore: credentialStore
        )
        await vm.refreshState()
        return vm
    }

    func test_menuBarView_instantiatesWithoutCrash_modeOffNoCreds() async throws {
        let vm = try await makeViewModel(modeEnabled: false, seedCredentials: false)
        // Construction itself is the assertion: `MenuBarView.init` runs the
        // SwiftUI `@State` wrapping for the injected VM. If the VM's
        // `@Observable` macro + actor existential layout is broken, this
        // traps before we ever read the view back.
        _ = MenuBarView(viewModel: vm)
        XCTAssertFalse(vm.canStartClinicalNote, "Gate must be closed in default state")
    }

    func test_menuBarView_instantiatesWithoutCrash_credsOnlyModeOff() async throws {
        let vm = try await makeViewModel(modeEnabled: false, seedCredentials: true)
        // Construction itself is the assertion: `MenuBarView.init` runs the
        // SwiftUI `@State` wrapping for the injected VM. If the VM's
        // `@Observable` macro + actor existential layout is broken, this
        // traps before we ever read the view back.
        _ = MenuBarView(viewModel: vm)
        XCTAssertFalse(vm.canStartClinicalNote, "Mode-off must close the gate even with creds")
    }

    func test_menuBarView_instantiatesWithoutCrash_modeOnNoCreds() async throws {
        let vm = try await makeViewModel(modeEnabled: true, seedCredentials: false)
        // Construction itself is the assertion: `MenuBarView.init` runs the
        // SwiftUI `@State` wrapping for the injected VM. If the VM's
        // `@Observable` macro + actor existential layout is broken, this
        // traps before we ever read the view back.
        _ = MenuBarView(viewModel: vm)
        XCTAssertFalse(vm.canStartClinicalNote, "Creds-absent must close the gate even with mode on")
    }

    func test_menuBarView_instantiatesWithoutCrash_bothGatesOpen() async throws {
        let vm = try await makeViewModel(modeEnabled: true, seedCredentials: true)
        // Construction itself is the assertion: `MenuBarView.init` runs the
        // SwiftUI `@State` wrapping for the injected VM. If the VM's
        // `@Observable` macro + actor existential layout is broken, this
        // traps before we ever read the view back.
        _ = MenuBarView(viewModel: vm)
        XCTAssertTrue(vm.canStartClinicalNote, "Gate must be open with mode on + creds present")
    }
}
