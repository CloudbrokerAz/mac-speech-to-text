import Foundation
import Testing
@testable import SpeechToText

/// `RecordingViewModel.isClinicalNotesEnabled` is the read seam the recording
/// modal uses to decide between the existing auto-dismiss success indicator
/// and the new "Generate Notes" button row added in #11. It must reflect the
/// most-recently saved value of `settings.general.clinicalNotesModeEnabled`.
///
/// Read-on-demand (not cached at init) is the contract: the doctor may flip
/// the toggle in the Main window between starting a recording and finishing
/// it; the modal evaluates this only after transcription completes, so a
/// fresh read is correct. The test pins that contract.
@MainActor
@Suite("RecordingViewModel: isClinicalNotesEnabled (#11)", .tags(.fast))
struct RecordingViewModelClinicalNotesTests {

    private func makeSettingsService() -> SettingsService {
        let suiteName = "RecordingViewModelClinicalNotesTests-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            preconditionFailure("UserDefaults(suiteName:) returned nil")
        }
        defaults.removePersistentDomain(forName: suiteName)
        return SettingsService(userDefaults: defaults)
    }

    @Test("Defaults to false on a fresh settings store")
    func defaultsFalse() {
        let settingsService = makeSettingsService()
        let viewModel = RecordingViewModel(settingsService: settingsService)
        #expect(viewModel.isClinicalNotesEnabled == false)
    }

    @Test("Reflects a saved-true value")
    func reflectsSavedTrue() throws {
        let settingsService = makeSettingsService()
        var settings = settingsService.load()
        settings.general.clinicalNotesModeEnabled = true
        try settingsService.save(settings)

        let viewModel = RecordingViewModel(settingsService: settingsService)
        #expect(viewModel.isClinicalNotesEnabled == true)
    }

    @Test("Reads on demand — a save after init is honoured")
    func readsOnDemand() throws {
        let settingsService = makeSettingsService()
        let viewModel = RecordingViewModel(settingsService: settingsService)
        #expect(viewModel.isClinicalNotesEnabled == false)

        var settings = settingsService.load()
        settings.general.clinicalNotesModeEnabled = true
        try settingsService.save(settings)

        // Same view model — must see the new value because the property is
        // a computed read of `settingsService.load()`, not a stored copy.
        #expect(viewModel.isClinicalNotesEnabled == true)
    }
}

/// Coverage for the Safety Disclaimer (#12) state and behaviour on
/// `RecordingViewModel`. The recording modal gates "Generate Notes" on
/// `isSafetyDisclaimerAcknowledged`; tapping the disclaimer's "I
/// understand, continue" button must persist the ack so subsequent taps
/// proceed straight to the post + dismiss path.
@MainActor
@Suite("RecordingViewModel: Safety Disclaimer (#12)", .tags(.fast))
struct RecordingViewModelSafetyDisclaimerTests {

    private func makeSettingsService() -> SettingsService {
        let suiteName = "RecordingViewModelSafetyDisclaimerTests-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            preconditionFailure("UserDefaults(suiteName:) returned nil")
        }
        defaults.removePersistentDomain(forName: suiteName)
        return SettingsService(userDefaults: defaults)
    }

    @Test("isSafetyDisclaimerAcknowledged defaults to false on a fresh settings store")
    func ackDefaultsFalse() {
        let settingsService = makeSettingsService()
        let viewModel = RecordingViewModel(settingsService: settingsService)
        #expect(viewModel.isSafetyDisclaimerAcknowledged == false)
    }

    @Test("isSafetyDisclaimerAcknowledged reflects a saved-true value")
    func ackReflectsSavedTrue() throws {
        let settingsService = makeSettingsService()
        var settings = settingsService.load()
        settings.general.clinicalNotesDisclaimerAcknowledged = true
        try settingsService.save(settings)

        let viewModel = RecordingViewModel(settingsService: settingsService)
        #expect(viewModel.isSafetyDisclaimerAcknowledged == true)
    }

    @Test("showSafetyDisclaimer defaults to false")
    func showSafetyDisclaimerDefaultsFalse() {
        let settingsService = makeSettingsService()
        let viewModel = RecordingViewModel(settingsService: settingsService)
        #expect(viewModel.showSafetyDisclaimer == false)
    }

    @Test("presentSafetyDisclaimer flips showSafetyDisclaimer true without persisting ack")
    func presentDoesNotPersist() {
        let settingsService = makeSettingsService()
        let viewModel = RecordingViewModel(settingsService: settingsService)

        viewModel.presentSafetyDisclaimer()

        #expect(viewModel.showSafetyDisclaimer == true)
        // Critical: presenting must not flip the ack — the ack only persists
        // on the user's "I understand, continue" tap, never on mere
        // presentation.
        #expect(viewModel.isSafetyDisclaimerAcknowledged == false)
        #expect(settingsService.load().general.clinicalNotesDisclaimerAcknowledged == false)
    }

    @Test("presentSafetyDisclaimer is idempotent — a second call while showing is a no-op")
    func presentIsIdempotent() {
        let settingsService = makeSettingsService()
        let viewModel = RecordingViewModel(settingsService: settingsService)

        viewModel.presentSafetyDisclaimer()
        viewModel.presentSafetyDisclaimer()

        #expect(viewModel.showSafetyDisclaimer == true)
        #expect(viewModel.isSafetyDisclaimerAcknowledged == false)
    }

    @Test("acknowledgeSafetyDisclaimer persists the ack, clears the overlay flag, and returns true on success")
    func acknowledgePersistsAndClears() {
        let settingsService = makeSettingsService()
        let viewModel = RecordingViewModel(settingsService: settingsService)
        viewModel.presentSafetyDisclaimer()
        #expect(viewModel.showSafetyDisclaimer == true)

        let success = viewModel.acknowledgeSafetyDisclaimer()

        #expect(success == true)
        #expect(viewModel.showSafetyDisclaimer == false)
        #expect(viewModel.isSafetyDisclaimerAcknowledged == true)
        #expect(settingsService.load().general.clinicalNotesDisclaimerAcknowledged == true)
        // Happy path must not surface an error banner.
        #expect(viewModel.errorMessage == nil)
    }

    @Test("acknowledge → toggle off → toggle on resets the ack via applyClinicalNotesMode")
    func toggleOffOnResetsAck() throws {
        let settingsService = makeSettingsService()
        let viewModel = RecordingViewModel(settingsService: settingsService)
        viewModel.acknowledgeSafetyDisclaimer()
        #expect(viewModel.isSafetyDisclaimerAcknowledged == true)

        // Simulate the toggle binding's off→on cycle the way
        // `ClinicalNotesSection.clinicalNotesModeBinding` does it.
        var settings = settingsService.load()
        settings.general.applyClinicalNotesMode(false)
        try settingsService.save(settings)
        // ack is preserved on on→off
        #expect(viewModel.isSafetyDisclaimerAcknowledged == true)

        settings = settingsService.load()
        settings.general.applyClinicalNotesMode(true)
        try settingsService.save(settings)
        // off→on resets the ack
        #expect(viewModel.isSafetyDisclaimerAcknowledged == false)
    }
}
