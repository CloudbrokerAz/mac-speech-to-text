import AppKit
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
    @ObservationIgnored let sessionStore: SessionStore

    /// Production-side `LLMProvider` (`MLXGemmaProvider`) + downloader +
    /// processor wiring (#3). The pipeline is constructed eagerly at
    /// launch but the model weights and the `ModelContainer` are *not*
    /// touched until `prepareClinicalNotesPipeline()` is invoked
    /// (today: lazily on the first `Generate Notes` tap; in a follow-up
    /// PR: from the Settings toggle when Clinical Notes Mode is enabled).
    /// `clinicalNotesProcessor` is `nil` only when the prompt template
    /// fails to load from the bundle, which would also have failed
    /// earlier asserts.
    ///
    /// Typed as `(any LLMProvider)?` rather than the concrete
    /// `MLXGemmaProvider?` so non-hardware tests can inject a
    /// `MockLLMProvider` via the `llmPipelineOverride:` init seam (#123).
    /// Without that, the cancel + await drain branch added by #121 in
    /// `removeClinicalNotesModel()` and the `unload()` wire-through
    /// added by #120 are only exercisable against the real Gemma 4
    /// model (gated on `RUN_MLX_GOLDEN=1` + a downloaded ~5 GB model)
    /// — a refactor that subtly broke cancel propagation would only be
    /// caught by the nightly hardware run.
    @ObservationIgnored let modelDownloader: ModelDownloader?
    @ObservationIgnored let llmProvider: (any LLMProvider)?
    @ObservationIgnored let clinicalNotesProcessor: ClinicalNotesProcessor?
    /// Cached pointer to the bundled manifest so per-file size lookups
    /// in `applyDownloadProgress` don't have to enter the downloader
    /// actor. Source-of-truth lives in `Resources/Models/<dir>/manifest.json`.
    @ObservationIgnored let llmManifest: ModelManifest?

    /// Observable hooks for the (future) Settings UI download surface.
    /// Updated from the `ModelDownloader` progress callback via
    /// `@MainActor` hops. UI consumers can bind directly; the values
    /// stay in `0...1` for `progress` and at `.idle` when no download
    /// is in flight. PHI-free by construction (model bytes only).
    var llmDownloadProgress: Double = 0
    var llmDownloadState: LLMDownloadState = .idle
    /// Sum of bytes fully downloaded + verified so far this session.
    /// Used by the `applyDownloadProgress` aggregator to advance the
    /// progress bar smoothly across file boundaries — without it,
    /// per-file `.bytesReceived` events would reset the bar each time
    /// a new file started.
    @ObservationIgnored var llmDownloadCompletedBytes: Int64 = 0
    /// Manifest's total bytes — captured once at `.starting`.
    @ObservationIgnored var llmDownloadTotalBytes: Int64 = 0

    /// Settings-side surface for the Gemma 4 model lifecycle (#104). Mirrors
    /// the two `llmDownload*` properties + `modelDirectoryURL` so the
    /// Settings row can bind directly. Constructed once at init with three
    /// closures that route to `downloadClinicalNotesModel()`,
    /// `cancelClinicalNotesModelDownload()`, and `removeClinicalNotesModel()`
    /// below. PHI-free by construction.
    ///
    /// `var` rather than `let` so init can construct it with `[weak self]`
    /// closures at the bottom of init (after all other stored properties
    /// have been assigned). Re-assigned exactly once and never mutated
    /// afterwards.
    @ObservationIgnored private(set) var modelStatusViewModel: ClinicalNotesModelStatusViewModel = .init()

    /// In-flight model-download / warmup task (#104). Set by
    /// `runClinicalNotesPipeline` and `downloadClinicalNotesModel` so that
    /// `cancelClinicalNotesModelDownload` can call `cancel()` on it.
    /// Re-entrant guard: a second call while the task is alive returns
    /// fast — the downloader is itself idempotent. Token-tagged so a
    /// fresh download started after a cancel doesn't have its slot
    /// clobbered by the original caller's slot-clear (silent-failure-hunter
    /// H2 / code-reviewer B2).
    @ObservationIgnored var clinicalNotesDownloadTask: (token: UUID, task: Task<Void, Never>)?

    /// In-flight clinical-notes pipeline task (#121). Set by
    /// `handleClinicalNotesGenerateRequested` so that
    /// `removeClinicalNotesModel` can drain it before releasing the
    /// `ModelContainer` mmap. Without this drain, an active
    /// `MLXGemmaProvider.runGeneration` would hold the container in a
    /// strong local across actor suspensions and pin the mmap past
    /// `unload()` due to Swift actor reentrancy. Token-tagged with the
    /// same identity-guarded-clear pattern as `clinicalNotesDownloadTask`
    /// so a re-entrant Generate Notes tap can't have its slot clobbered.
    @ObservationIgnored var clinicalNotesPipelineTask: (token: UUID, task: Task<Void, Never>)?

    /// Mirror of `clinicalNotesPipelineTask != nil`, exposed as an
    /// `@Observable` Bool so the Settings model-status row (#104) can
    /// gate the "Remove" affordance while a pipeline is in flight (#121).
    /// Set + cleared on the same MainActor as the task slot itself, so
    /// the Bool and the slot are always in sync from a UI bind's
    /// perspective.
    var isClinicalNotesPipelineActive: Bool = false

    /// Set to `true` for the duration of `removeClinicalNotesModel()` so
    /// `handleClinicalNotesGenerateRequested` can short-circuit any
    /// fresh transcript hand-off arriving via the menu-bar / hotkey /
    /// other recording surfaces while the remove is draining (#121,
    /// silent-failure-hunter Scenario 4 / Finding 9). Without this
    /// gate, a new pipeline could start during the drain's `await
    /// existing.task.value`, complete a fresh `requireContainer()` →
    /// `warmup()` against the still-on-disk weights, and capture the
    /// container into a strong local that survives the subsequent
    /// `unload()` — exactly the reentrancy hazard #121 set out to fix,
    /// in a different shape. Cleared via `defer` so an early-return
    /// branch can't leave the flag stuck.
    @ObservationIgnored var isRemovingClinicalNotesModel: Bool = false

    /// Gemma model download / warmup / pipeline lifecycle (#ARC-1).
    @ObservationIgnored private(set) var clinicalNotesLifecycle: ClinicalNotesModelLifecycleController!

    /// Static manipulations taxonomy bundled with the app (#6). Loaded
    /// once at launch and handed to `ReviewWindowController` so the
    /// review surface (#13) renders the checklist without re-parsing the
    /// JSON on every present. Empty repository on load failure — the
    /// `swift-tools-version: 5.9` `.copy(...)` in `Package.swift` makes
    /// the JSON's presence in the test bundle a build-system invariant,
    /// so any failure is a structural bug we want to surface (logged) but
    /// never want to crash production over.
    @ObservationIgnored let manipulations: ManipulationsRepository

    /// Cliniko credentials handle. Backed by the keychain via
    /// `KeychainSecureStore`; created eagerly so the export-flow
    /// setup task can read credentials without a second handle
    /// allocation. `loadCredentials()` returns nil when the
    /// practitioner hasn't yet entered an API key — the export-flow
    /// factories surface "Cliniko not configured" in that case.
    @ObservationIgnored let clinikoCredentialStore: ClinikoCredentialStore

    /// Disk-backed audit ledger for treatment-note exports (#10).
    /// Constructed once at launch; written by `TreatmentNoteExporter`
    /// after every successful POST. Falls back to in-memory if
    /// Application Support is unavailable (logged + flagged).
    @ObservationIgnored let auditStore: any AuditStore

    /// Cliniko patient-search service. Built from the configured
    /// `ClinikoClient` once credentials load; nil until then.
    @ObservationIgnored private var clinikoPatientService: (any ClinikoPatientSearching)?

    /// Cliniko appointment-loading service. Mirrors
    /// `clinikoPatientService`'s lifecycle.
    @ObservationIgnored private var clinikoAppointmentService: (any ClinikoAppointmentLoading)?

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
    /// Observer for `willTerminate` — clears in-memory PHI (#SEC-4).
    @ObservationIgnored private var willTerminateObserver: NSObjectProtocol?
    /// nonisolated copy for deinit access
    @ObservationIgnored private nonisolated(unsafe) var deinitWillTerminateObserver: NSObjectProtocol?
    /// Observer for `willResignActive` — drives `SessionStore.checkIdleTimeout()` (#SEC-5).
    @ObservationIgnored private var willResignActiveObserver: NSObjectProtocol?
    /// nonisolated copy for deinit access
    @ObservationIgnored private nonisolated(unsafe) var deinitWillResignActiveObserver: NSObjectProtocol?

    /// Designated initialiser.
    ///
    /// `llmPipelineOverride` is the `#123` init-time DI seam: pass
    /// `nil` (the production default) to build the pipeline from the
    /// bundled Gemma 4 manifest via `makeLLMPipeline(...)`; pass a
    /// pre-built pipeline (typically with a `MockLLMProvider` and a
    /// processor wired against it) to exercise the cancel + drain +
    /// unload branches added by #120 / #121 from non-hardware tests.
    /// The override does NOT replace `manipulations` — that loads from
    /// a bundle resource which is also bundled into the test target,
    /// so production manipulations and test manipulations are the same
    /// data.
    init(llmPipelineOverride: LLMPipeline? = nil) {
        // Initialize services
        self.fluidAudioService = FluidAudioService()
        self.permissionService = PermissionService()
        self.settingsService = SettingsService()
        self.statisticsService = StatisticsService()
        self.sessionStore = SessionStore()
        self.manipulations = Self.loadManipulationsTaxonomy()
        self.clinikoCredentialStore = ClinikoCredentialStore()
        self.auditStore = Self.makeAuditStore()

        // Construct the clinical-notes LLM pipeline (#3). All four are
        // optional: the manifest may be missing in pathological dev
        // builds, and the prompt template may fail to load (asserts but
        // doesn't crash). Each `nil` translates downstream into the
        // existing raw-transcript fallback path — we never crash the
        // app on a missing model. Tests can inject a pre-built pipeline
        // via `llmPipelineOverride:` (#123).
        let llmPipeline = llmPipelineOverride
            ?? Self.makeLLMPipeline(manipulations: self.manipulations)
        self.modelDownloader = llmPipeline.downloader
        self.llmProvider = llmPipeline.provider
        self.clinicalNotesProcessor = llmPipeline.processor
        self.llmManifest = llmPipeline.manifest

        // Load settings before any closure captures self — Swift's
        // definite-init checker treats `[weak self]` captures as
        // potential reads, and the closures below need every stored
        // property already initialised.
        self.settings = settingsService.load()
        self.statistics = .empty

        // Configure ReviewWindowController once with the SessionStore +
        // taxonomy so `present()` is a no-arg call from the notification
        // observer below. Mirrors the MainWindowController.shared idiom.
        // Factory closures route to `ExportFlowCoordinator.shared`
        // (configured at launch + re-validated per tap) and to a
        // per-tap fresh `PatientPickerViewModel` constructed against
        // the configured Cliniko services.
        ReviewWindowController.shared.configure(
            sessionStore: self.sessionStore,
            manipulations: self.manipulations,
            makeExportFlowViewModel: { [weak self] in
                // Re-validate config on every tap and AWAIT the
                // credential load so a freshly-pasted API key is
                // picked up before we read the coordinator. The
                // sync return path used to race
                // `configureClinikoExportPipelineIfNeeded()` and
                // produce a spurious "Cliniko isn't set up" banner
                // on the first tap after a credential change (#65).
                await self?.ensureClinikoSetupAsync()
                return ExportFlowCoordinator.shared.makeViewModel()
            },
            makePatientPickerViewModel: { [weak self] in
                await self?.ensureClinikoSetupAsync()
                return self?.makePatientPickerViewModel()
            }
        )

        // Pre-configure the Cliniko export pipeline at launch so the
        // first Generate-Notes interaction does NOT race the
        // credential load. The recording flow takes at minimum a few
        // seconds; this Task completes well before the user reaches
        // the review window in the common path. The factory closures
        // above also `await ensureClinikoSetupAsync()` to handle
        // "user just configured Cliniko in Settings and clicked
        // Generate Notes" — a much narrower window than first-tap.
        Task { @MainActor [weak self] in
            await self?.ensureClinikoSetupAsync()
        }

        // Load statistics asynchronously (actor isolation)
        // Track the task for proper lifecycle management. `statistics`
        // is initialised above (.empty) so the Task body can mutate it.
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

        // PHI lifecycle: clear in-memory session on quit (#SEC-4).
        let terminateObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.sessionStore.clear()
            AppLogger.app.info("AppState: sessionStore cleared on willTerminate")
        }
        willTerminateObserver = terminateObserver
        deinitWillTerminateObserver = terminateObserver

        // PHI lifecycle: idle-timeout check when app resigns active (#SEC-5).
        let resignObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            if self.sessionStore.checkIdleTimeout() {
                AppLogger.app.info("AppState: sessionStore cleared on idle timeout (willResignActive)")
            }
        }
        willResignActiveObserver = resignObserver
        deinitWillResignActiveObserver = resignObserver

        // Settings-side model status surface (#104). Replace the placeholder
        // VM (`@ObservationIgnored ... = .init()` in the property declaration)
        // with the wired one. By this point in init, all stored properties
        // have been assigned, so `[weak self]` is legal in the action
        // closures. The closures hop to MainActor explicitly because the VM's
        // `@Sendable` shape lets the row's button-tap fire them from any
        // context — defence in depth even when SwiftUI dispatches on Main.
        let totalBytes = llmManifest?.totalBytes ?? 0
        modelStatusViewModel = ClinicalNotesModelStatusViewModel(
            state: llmDownloadState,
            progress: llmDownloadProgress,
            manifestSizeBytes: totalBytes,
            modelDirectoryURL: nil,
            onDownload: { [weak self] in
                await self?.downloadClinicalNotesModel()
            },
            onCancel: { [weak self] in
                await self?.cancelClinicalNotesModelDownload()
            },
            onRemove: { [weak self] in
                await self?.removeClinicalNotesModel()
            }
        )
        // Wire the singleton MainWindowController with the VM so any
        // subsequently-constructed MainWindow threads it through to
        // ClinicalNotesSection. Mirrors `ReviewWindowController.shared.configure`.
        MainWindowController.shared.configure(modelStatusViewModel: modelStatusViewModel, appState: self)

        clinicalNotesLifecycle = ClinicalNotesModelLifecycleController(host: self)
    }

    deinit {
        deinitLoadingTask?.cancel()
        if let observer = deinitVoiceTriggerStateObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = deinitClinicalNotesGenerateObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = deinitWillTerminateObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = deinitWillResignActiveObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // MARK: - Clinical Notes (#13)

    /// Handle the Generate-Notes hand-off. Builds a minimal
    /// `RecordingSession` carrying the transcript, hops PHI into
    /// `SessionStore`, presents the review window in a `.pending` load
    /// state (so the editors render a "generating…" overlay rather than
    /// silently-blank text fields), then kicks off the LLM pipeline (#3)
    /// in a background Task. When the processor returns, the
    /// `draftStatus` flips to `.ready` (with the generated SOAP draft)
    /// or `.fallback(reasonCode:)` (with an empty-but-editable draft —
    /// the practitioner edits manually or via "Insert raw transcript").
    ///
    /// Bug #100: previously this method seeded an empty
    /// `StructuredNotes()` *before* the LLM ran, so any pipeline failure
    /// (download, warmup, empty SOAP that snuck past validation, …) left
    /// the Review screen rendering blank `TextEditor`s as if the model
    /// had succeeded. The pre-seed is gone; the screen reads
    /// `draftStatus` to render the correct surface.
    ///
    /// PHI: only the transcript length and "session started" structural
    /// markers cross the log boundary. The transcript itself flows into
    /// `SessionStore` and `ClinicalNotesProcessor` in-memory only — see
    /// `.claude/references/phi-handling.md`.
    private func handleClinicalNotesGenerateRequested(transcript: String) {
        AppLogger.app.info(
            "AppState: clinicalNotes hand-off length=\(transcript.count, privacy: .public)"
        )
        let language = SupportedLanguage.from(code: settings.language.defaultLanguage) ?? .en
        var recording = RecordingSession(
            language: language,
            state: .completed
        )
        recording.transcribedText = transcript

        sessionStore.start(from: recording)
        // `start(from:)` initialises `draftStatus` to `.pending` via the
        // `ClinicalSession` init default; the Review window picks that up
        // and shows the generation overlay. No `setDraftNotes` here —
        // pre-seeding an empty draft was the bug #100 root cause.

        ReviewWindowController.shared.present()

        startClinicalNotesPipeline(transcript: transcript)
    }

    private func startClinicalNotesPipeline(transcript: String) {
        clinicalNotesLifecycle.startClinicalNotesPipeline(transcript: transcript)
    }

    #if DEBUG
    func startClinicalNotesPipelineForTesting(transcript: String) {
        clinicalNotesLifecycle.startClinicalNotesPipelineForTesting(transcript: transcript)
    }
    #endif

    func downloadClinicalNotesModel() async {
        await clinicalNotesLifecycle.downloadClinicalNotesModel()
    }

    func cancelClinicalNotesModelDownload() {
        clinicalNotesLifecycle.cancelClinicalNotesModelDownload()
    }

    func removeClinicalNotesModel() async {
        await clinicalNotesLifecycle.removeClinicalNotesModel()
    }

    // MARK: - LLM pipeline construction

    /// Bundled value type that `makeLLMPipeline` returns and that the
    /// init seam (#123) accepts as an override. `internal` (rather than
    /// `private` as it was before #123) so non-hardware tests can build
    /// a test-only pipeline with a `MockLLMProvider` and inject it via
    /// `init(llmPipelineOverride:)`. Construction itself remains
    /// internal-to-the-target — there is no public API surface.
    internal struct LLMPipeline {
        let downloader: ModelDownloader?
        let provider: (any LLMProvider)?
        let processor: ClinicalNotesProcessor?
        let manifest: ModelManifest?
    }

    /// One-shot disk reclaim: delete the v1 `gemma-3-text-4b-it-4bit/`
    /// directory left in Application Support after the v2 cutover to
    /// Gemma 4 E4B (#18). The new model lives in
    /// `gemma-4-e4b-it-4bit/` so the legacy directory would otherwise
    /// orphan ~2.6 GB on every existing user's disk.
    ///
    /// Idempotent — the existence check on the legacy path is the
    /// guard, no `UserDefaults` flag needed. Errors are logged and
    /// swallowed: a stuck legacy directory is a disk-space loss, not
    /// a correctness failure.
    ///
    /// `nonisolated` so the synchronous `FileManager.removeItem(at:)`
    /// can run from a background `Task.detached` instead of holding the
    /// MainActor while a multi-GB directory tree unlinks.
    nonisolated private static func purgeLegacyGemma3ModelDirectory() {
        let legacyPath = ModelDownloader.defaultBaseDirectory()
            .appendingPathComponent("gemma-3-text-4b-it-4bit", isDirectory: true)
        guard FileManager.default.fileExists(atPath: legacyPath.path) else {
            return
        }
        do {
            try FileManager.default.removeItem(at: legacyPath)
            // `.private` on the path: the resolved URL includes
            // `/Users/<username>/...` which is local-PII per the
            // `.gemini/styleguide.md` rule "paths are not structural
            // values". Error `kind` stays `.public` — it's a class name.
            AppLogger.app.info(
                "AppState: removed legacy Gemma 3 model directory at \(legacyPath.path, privacy: .private)"
            )
        } catch {
            AppLogger.app.error(
                "AppState: failed to remove legacy Gemma 3 directory kind=\(String(describing: type(of: error)), privacy: .public)"
            )
        }
    }

    /// Build the `ModelDownloader` + `MLXGemmaProvider` + `ClinicalNotesProcessor`
    /// trio from bundled resources. Any missing piece (manifest absent,
    /// prompt template missing) returns `nil` for the corresponding
    /// member so callers fall back to the empty-draft path; we never
    /// crash on a misconfigured bundle.
    private static func makeLLMPipeline(
        manipulations: ManipulationsRepository
    ) -> LLMPipeline {
        // Reclaim disk used by the v1 Gemma 3 weights — fire-and-forget
        // on a utility-priority detached task so app init never waits
        // on a multi-GB directory unlink. Idempotent — the directory
        // check IS the guard, so repeat launches after the cleanup are
        // no-ops. The cleanup operates on a different directory name
        // (`gemma-3-…` vs the new `gemma-4-…`) so it can never race
        // with the v2 download started downstream of this method.
        Task.detached(priority: .utility) {
            Self.purgeLegacyGemma3ModelDirectory()
        }

        guard let manifestURL = Bundle.module.url(
            forResource: "manifest",
            withExtension: "json",
            subdirectory: "Models/gemma-4-e4b-it-4bit"
        ) else {
            AppLogger.app.warning(
                "AppState: LLM manifest not bundled — clinical-notes LLM disabled"
            )
            return LLMPipeline(downloader: nil, provider: nil, processor: nil, manifest: nil)
        }
        let manifest: ModelManifest
        do {
            let data = try Data(contentsOf: manifestURL)
            manifest = try JSONDecoder().decode(ModelManifest.self, from: data)
        } catch {
            AppLogger.app.error(
                "AppState: LLM manifest decode failed kind=\(String(describing: type(of: error)), privacy: .public)"
            )
            return LLMPipeline(downloader: nil, provider: nil, processor: nil, manifest: nil)
        }
        let downloader = ModelDownloader(manifest: manifest)
        let modelDir = ModelDownloader.defaultBaseDirectory()
            .appendingPathComponent(
                manifest.modelDirectoryName,
                isDirectory: true
            )
        let provider = MLXGemmaProvider(modelDirectory: modelDir)
        let processor: ClinicalNotesProcessor?
        do {
            let promptBuilder = try ClinicalNotesPromptBuilder.loadFromBundle(
                manipulations: manipulations
            )
            processor = ClinicalNotesProcessor(
                provider: provider,
                promptBuilder: promptBuilder,
                manipulations: manipulations
            )
        } catch {
            AppLogger.app.error(
                "AppState: prompt builder load failed kind=\(String(describing: type(of: error)), privacy: .public) — clinical-notes processor disabled"
            )
            processor = nil
        }
        return LLMPipeline(
            downloader: downloader,
            provider: provider,
            processor: processor,
            manifest: manifest
        )
    }

    // MARK: - Cliniko export pipeline (#14)

    /// Ensure the Cliniko export pipeline (`TreatmentNoteExporter`,
    /// patient/appointment services, and the
    /// `ExportFlowCoordinator`) are wired against the latest
    /// keychain credentials. Idempotent — once configured, repeat
    /// calls re-load credentials so a freshly-pasted API key is
    /// picked up without restarting the app.
    ///
    /// `async` so the review window's factory closures can `await`
    /// the credential load before reading the coordinator. The
    /// previous sync wrapper kicked off an async Task and returned
    /// immediately — fine for cold-launch (the Task lands well
    /// before the recording flow ends) but raced the post-credential-
    /// change tap path (#65). Both call sites now await.
    func ensureClinikoSetupAsync() async {
        await configureClinikoExportPipelineIfNeeded()
    }

    /// Async configuration of the Cliniko export pipeline. Safe to
    /// call repeatedly — overwrites the existing coordinator config
    /// with the latest credentials.
    ///
    /// Returns silently in two cases that share the same downstream
    /// banner ("Cliniko isn't set up — configure your API key in
    /// Settings"):
    /// 1. No API key in the keychain (`loadCredentials` returns nil).
    /// 2. The keychain load *threw* (locked keychain, denied prompt,
    ///    code-signing change). Tracked as a follow-up: the post-#65
    ///    always-await flow now runs this on the user's tap, so the
    ///    failed-load case deserves a distinct banner. Until that
    ///    lands, the structural log line above is the only signal.
    private func configureClinikoExportPipelineIfNeeded() async {
        let credentials: ClinikoCredentials?
        do {
            credentials = try await clinikoCredentialStore.loadCredentials()
        } catch {
            AppLogger.app.error(
                "AppState: ClinikoCredentialStore.loadCredentials failed type=\(String(describing: type(of: error)), privacy: .public)"
            )
            return
        }
        guard let credentials else {
            AppLogger.app.info("AppState: Cliniko credentials not configured — export pipeline idle")
            return
        }
        let client = ClinikoClient(credentials: credentials)
        self.clinikoPatientService = ClinikoPatientService(client: client)
        self.clinikoAppointmentService = ClinikoAppointmentService(client: client)
        let exporter = TreatmentNoteExporter(
            client: client,
            auditStore: self.auditStore,
            manipulations: self.manipulations
        )
        ExportFlowCoordinator.shared.configure(
            sessionStore: self.sessionStore,
            exporter: exporter,
            manipulations: self.manipulations,
            openClinikoSettings: { [weak self] in
                self?.openClinikoSettings()
            },
            closeReviewWindow: {
                ReviewWindowController.shared.close()
            }
        )
        AppLogger.app.info("AppState: Cliniko export pipeline configured")
    }

    /// Build a fresh `PatientPickerViewModel` for the header-hosted
    /// picker sheet (#14). Returns nil when the Cliniko services
    /// haven't been configured yet (either Cliniko isn't set up,
    /// or `configureClinikoExportPipelineIfNeeded()` is still
    /// loading) — the picker chip's tap shows "Cliniko isn't set
    /// up" until the next tap finds a configured pipeline.
    private func makePatientPickerViewModel() -> PatientPickerViewModel? {
        guard let patientService = clinikoPatientService,
              let appointmentService = clinikoAppointmentService else {
            return nil
        }
        return PatientPickerViewModel(
            patientService: patientService,
            appointmentService: appointmentService,
            sessionStore: self.sessionStore
        )
    }

    /// Routes the practitioner to the Cliniko credentials surface.
    /// Wired by `ExportFlowCoordinator.configure(...)` for the
    /// 401 / 403 paths so the export sheet's "Open Cliniko
    /// Settings" button lands somewhere meaningful.
    func openClinikoSettings() {
        AppLogger.app.info("AppState: opening Cliniko settings via Clinical Notes section")
        MainWindowController.shared.showSection(.clinicalNotes)
    }

    /// Construct the disk-backed audit store at launch. Falls back
    /// to in-memory if Application Support is unavailable — the
    /// fallback path lets the export pipeline still write
    /// `auditPersisted = true` so the post-success UI behaves
    /// correctly, while the structural log signals that the on-disk
    /// ledger is unavailable for this launch.
    private static func makeAuditStore() -> any AuditStore {
        do {
            let url = try LocalAuditStore.defaultURL()
            return LocalAuditStore(fileURL: url)
        } catch {
            AppLogger.app.error(
                "AppState: LocalAuditStore unavailable kind=\(String(describing: type(of: error)), privacy: .public) — falling back to InMemoryAuditStore"
            )
            return InMemoryAuditStore()
        }
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
            language: SupportedLanguage.from(code: settings.language.defaultLanguage) ?? .en,
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
