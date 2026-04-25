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
