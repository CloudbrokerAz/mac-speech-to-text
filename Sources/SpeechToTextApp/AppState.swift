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
    @ObservationIgnored let modelDownloader: ModelDownloader?
    @ObservationIgnored let llmProvider: MLXGemmaProvider?
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
    @ObservationIgnored private var llmDownloadCompletedBytes: Int64 = 0
    /// Manifest's total bytes — captured once at `.starting`.
    @ObservationIgnored private var llmDownloadTotalBytes: Int64 = 0

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

    init() {
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
        // app on a missing model.
        let llmPipeline = Self.makeLLMPipeline(manipulations: self.manipulations)
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
                // Re-validate config on every tap so a freshly-pasted
                // API key is picked up without restarting the app —
                // the launch-time pre-configure (below) handles the
                // common "key was already set" path.
                self?.ensureClinikoSetupSync()
                return ExportFlowCoordinator.shared.makeViewModel()
            },
            makePatientPickerViewModel: { [weak self] in
                self?.ensureClinikoSetupSync()
                return self?.makePatientPickerViewModel()
            }
        )

        // Pre-configure the Cliniko export pipeline at launch so the
        // first Generate-Notes interaction does NOT race the
        // credential load. The recording flow takes at minimum a few
        // seconds; this Task completes well before the user reaches
        // the review window in the common path. The factory closures
        // above also re-call `ensureClinikoSetupSync()` to handle
        // "user just configured Cliniko in Settings and clicked
        // Generate Notes" — a much narrower window than first-tap.
        ensureClinikoSetupSync()

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
    /// immediately interactive while the LLM runs, presents the review
    /// window, then kicks off the LLM pipeline (#3) in a background
    /// Task. When the processor returns, the draft is replaced with the
    /// generated SOAP payload (or stays as the empty seed on
    /// `.rawTranscriptFallback`, mirroring the existing UX contract).
    ///
    /// PHI: only the transcript length and "session started" structural
    /// markers cross the log boundary. The transcript itself flows into
    /// `SessionStore` and `ClinicalNotesProcessor` in-memory only — see
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
        sessionStore.setDraftNotes(StructuredNotes())

        ReviewWindowController.shared.present()

        // Kick off LLM processing without blocking the UI present.
        // `runClinicalNotesPipeline` ensures-download + warms-up + runs
        // the processor; any failure resolves to the existing empty-draft
        // fallback so the practitioner can edit manually.
        Task { @MainActor [weak self] in
            await self?.runClinicalNotesPipeline(transcript: transcript)
        }
    }

    /// Drive the LLM pipeline end-to-end for a single transcript. Idempotent
    /// across model state — re-entry while a download is in flight returns
    /// fast (the downloader is itself idempotent + actor-serialised).
    /// Failures are absorbed into structural log entries and leave the
    /// existing empty `StructuredNotes` draft in place so the practitioner
    /// keeps a working surface.
    private func runClinicalNotesPipeline(transcript: String) async {
        guard
            let downloader = modelDownloader,
            let provider = llmProvider,
            let processor = clinicalNotesProcessor
        else {
            AppLogger.app.warning(
                "AppState: clinical-notes pipeline unavailable (missing manifest or template)"
            )
            return
        }
        do {
            llmDownloadState = .downloading
            // Per-event Task hops to MainActor are not strictly ordered
            // (Gemini Code Assist, PR #70). After the refactor to
            // `URLSession.download(for:)` the events are far apart in
            // time (one `.fileStarted` / `.bytesReceived` / `.fileVerified`
            // per file in the manifest, not per byte) so practical
            // reordering is highly unlikely. The aggregator
            // (`applyDownloadProgress`) is also hardened to be order-
            // insensitive: progress monotonically increases and latches
            // at 1.0 on `.completed`, and `.cancelled` / `.failed` are
            // terminal. Promote to an `AsyncStream`-piped source if a
            // future progress event design becomes per-byte.
            let modelDir = try await downloader.ensureModelDownloaded { [weak self] event in
                Task { @MainActor [weak self] in
                    self?.applyDownloadProgress(event)
                }
            }
            llmDownloadState = .verified(directory: modelDir)
            try await provider.warmup()
            llmDownloadState = .ready
        } catch is CancellationError {
            // User-initiated cancel is a clean state transition, not a
            // failure. Don't overwrite to `.failed` — `applyDownloadProgress`
            // may have already set `.cancelled`, and either order yields the
            // correct final state.
            AppLogger.app.info("AppState: clinical-notes pipeline cancelled")
            if llmDownloadState != .cancelled {
                llmDownloadState = .cancelled
            }
            return
        } catch {
            AppLogger.app.error(
                "AppState: clinical-notes warmup failed kind=\(String(describing: type(of: error)), privacy: .public)"
            )
            llmDownloadState = .failed
            return
        }

        let outcome = await processor.process(transcript: transcript)
        switch outcome {
        case .success(let notes):
            sessionStore.setDraftNotes(notes)
            AppLogger.app.info("AppState: clinical-notes draft populated")
        case .rawTranscriptFallback(let reason):
            AppLogger.app.info(
                "AppState: clinical-notes fell back reason=\(reason, privacy: .public)"
            )
        }
    }

    /// Translate a `ModelDownloader.DownloadProgress` event into the
    /// `@Observable` properties the (future) Settings UI surface binds
    /// against. Aggregates per-file progress into a single overall
    /// `llmDownloadProgress` in `[0, 1]` so the bar advances smoothly
    /// across the multi-file manifest (file boundaries no longer leave
    /// the UI looking frozen).
    private func applyDownloadProgress(_ event: ModelDownloader.DownloadProgress) {
        switch event {
        case .starting(let totalBytes):
            llmDownloadProgress = 0
            llmDownloadCompletedBytes = 0
            llmDownloadTotalBytes = totalBytes
            llmDownloadState = .downloading
        case .fileStarted(let path, let expected):
            AppLogger.app.info(
                "AppState: clinical-notes download begin file=\(path, privacy: .public) bytes=\(expected, privacy: .public)"
            )
        case .bytesReceived(_, let received, let total):
            // Aggregate progress across the whole manifest, not just the
            // active file: previously-completed bytes plus the active
            // file's running tally. Latches at 1.0 so a stale event after
            // `.completed` cannot regress the bar.
            let denom = max(llmDownloadTotalBytes, 1)
            let raw = Double(llmDownloadCompletedBytes + received) / Double(denom)
            llmDownloadProgress = min(max(raw, llmDownloadProgress), 1.0)
            _ = total // expected denominator at the per-file level — we use the manifest-wide denom instead
        case .fileVerified(let path):
            // A verified file's bytes graduate from "in flight" to
            // "completed" so the next file's `bytesReceived` rolls up
            // from the right baseline. The manifest is the authority for
            // the file's size.
            if let file = downloadedFileSize(path: path) {
                llmDownloadCompletedBytes += file
            }
            AppLogger.app.info(
                "AppState: clinical-notes download verified file=\(path, privacy: .public)"
            )
        case .completed(let dir):
            llmDownloadProgress = 1
            llmDownloadState = .verified(directory: dir)
        case .cancelled:
            llmDownloadState = .cancelled
        }
    }

    /// Lookup the manifest-declared size of a file by its repo-relative
    /// path. Returns `nil` for an unknown path so the aggregator can
    /// no-op rather than miscount.
    private func downloadedFileSize(path: String) -> Int64? {
        guard let downloader = modelDownloader else { return nil }
        // The downloader's manifest is the source of truth. We only need
        // the size lookup, which is cheap and does not require entering
        // the actor — but we don't have direct access to the manifest
        // through the downloader's public API. Cache via the bundled
        // manifest read once at init time. (The manifest is already
        // in-memory inside `makeLLMPipeline`; we save a copy here.)
        _ = downloader
        return llmManifest?.files.first(where: { $0.path == path })?.size
    }

    // MARK: - LLM pipeline construction

    private struct LLMPipeline {
        let downloader: ModelDownloader?
        let provider: MLXGemmaProvider?
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
    /// "Sync" because the factory closures are sync. Internally
    /// kicks off an async credential load and configures the
    /// coordinator on completion; the same closure-call cycle that
    /// returned `nil` once will succeed on the next tap once the
    /// async load lands.
    private func ensureClinikoSetupSync() {
        Task { @MainActor [weak self] in
            await self?.configureClinikoExportPipelineIfNeeded()
        }
    }

    /// Async configuration of the Cliniko export pipeline. Safe to
    /// call repeatedly — overwrites the existing coordinator config
    /// with the latest credentials. Returns silently when no API
    /// key is set (export factories return nil; UI surfaces
    /// "Cliniko isn't set up").
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
