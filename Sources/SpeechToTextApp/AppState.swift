import Foundation
import Observation

/// Observable app-wide state management
@Observable @MainActor
class AppState {
    var settings: UserSettings
    var statistics: AggregatedStats
    var currentSession: RecordingSession?
    var isRecording: Bool = false
    var showOnboarding: Bool = false
    var showSettings: Bool = false
    var errorMessage: String?

    // Voice trigger monitoring state (for menu bar indicator)
    var voiceTriggerState: VoiceTriggerState = .idle

    // Services
    // CRITICAL: Actor types in @Observable must be @ObservationIgnored to prevent EXC_BAD_ACCESS
    // crashes due to the observation macro scanning properties and triggering executor checks.
    // See docs/CONCURRENCY_PATTERNS.md for details.
    @ObservationIgnored let fluidAudioService: FluidAudioService
    @ObservationIgnored let permissionService: PermissionService
    @ObservationIgnored let settingsService: SettingsService
    @ObservationIgnored let statisticsService: StatisticsService

    /// In-memory clinical session lifecycle (#2). Always instantiated; cheap
    /// and idle when Clinical Notes Mode (#11) is off. The active
    /// `ClinicalSession` only ever exists between the end of a recording and
    /// either successful Cliniko export, idle timeout, or app quit. PHI lives
    /// here exclusively — see `.claude/references/phi-handling.md`.
    ///
    /// `clinicalNotesProcessor` (the `actor ClinicalNotesProcessor` from #5)
    /// injection is deferred until the concrete `MLXGemmaProvider` lands —
    /// only the `LLMProvider` protocol + `MockLLMProvider` shipped in #3, so
    /// there is no production-shaped LLM to construct a default processor
    /// against. Wiring is a one-line addition once that provider exists; the
    /// store on its own is a no-op when the toggle is off and provides no
    /// PHI surface area.
    @ObservationIgnored let sessionStore: SessionStore

    /// Static manipulations taxonomy bundled with the app (#6). Loaded
    /// once at launch and handed to `ReviewWindowController` so the
    /// review surface (#13) renders the checklist without re-parsing the
    /// JSON on every present. Empty repository on load failure — the
    /// `swift-tools-version: 5.9` `.copy(...)` in `Package.swift` makes
    /// the JSON's presence in the test bundle a build-system invariant,
    /// so any failure is a structural bug we want to surface (logged) but
    /// never want to crash production over.
    @ObservationIgnored let manipulations: ManipulationsRepository

    /// Task for loading statistics - tracked for proper lifecycle management
    @ObservationIgnored private var loadingTask: Task<Void, Never>?
    /// nonisolated copy for deinit access (deinit cannot access MainActor-isolated state)
    @ObservationIgnored private nonisolated(unsafe) var deinitLoadingTask: Task<Void, Never>?
    /// Observer for voice trigger state changes
    @ObservationIgnored private var voiceTriggerStateObserver: NSObjectProtocol?
    /// nonisolated copy for deinit access
    @ObservationIgnored private nonisolated(unsafe) var deinitVoiceTriggerStateObserver: NSObjectProtocol?
    /// Observer for `.clinicalNotesGenerateRequested` (posted by the
    /// recording modal once the doctor has acknowledged the safety
    /// disclaimer). Hops the transcript off the notification boundary
    /// into `SessionStore` and presents `ReviewWindowController`.
    @ObservationIgnored private var clinicalNotesGenerateObserver: NSObjectProtocol?
    /// nonisolated copy for deinit access
    @ObservationIgnored private nonisolated(unsafe) var deinitClinicalNotesGenerateObserver: NSObjectProtocol?

    init() {
        // Initialize services
        self.fluidAudioService = FluidAudioService()
        self.permissionService = PermissionService()
        self.settingsService = SettingsService()
        self.statisticsService = StatisticsService()
        self.sessionStore = SessionStore()
        self.manipulations = Self.loadManipulationsTaxonomy()

        // Configure ReviewWindowController once with the SessionStore +
        // taxonomy so `present()` is a no-arg call from the notification
        // observer below. Mirrors the MainWindowController.shared idiom.
        ReviewWindowController.shared.configure(
            sessionStore: self.sessionStore,
            manipulations: self.manipulations
        )

        // Load settings
        self.settings = settingsService.load()

        // Load statistics asynchronously (actor isolation)
        // Track the task for proper lifecycle management
        self.statistics = .empty
        let task = Task { [weak self] in
            guard let self else { return }
            // Check for cancellation before doing work (e.g., if AppState was deallocated quickly)
            guard !Task.isCancelled else { return }
            self.statistics = await statisticsService.getAggregatedStats()
        }
        loadingTask = task
        deinitLoadingTask = task

        // Check if onboarding needed
        self.showOnboarding = !settings.onboarding.completed

        // Observe voice trigger state changes from AppDelegate
        let observer = NotificationCenter.default.addObserver(
            forName: .voiceTriggerStateChanged,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self else { return }
            if let state = notification.userInfo?["state"] as? VoiceTriggerState {
                // Use Task to hop to MainActor for thread-safe property mutation
                Task { @MainActor [weak self] in
                    self?.voiceTriggerState = state
                }
            }
        }
        voiceTriggerStateObserver = observer
        deinitVoiceTriggerStateObserver = observer

        // Observe the Generate-Notes hand-off from the recording modal.
        // The notification carries `userInfo["transcript"]` (per #11/#12);
        // we hop it into `SessionStore` immediately so PHI does not
        // continue to ride the NotificationCenter boundary, then present
        // the review window. This closes the leak gap noted on #11's
        // hand-off comment to #13.
        let clinicalObserver = NotificationCenter.default.addObserver(
            forName: .clinicalNotesGenerateRequested,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self else { return }
            // Mirror the recording-modal poster's empty-guard
            // (LiquidGlassRecordingModal.postGenerateNotesAndDismiss)
            // as defence-in-depth. A future poster that bypasses the
            // modal's guard must not produce a degenerate session here.
            // Logs are structural-only (length / state); no PHI.
            guard let transcript = notification.userInfo?["transcript"] as? String else {
                AppLogger.app.error(
                    "AppState: clinicalNotesGenerateRequested userInfo missing transcript"
                )
                return
            }
            guard !transcript.isEmpty else {
                AppLogger.app.warning(
                    "AppState: clinicalNotesGenerateRequested empty transcript — ignoring"
                )
                return
            }
            // The notification can be delivered from either MainActor or
            // a background queue depending on the poster; hop explicitly
            // before mutating MainActor-isolated state (concurrency.md §2).
            Task { @MainActor [weak self] in
                self?.handleClinicalNotesGenerateRequested(transcript: transcript)
            }
        }
        clinicalNotesGenerateObserver = clinicalObserver
        deinitClinicalNotesGenerateObserver = clinicalObserver
    }

    deinit {
        deinitLoadingTask?.cancel()
        if let observer = deinitVoiceTriggerStateObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = deinitClinicalNotesGenerateObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // MARK: - Clinical Notes (#13)

    /// Handle the Generate-Notes hand-off. Builds a minimal
    /// `RecordingSession` carrying the transcript, hops PHI into
    /// `SessionStore`, seeds an empty `StructuredNotes` so the editor is
    /// immediately interactive in the no-LLM path (production wiring of
    /// `ClinicalNotesProcessor` lands in the same PR series as
    /// `MLXGemmaProvider` per the comment on `sessionStore` above and
    /// the `#18` blocker), then presents the review window.
    ///
    /// PHI: only the transcript length and "session started" structural
    /// markers cross the log boundary. See
    /// `.claude/references/phi-handling.md`.
    private func handleClinicalNotesGenerateRequested(transcript: String) {
        AppLogger.app.info(
            "AppState: clinicalNotes hand-off length=\(transcript.count, privacy: .public)"
        )
        let language = settings.language.defaultLanguage
        var recording = RecordingSession(
            language: language,
            state: .completed
        )
        recording.transcribedText = transcript

        sessionStore.start(from: recording)
        // Seed an empty draft so the SOAP editor is interactive without
        // waiting on the LLM (the practitioner can compose from the raw
        // transcript via the "View raw transcript" sheet). Once the LLM
        // wiring lands, this seed will be replaced with the
        // `ClinicalNotesProcessor.Outcome` payload before the window
        // presents.
        sessionStore.setDraftNotes(StructuredNotes())

        ReviewWindowController.shared.present()
    }

    // MARK: - Manipulations loader

    /// Load the bundled manipulations taxonomy. Surfaces decode / lookup
    /// failures as a structural log + empty repository — the JSON's
    /// presence is a `Package.swift` build-system invariant (#6), so a
    /// runtime failure means a build went wrong rather than something
    /// the user can fix. ReviewScreen renders an empty checklist in
    /// that pathological case so the rest of the app still functions.
    private static func loadManipulationsTaxonomy() -> ManipulationsRepository {
        do {
            return try ManipulationsRepository.loadFromBundle()
        } catch {
            // Structural log: the case description, no PHI anywhere.
            AppLogger.app.error(
                "AppState: failed to load manipulations taxonomy kind=\(String(describing: type(of: error)), privacy: .public)"
            )
            assertionFailure("AppState: manipulations taxonomy missing — see Package.swift .copy(...)")
            return ManipulationsRepository(all: [])
        }
    }

    /// Initialize FluidAudio on app startup
    func initializeFluidAudio() async {
        do {
            try await fluidAudioService.initialize(language: settings.language.defaultLanguage)
        } catch {
            errorMessage = "Failed to initialize speech recognition: \(error.localizedDescription)"
        }
    }

    /// Start a new recording session
    func startRecording() {
        currentSession = RecordingSession(
            language: settings.language.defaultLanguage,
            state: .recording
        )
        isRecording = true
    }

    /// Stop recording and transition to transcribing
    func stopRecording() {
        guard var session = currentSession else { return }
        session.endTime = Date()
        session.state = .transcribing
        currentSession = session
        isRecording = false
    }

    /// Complete session successfully
    func completeSession() async {
        guard var session = currentSession else { return }
        session.state = .completed
        session.insertionSuccess = true

        // Record statistics
        do {
            try await statisticsService.recordSession(session)
            statistics = await statisticsService.getAggregatedStats()
        } catch {
            errorMessage = "Failed to record statistics: \(error.localizedDescription)"
        }

        currentSession = nil
    }

    /// Cancel current session
    func cancelSession() {
        // Guard: only cancel if there's an active session
        guard currentSession != nil else { return }
        // Note: We don't need to set session.state = .cancelled since we're immediately clearing it
        // and not recording the cancelled session in statistics
        currentSession = nil
        isRecording = false
    }

    /// Update settings
    func updateSettings(_ newSettings: UserSettings) {
        do {
            try settingsService.save(newSettings)
            settings = newSettings
        } catch {
            errorMessage = "Failed to save settings: \(error.localizedDescription)"
        }
    }

    /// Complete onboarding
    func completeOnboarding() {
        do {
            try settingsService.completeOnboarding()
            settings = settingsService.load()
            showOnboarding = false
        } catch {
            errorMessage = "Failed to complete onboarding: \(error.localizedDescription)"
        }
    }

    /// Refresh statistics
    func refreshStatistics() async {
        statistics = await statisticsService.getAggregatedStats()
    }
}
