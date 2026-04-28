import AVFoundation
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

/// PHI invariant tests for `RecordingViewModel.clinicalMode` (#98).
///
/// In a clinical session the just-finished transcript is PHI by definition.
/// Before #98, the modal-stop pipeline (`stopRecording → transcribe →
/// insertText`) and the hold-to-record pipeline (`onHotkeyReleased →
/// transcribeWithFallback → insertTextWithFallback`) both handed the
/// transcript to `TextInsertionService`, which Cmd+V'd into the focused
/// app and (when Accessibility was denied) wrote it to
/// `NSPasteboard.general`. Either path is a PHI escape — the only
/// legitimate destinations are the in-memory `transcribedText` and the
/// doctor-initiated Cliniko POST that follows Generate Notes.
///
/// These tests pin the gate at the view-model boundary so a regression
/// in the modal (or any future trigger surface) can't reintroduce the
/// leak: regardless of which pipeline runs, when `clinicalMode = true`
/// the `TextInsertionService` mock must observe **zero** calls.
@MainActor
@Suite("RecordingViewModel: clinicalMode PHI gate (#98)", .tags(.fast))
struct RecordingViewModelClinicalModePHIGateTests {

    private func makeSettingsService() -> SettingsService {
        let suiteName = "RecordingViewModelClinicalModePHIGateTests-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            preconditionFailure("UserDefaults(suiteName:) returned nil")
        }
        defaults.removePersistentDomain(forName: suiteName)
        return SettingsService(userDefaults: defaults)
    }

    private struct Pipeline {
        let viewModel: RecordingViewModel
        let mockAudio: MockAudioCaptureServiceForRecording
        let mockFluidAudio: MockFluidAudioServiceForRecording
        let mockInsertion: MockTextInsertionServiceForRecording
    }

    private func makePipeline(
        clinicalMode: Bool,
        transcript: String = "Patient reports lower back pain after gardening on Saturday."
    ) async -> Pipeline {
        let mockAudio = MockAudioCaptureServiceForRecording()
        mockAudio.mockSamples = [100, 200, 300]
        let mockFluidAudio = MockFluidAudioServiceForRecording()
        await mockFluidAudio.setMockResult(
            TranscriptionResult(text: transcript, confidence: 0.92, durationMs: 1500)
        )
        let mockInsertion = MockTextInsertionServiceForRecording()
        let viewModel = RecordingViewModel(
            audioService: mockAudio,
            fluidAudioService: mockFluidAudio,
            textInsertionService: mockInsertion,
            settingsService: makeSettingsService(),
            clinicalMode: clinicalMode
        )
        return Pipeline(
            viewModel: viewModel,
            mockAudio: mockAudio,
            mockFluidAudio: mockFluidAudio,
            mockInsertion: mockInsertion
        )
    }

    @Test("clinicalMode defaults to false")
    func clinicalModeDefaultsFalse() async {
        let pipeline = await makePipeline(clinicalMode: false)
        #expect(pipeline.viewModel.clinicalMode == false)
    }

    @Test("Modal-stop path: clinicalMode = true never calls insertText")
    func modalStopGatesInsertText() async throws {
        let pipeline = await makePipeline(clinicalMode: true)

        try await pipeline.viewModel.startRecording()
        try await pipeline.viewModel.stopRecording()

        // Transcript landed on the view model — Generate Notes will read it.
        #expect(pipeline.viewModel.transcribedText == "Patient reports lower back pain after gardening on Saturday.")
        #expect(pipeline.viewModel.currentSession?.state == .completed)

        // PHI invariant — TextInsertionService must NOT have been called on
        // either entry point. If this regresses, a clinical transcript is
        // pasted into the focused app and/or NSPasteboard.general.
        #expect(pipeline.mockInsertion.insertTextCalled == false)
        #expect(pipeline.mockInsertion.insertTextWithFallbackCalled == false)
        #expect(pipeline.mockInsertion.lastInsertedText == nil)
        #expect(pipeline.viewModel.lastTranscriptionCopiedToClipboard == false)
    }

    @Test("Hold-to-record path: clinicalMode = true never calls insertTextWithFallback")
    func holdToRecordGatesInsertTextWithFallback() async throws {
        let pipeline = await makePipeline(clinicalMode: true)

        try await pipeline.viewModel.startRecording()
        try await pipeline.viewModel.onHotkeyReleased()

        #expect(pipeline.viewModel.transcribedText == "Patient reports lower back pain after gardening on Saturday.")
        #expect(pipeline.viewModel.currentSession?.state == .completed)

        // PHI invariant — defence-in-depth: the hold-to-record chord is a
        // non-clinical surface today, but the gate is local to the VM so a
        // future clinical surface that routes through this path is also
        // covered.
        #expect(pipeline.mockInsertion.insertTextWithFallbackCalled == false)
        #expect(pipeline.mockInsertion.insertTextCalled == false)
        #expect(pipeline.mockInsertion.lastInsertedText == nil)
        #expect(pipeline.viewModel.showAccessibilityPrompt == false)
    }

    @Test("General-dictation regression check: clinicalMode = false still pastes via modal-stop")
    func generalDictationStillCallsInsertText() async throws {
        let pipeline = await makePipeline(clinicalMode: false)

        try await pipeline.viewModel.startRecording()
        try await pipeline.viewModel.stopRecording()

        #expect(pipeline.mockInsertion.insertTextCalled == true)
        #expect(pipeline.mockInsertion.lastInsertedText == "Patient reports lower back pain after gardening on Saturday.")
    }

    @Test("General-dictation regression check: clinicalMode = false still pastes via hold-to-record")
    func generalDictationStillCallsInsertTextWithFallback() async throws {
        let pipeline = await makePipeline(clinicalMode: false)

        try await pipeline.viewModel.startRecording()
        try await pipeline.viewModel.onHotkeyReleased()

        #expect(pipeline.mockInsertion.insertTextWithFallbackCalled == true)
        #expect(pipeline.mockInsertion.lastInsertedText == "Patient reports lower back pain after gardening on Saturday.")
    }

    @Test("clinicalMode + transcribe failure: errorMessage stays inert (no SDK leakage)")
    func clinicalErrorMessageIsInert() async throws {
        let leakyError = NSError(
            domain: "FluidAudioMock",
            code: 42,
            userInfo: [NSLocalizedDescriptionKey: "decode dump: <PATIENT_TRANSCRIPT_FRAGMENT>"]
        )
        let mockAudio = MockAudioCaptureServiceForRecording()
        mockAudio.mockSamples = [100, 200, 300]
        let mockFluidAudio = ThrowingFluidAudioMock(error: leakyError)
        let mockInsertion = MockTextInsertionServiceForRecording()
        let viewModel = RecordingViewModel(
            audioService: mockAudio,
            fluidAudioService: mockFluidAudio,
            textInsertionService: mockInsertion,
            settingsService: makeSettingsService(),
            clinicalMode: true
        )

        try await viewModel.startRecording()

        do {
            try await viewModel.stopRecording()
            Issue.record("Expected stopRecording() to throw when transcribe fails")
        } catch {
            // expected
        }

        let message = viewModel.errorMessage ?? ""
        // The PHI invariant: clinical-mode `errorMessage` must not contain
        // the FluidAudio error's `localizedDescription`. We use a sentinel
        // string ("decode dump: <PATIENT_TRANSCRIPT_FRAGMENT>") that mirrors
        // the worst-case shape of an SDK error that smuggles patient-derived
        // data into its description.
        #expect(!message.contains("decode dump"), "clinicalMode error message must not interpolate SDK error.localizedDescription")
        #expect(!message.contains("PATIENT_TRANSCRIPT_FRAGMENT"), "clinicalMode error message must not interpolate SDK error.localizedDescription")
        #expect(message == "Transcription failed: Please try recording again.")
        // Defence-in-depth: the session's persisted errorMessage (which feeds
        // StatisticsService.extractErrorType) must also not contain the SDK
        // string. The exact value differs based on whether the inner
        // transcribe-catch or outer stopRecording-catch wins the last write
        // (currently the outer wins and prefixes "Transcription failed: "),
        // but both writes funnel through the sanitised inert payload.
        let sessionMessage = viewModel.currentSession?.errorMessage ?? ""
        #expect(!sessionMessage.contains("decode dump"), "session.errorMessage must not contain SDK leakage")
        #expect(!sessionMessage.contains("PATIENT_TRANSCRIPT_FRAGMENT"), "session.errorMessage must not contain SDK leakage")
        #expect(sessionMessage.contains("Please try recording again."), "session.errorMessage must surface the inert clinical message")
    }

    @Test("Default mode: error message DOES include localizedDescription (regression check)")
    func defaultModeErrorMessageIncludesLocalizedDescription() async throws {
        let mockError = NSError(
            domain: "FluidAudioMock",
            code: 42,
            userInfo: [NSLocalizedDescriptionKey: "Network timeout"]
        )
        let mockAudio = MockAudioCaptureServiceForRecording()
        mockAudio.mockSamples = [100, 200, 300]
        let mockFluidAudio = ThrowingFluidAudioMock(error: mockError)
        let viewModel = RecordingViewModel(
            audioService: mockAudio,
            fluidAudioService: mockFluidAudio,
            textInsertionService: MockTextInsertionServiceForRecording(),
            settingsService: makeSettingsService(),
            clinicalMode: false
        )

        try await viewModel.startRecording()

        do {
            try await viewModel.stopRecording()
            Issue.record("Expected stopRecording() to throw when transcribe fails")
        } catch {
            // expected
        }

        // General dictation surfaces SDK error description so dictation
        // failures stay actionable. No PHI in this path.
        let message = viewModel.errorMessage ?? ""
        #expect(message.contains("Network timeout"))
    }
}

/// Inline mock that lets a Swift-Testing test drive `transcribe()`'s catch
/// branch deterministically. The default mock in `RecordingViewModelTests`
/// always succeeds; this lets us throw a known error and assert the
/// clinical-mode sanitisation kicks in. Confined to the test target.
actor ThrowingFluidAudioMock: FluidAudioServiceProtocol {
    private let error: Error
    private var initialized = false

    init(error: Error) {
        self.error = error
    }

    func initialize(language: String) async throws {
        initialized = true
    }

    func transcribe(samples: [Int16], sampleRate: Double) async throws -> TranscriptionResult {
        throw error
    }

    func switchLanguage(to language: String) async throws {
        // no-op
    }

    func getCurrentLanguage() -> String { "en" }

    func checkInitialized() -> Bool { initialized }

    func shutdown() { initialized = false }
}
