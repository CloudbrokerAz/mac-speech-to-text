// ReviewViewModelTests.swift
// macOS Local Speech-to-Text Application
//
// Swift Testing `.fast` suite for `ReviewViewModel` (#13). Covers:
//   - SOAP-field bindings write through to `SessionStore.draftNotes`,
//   - manipulation toggle adds/removes entries from
//     `selectedManipulationIDs`,
//   - excluded re-add routes to default (Subjective) when no recent
//     focus, and to the last-focused field when within the focus window,
//   - `excludedEntries` filters out re-added entries,
//   - cancel clears the session and posts `.reviewScreenDidDismiss`,
//   - export posts `.clinicalNotesExportRequested` only when a patient
//     is selected.
//
// PHI: tests use synthetic strings only. No real transcripts, no
// Cliniko, no LLM, no Keychain. See `.claude/references/testing-conventions.md`.

import Foundation
import Testing
@testable import SpeechToText

@Suite("ReviewViewModel", .tags(.fast))
@MainActor
struct ReviewViewModelTests {

    // MARK: - Helpers

    private func stubManipulations() -> ManipulationsRepository {
        ManipulationsRepository(all: [
            Manipulation(id: "diversified_hvla", displayName: "Diversified HVLA", clinikoCode: nil),
            Manipulation(id: "activator", displayName: "Activator", clinikoCode: nil),
            Manipulation(id: "thompson", displayName: "Thompson", clinikoCode: nil)
        ])
    }

    private func makeSessionWith(
        transcript: String = "Synthetic transcript.",
        notes: StructuredNotes? = StructuredNotes(),
        status: ClinicalNotesDraftStatus = .ready
    ) -> SessionStore {
        let store = SessionStore()
        var recording = RecordingSession(language: "en", state: .completed)
        recording.transcribedText = transcript
        store.start(from: recording)
        if let notes {
            store.setDraftNotes(notes)
        }
        // `start(from:)` initialises status to `.pending` (the
        // production default for the brief gap between Generate Notes
        // and the first processor return). Most existing tests want
        // the steady-state `.ready` rendering — the fixture flips
        // explicitly so each `setValue` / re-add / toggle test
        // exercises the post-LLM surface, not the pending overlay.
        store.setDraftStatus(status)
        return store
    }

    // MARK: - SOAP bindings

    @Test("setValue writes through to SessionStore.draftNotes for each field")
    func setValueWritesThroughToSessionStore() {
        let store = makeSessionWith()
        let viewModel = ReviewViewModel(sessionStore: store, manipulations: stubManipulations())

        viewModel.setValue("Subj", for: .subjective)
        viewModel.setValue("Obj", for: .objective)
        viewModel.setValue("Asm", for: .assessment)
        viewModel.setValue("Pln", for: .plan)

        let draft = store.active?.draftNotes
        #expect(draft?.subjective == "Subj")
        #expect(draft?.objective == "Obj")
        #expect(draft?.assessment == "Asm")
        #expect(draft?.plan == "Pln")
    }

    @Test("binding(for:) round-trips through SessionStore on every set")
    func bindingRoundTripsThroughSessionStore() {
        let store = makeSessionWith()
        let viewModel = ReviewViewModel(sessionStore: store, manipulations: stubManipulations())

        let binding = viewModel.binding(for: .subjective)
        binding.wrappedValue = "First"
        #expect(store.active?.draftNotes?.subjective == "First")

        binding.wrappedValue = "Second"
        #expect(store.active?.draftNotes?.subjective == "Second")
    }

    @Test("setValue without active session does not write but surfaces a banner")
    func setValueNoOpWithoutActiveSession() {
        let store = SessionStore() // no active
        let viewModel = ReviewViewModel(sessionStore: store, manipulations: stubManipulations())

        viewModel.setValue("Subj", for: .subjective)

        #expect(store.active == nil)
        // S2 mitigation: every silent-guard hit surfaces a banner so the
        // doctor sees that their keystroke is not landing (idle-timeout
        // path between recording end and review-window close).
        #expect(viewModel.errorMessage != nil)
    }

    @Test("toggleManipulation without active session surfaces a banner")
    func toggleManipulationSurfacesBannerWithoutSession() {
        let store = SessionStore()
        let viewModel = ReviewViewModel(sessionStore: store, manipulations: stubManipulations())

        viewModel.toggleManipulation(id: "activator")

        #expect(viewModel.errorMessage != nil)
    }

    @Test("reAddExcludedEntry without active session surfaces a banner")
    func reAddSurfacesBannerWithoutSession() {
        let store = SessionStore()
        let viewModel = ReviewViewModel(sessionStore: store, manipulations: stubManipulations())

        viewModel.reAddExcludedEntry("Anything")

        #expect(viewModel.errorMessage != nil)
    }

    @Test("setValue lazily seeds StructuredNotes when draft is nil")
    func setValueSeedsDraftWhenNil() {
        let store = makeSessionWith(notes: nil) // active session, no draft
        #expect(store.active?.draftNotes == nil)

        let viewModel = ReviewViewModel(sessionStore: store, manipulations: stubManipulations())
        viewModel.setValue("Hello", for: .objective)

        #expect(store.active?.draftNotes?.objective == "Hello")
        #expect(store.active?.draftNotes?.subjective == "")
    }

    // MARK: - Manipulation toggle

    @Test("toggleManipulation adds and then removes an id from selectedManipulationIDs")
    func toggleManipulationAddsAndRemoves() {
        let store = makeSessionWith()
        let viewModel = ReviewViewModel(sessionStore: store, manipulations: stubManipulations())

        viewModel.toggleManipulation(id: "activator")
        #expect(viewModel.isManipulationSelected(id: "activator"))
        #expect(store.active?.draftNotes?.selectedManipulationIDs == ["activator"])

        viewModel.toggleManipulation(id: "activator")
        #expect(!viewModel.isManipulationSelected(id: "activator"))
        #expect(store.active?.draftNotes?.selectedManipulationIDs == [])
    }

    @Test("toggleManipulation seeds an empty draft when needed")
    func toggleManipulationSeedsDraft() {
        let store = makeSessionWith(notes: nil)
        let viewModel = ReviewViewModel(sessionStore: store, manipulations: stubManipulations())

        viewModel.toggleManipulation(id: "diversified_hvla")
        #expect(store.active?.draftNotes?.selectedManipulationIDs == ["diversified_hvla"])
    }

    // MARK: - Excluded re-add routing

    @Test("reAddExcludedEntry routes to Subjective by default and removes from drawer")
    func reAddDefaultsToSubjective() {
        let store = makeSessionWith()
        var notes = StructuredNotes()
        notes.subjective = "Pre-existing."
        notes.excluded = ["Weather chat.", "Parking talk."]
        store.setDraftNotes(notes)

        let viewModel = ReviewViewModel(sessionStore: store, manipulations: stubManipulations())

        viewModel.reAddExcludedEntry("Weather chat.")

        // Routed to Subjective, separator preserved.
        let updated = try? #require(store.active?.draftNotes)
        #expect(updated?.subjective == "Pre-existing.\n\nWeather chat.")

        // Drawer hides re-added entries.
        #expect(viewModel.excludedEntries == ["Parking talk."])
    }

    @Test("reAddExcludedEntry honours the last-focused field within the window")
    func reAddRoutesToRecentlyFocusedField() {
        let store = makeSessionWith()
        var notes = StructuredNotes()
        notes.objective = "Existing objective."
        notes.excluded = ["Tangential remark."]
        store.setDraftNotes(notes)

        var clock = Date(timeIntervalSince1970: 1_000_000)
        let viewModel = ReviewViewModel(
            sessionStore: store,
            manipulations: stubManipulations(),
            reAddTargetWindow: 5.0,
            now: { clock }
        )

        // Practitioner focused Objective at t=0.
        viewModel.noteFieldFocused(.objective)

        // Re-adds 2 seconds later — within the 5s window — so target = .objective.
        clock = Date(timeIntervalSince1970: 1_000_002)
        viewModel.reAddExcludedEntry("Tangential remark.")

        #expect(store.active?.draftNotes?.objective == "Existing objective.\n\nTangential remark.")
        #expect(store.active?.draftNotes?.subjective == "")
    }

    @Test("reAddExcludedEntry falls back to Subjective once the focus window expires")
    func reAddFallsBackOnceFocusWindowExpires() {
        let store = makeSessionWith()
        var notes = StructuredNotes()
        notes.excluded = ["Late re-add."]
        store.setDraftNotes(notes)

        var clock = Date(timeIntervalSince1970: 2_000_000)
        let viewModel = ReviewViewModel(
            sessionStore: store,
            manipulations: stubManipulations(),
            reAddTargetWindow: 5.0,
            now: { clock }
        )

        viewModel.noteFieldFocused(.plan)
        // 6 s later — outside the 5 s window.
        clock = Date(timeIntervalSince1970: 2_000_006)

        viewModel.reAddExcludedEntry("Late re-add.")

        #expect(store.active?.draftNotes?.plan == "")
        #expect(store.active?.draftNotes?.subjective == "Late re-add.")
    }

    @Test("reAddExcludedEntry handles empty target field without leading newlines")
    func reAddDoesNotAddSeparatorToEmptyField() {
        let store = makeSessionWith()
        var notes = StructuredNotes()
        notes.excluded = ["Solo entry."]
        store.setDraftNotes(notes)

        let viewModel = ReviewViewModel(sessionStore: store, manipulations: stubManipulations())

        viewModel.reAddExcludedEntry("Solo entry.")

        #expect(store.active?.draftNotes?.subjective == "Solo entry.")
    }

    // MARK: - excludedEntries filter

    @Test("excludedEntries filters out entries already in excludedReAdded")
    func excludedEntriesFiltersReAdded() {
        let store = makeSessionWith()
        var notes = StructuredNotes()
        notes.excluded = ["A", "B", "C"]
        store.setDraftNotes(notes)
        store.markExcludedReAdded("B")

        let viewModel = ReviewViewModel(sessionStore: store, manipulations: stubManipulations())
        #expect(viewModel.excludedEntries == ["A", "C"])
    }

    @Test("excludedEntries handles duplicates by count, leaving extra copies in the drawer")
    func excludedEntriesHandlesDuplicatesByCount() {
        // SessionStore.markExcludedReAdded dedups same-string re-adds
        // (audit-trail invariant), so even if the same snippet appears
        // twice in `notes.excluded`, only one re-add is tracked. The
        // count-based filter therefore hides one copy and keeps the
        // other in the drawer — order preserved from the LLM output.
        let store = makeSessionWith()
        var notes = StructuredNotes()
        notes.excluded = ["dup", "dup", "single"]
        store.setDraftNotes(notes)
        store.markExcludedReAdded("dup")

        let viewModel = ReviewViewModel(sessionStore: store, manipulations: stubManipulations())
        #expect(viewModel.excludedEntries == ["dup", "single"])
    }

    @Test("reAddExcludedEntry trims trailing whitespace before adding the separator")
    func reAddTrimsTrailingWhitespace() {
        let store = makeSessionWith()
        var notes = StructuredNotes()
        // Existing has trailing whitespace + newline (e.g. from a prior
        // re-add that the practitioner partially deleted).
        notes.subjective = "Pre-existing.   \n\n"
        notes.excluded = ["New snippet."]
        store.setDraftNotes(notes)

        let viewModel = ReviewViewModel(sessionStore: store, manipulations: stubManipulations())

        viewModel.reAddExcludedEntry("New snippet.")

        #expect(store.active?.draftNotes?.subjective == "Pre-existing.\n\nNew snippet.")
    }

    // MARK: - canExport / triggerExport

    @Test("canExport requires a selected patient")
    func canExportRequiresPatient() {
        let store = makeSessionWith()
        let viewModel = ReviewViewModel(sessionStore: store, manipulations: stubManipulations())
        #expect(!viewModel.canExport)

        store.setSelectedPatient(id: OpaqueClinikoID(42))
        #expect(viewModel.canExport)
    }

    @Test("triggerExport without a patient sets a structural error message and does not present a sheet")
    func triggerExportWithoutPatientSetsErrorMessage() async {
        let store = makeSessionWith()
        let viewModel = ReviewViewModel(sessionStore: store, manipulations: stubManipulations())

        await viewModel.triggerExport()

        // No sheet — the canExport gate fires before the factory is
        // ever consulted, so the export sheet does not present.
        #expect(viewModel.errorMessage != nil)
        #expect(viewModel.exportFlowSheet == nil)
    }

    @Test("triggerExport with a patient invokes the export factory and presents the sheet")
    func triggerExportWithPatientPresentsSheet() async {
        let store = makeSessionWith()
        store.setSelectedPatient(id: OpaqueClinikoID(99))
        store.setDraftNotes(StructuredNotes(subjective: "s"))

        // Hand-rolled factory that returns a real ExportFlowViewModel
        // built against in-memory fakes. The export VM doesn't need
        // to do anything past `idle` for this test — we only assert
        // the wiring.
        let exporter = TreatmentNoteExporter(
            client: ClinikoClient(
                credentials: try! ClinikoCredentials(apiKey: "MS-test-au1", shard: .au1),
                session: URLSession.shared
            ),
            auditStore: InMemoryAuditStore(),
            manipulations: stubManipulations()
        )
        let factory: () async -> ExportFlowViewModel? = {
            ExportFlowViewModel(
                sessionStore: store,
                dependencies: ExportFlowDependencies(
                    exporter: exporter,
                    manipulations: stubManipulationsRepo(),
                    onSuccess: {},
                    openClinikoSettings: {},
                    copyToClipboard: { _ in }
                )
            )
        }
        let viewModel = ReviewViewModel(
            sessionStore: store,
            manipulations: stubManipulations(),
            makeExportFlowViewModel: factory
        )

        await viewModel.triggerExport()

        #expect(viewModel.exportFlowSheet != nil)
        #expect(viewModel.errorMessage == nil)
    }

    @Test("triggerExport with a patient but no factory surfaces a 'Cliniko not set up' banner")
    func triggerExportWithoutFactorySurfacesBanner() async {
        let store = makeSessionWith()
        store.setSelectedPatient(id: OpaqueClinikoID(99))

        // Default factory closure returns nil.
        let viewModel = ReviewViewModel(sessionStore: store, manipulations: stubManipulations())

        await viewModel.triggerExport()

        #expect(viewModel.exportFlowSheet == nil)
        #expect(viewModel.errorMessage != nil)
    }

    @Test("dismissExportFlow clears the sheet")
    func dismissExportFlowClearsSheet() async {
        let store = makeSessionWith()
        store.setSelectedPatient(id: OpaqueClinikoID(99))
        store.setDraftNotes(StructuredNotes(subjective: "s"))

        let exporter = TreatmentNoteExporter(
            client: ClinikoClient(
                credentials: try! ClinikoCredentials(apiKey: "MS-test-au1", shard: .au1),
                session: URLSession.shared
            ),
            auditStore: InMemoryAuditStore(),
            manipulations: stubManipulations()
        )
        let factory: () async -> ExportFlowViewModel? = {
            ExportFlowViewModel(
                sessionStore: store,
                dependencies: ExportFlowDependencies(
                    exporter: exporter,
                    manipulations: stubManipulationsRepo(),
                    onSuccess: {},
                    openClinikoSettings: {},
                    copyToClipboard: { _ in }
                )
            )
        }
        let viewModel = ReviewViewModel(
            sessionStore: store,
            manipulations: stubManipulations(),
            makeExportFlowViewModel: factory
        )

        await viewModel.triggerExport()
        #expect(viewModel.exportFlowSheet != nil)

        viewModel.dismissExportFlow()
        #expect(viewModel.exportFlowSheet == nil)
    }

    private func stubManipulationsRepo() -> ManipulationsRepository { stubManipulations() }

    // MARK: - Post-credential-change race (#65)

    @Test(
        "triggerExport awaits the async factory — first tap after a credential change presents the sheet without a 'Cliniko isn't set up' banner"
    )
    func triggerExportAwaitsAsyncFactoryAfterCredentialChange() async {
        let store = makeSessionWith()
        store.setSelectedPatient(id: OpaqueClinikoID(99))
        store.setDraftNotes(StructuredNotes(subjective: "s"))

        let exporter = TreatmentNoteExporter(
            client: ClinikoClient(
                credentials: try! ClinikoCredentials(apiKey: "MS-test-au1", shard: .au1),
                session: URLSession.shared
            ),
            auditStore: InMemoryAuditStore(),
            manipulations: stubManipulations()
        )

        // Mirror the production race: the configure-pipeline Task
        // hasn't completed when `triggerExport` first runs. The
        // pre-#65 sync factory would have read the coordinator
        // immediately and returned nil. The fix's async factory
        // suspends mid-flight (here: two `Task.yield()`s — one
        // hop per actor boundary the production
        // `configureClinikoExportPipelineIfNeeded()` crosses), and
        // `triggerExport` awaits it. The end-state assertions pin
        // the user-visible contract: sheet present, no spurious
        // banner.
        let factory: () async -> ExportFlowViewModel? = {
            await Task.yield()
            await Task.yield()
            return ExportFlowViewModel(
                sessionStore: store,
                dependencies: ExportFlowDependencies(
                    exporter: exporter,
                    manipulations: stubManipulationsRepo(),
                    onSuccess: {},
                    openClinikoSettings: {},
                    copyToClipboard: { _ in }
                )
            )
        }
        let viewModel = ReviewViewModel(
            sessionStore: store,
            manipulations: stubManipulations(),
            makeExportFlowViewModel: factory
        )

        await viewModel.triggerExport()

        #expect(!viewModel.isPreparingExport, "isPreparingExport should be cleared by the defer once the await completes")
        #expect(viewModel.exportFlowSheet != nil, "First tap should present the sheet, not surface 'Cliniko isn't set up'")
        #expect(viewModel.errorMessage == nil)
    }

    @Test("triggerExport's isPreparingExport flag is true mid-await and false after — the spinner UI binds to this signal")
    func triggerExportSurfacesPreparingFlagDuringAwait() async {
        let store = makeSessionWith()
        store.setSelectedPatient(id: OpaqueClinikoID(99))
        store.setDraftNotes(StructuredNotes(subjective: "s"))

        let exporter = TreatmentNoteExporter(
            client: ClinikoClient(
                credentials: try! ClinikoCredentials(apiKey: "MS-test-au1", shard: .au1),
                session: URLSession.shared
            ),
            auditStore: InMemoryAuditStore(),
            manipulations: stubManipulations()
        )

        // Probe the flag from inside the factory's await — the
        // factory closure runs while `triggerExport` is suspended
        // mid-`await`, so reading the VM's flag here proves the
        // ProgressView swap on `reviewScreen.actions.export.loading`
        // would render.
        var observedFlagDuringAwait = false
        var capturedViewModel: ReviewViewModel?
        let factory: () async -> ExportFlowViewModel? = {
            // The factory is async-isolated; hop back to MainActor
            // to read the @MainActor flag.
            observedFlagDuringAwait = await MainActor.run {
                capturedViewModel?.isPreparingExport ?? false
            }
            return ExportFlowViewModel(
                sessionStore: store,
                dependencies: ExportFlowDependencies(
                    exporter: exporter,
                    manipulations: stubManipulationsRepo(),
                    onSuccess: {},
                    openClinikoSettings: {},
                    copyToClipboard: { _ in }
                )
            )
        }
        let viewModel = ReviewViewModel(
            sessionStore: store,
            manipulations: stubManipulations(),
            makeExportFlowViewModel: factory
        )
        capturedViewModel = viewModel

        await viewModel.triggerExport()

        #expect(observedFlagDuringAwait, "isPreparingExport should be true while the factory is awaiting")
        #expect(!viewModel.isPreparingExport, "defer should clear the flag once the await completes")
        #expect(viewModel.exportFlowSheet != nil)
    }

    @Test("triggerExport ignores re-entrant calls while the async factory is still preparing")
    func triggerExportIgnoresReentrantCallWhilePreparing() async {
        let store = makeSessionWith()
        store.setSelectedPatient(id: OpaqueClinikoID(99))
        store.setDraftNotes(StructuredNotes(subjective: "s"))

        let exporter = TreatmentNoteExporter(
            client: ClinikoClient(
                credentials: try! ClinikoCredentials(apiKey: "MS-test-au1", shard: .au1),
                session: URLSession.shared
            ),
            auditStore: InMemoryAuditStore(),
            manipulations: stubManipulations()
        )

        // The factory issues a re-entrant `triggerExport` call from
        // INSIDE its own await. Because we're suspended inside the
        // factory, `isPreparingExport` is still true on the VM, so
        // the re-entry guard (`guard !isPreparingExport`) must
        // short-circuit and the factory body must be invoked
        // exactly once.
        var factoryCallCount = 0
        var capturedViewModel: ReviewViewModel?
        let factory: () async -> ExportFlowViewModel? = {
            factoryCallCount += 1
            // Issue the re-entrant call from the awaited path. If
            // the guard is missing, this would stack a second
            // factory invocation and bump factoryCallCount to 2.
            await capturedViewModel?.triggerExport()
            return ExportFlowViewModel(
                sessionStore: store,
                dependencies: ExportFlowDependencies(
                    exporter: exporter,
                    manipulations: stubManipulationsRepo(),
                    onSuccess: {},
                    openClinikoSettings: {},
                    copyToClipboard: { _ in }
                )
            )
        }
        let viewModel = ReviewViewModel(
            sessionStore: store,
            manipulations: stubManipulations(),
            makeExportFlowViewModel: factory
        )
        capturedViewModel = viewModel

        await viewModel.triggerExport()

        #expect(factoryCallCount == 1, "Re-entrant tap should hit the guard, not stack a second factory call")
        #expect(viewModel.exportFlowSheet != nil)
    }

    // MARK: - cancelReview

    @Test("cancelReview clears SessionStore and posts .reviewScreenDidDismiss")
    func cancelReviewClearsAndDismisses() async {
        let store = makeSessionWith()
        let viewModel = ReviewViewModel(sessionStore: store, manipulations: stubManipulations())

        var receivedDismiss = false
        let observer = NotificationCenter.default.addObserver(
            forName: .reviewScreenDidDismiss,
            object: viewModel,
            queue: .main
        ) { _ in receivedDismiss = true }
        defer { NotificationCenter.default.removeObserver(observer) }

        viewModel.cancelReview()

        await Task.yield()
        await Task.yield()
        #expect(store.active == nil)
        #expect(receivedDismiss)
    }

    // MARK: - Sheet / drawer toggles

    @Test("presentRawTranscript opens only when a transcript is present")
    func presentRawTranscriptGuardsEmpty() {
        let storeWithText = makeSessionWith(transcript: "Hello.")
        let viewModelWithText = ReviewViewModel(sessionStore: storeWithText, manipulations: stubManipulations())
        viewModelWithText.presentRawTranscript()
        #expect(viewModelWithText.isRawTranscriptSheetOpen)

        let storeNoSession = SessionStore()
        let viewModelNoSession = ReviewViewModel(sessionStore: storeNoSession, manipulations: stubManipulations())
        viewModelNoSession.presentRawTranscript()
        #expect(!viewModelNoSession.isRawTranscriptSheetOpen)
    }

    @Test("toggleExcludedDrawer flips state")
    func toggleExcludedDrawer() {
        let store = makeSessionWith()
        let viewModel = ReviewViewModel(sessionStore: store, manipulations: stubManipulations())
        #expect(viewModel.isExcludedDrawerOpen)
        viewModel.toggleExcludedDrawer()
        #expect(!viewModel.isExcludedDrawerOpen)
        viewModel.toggleExcludedDrawer()
        #expect(viewModel.isExcludedDrawerOpen)
    }

    // MARK: - loadState transitions (#100)

    /// Bug #100. The screen must distinguish "LLM still running" from
    /// "LLM produced an empty draft" — both rendered identically pre-
    /// fix (four blank `TextEditor`s). `loadState` is the signal the
    /// view binds to.
    @Test("loadState reflects SessionStore.draftStatus across pending → ready → fallback transitions")
    func loadStateTracksDraftStatus() {
        let store = makeSessionWith(notes: nil, status: .pending)
        let viewModel = ReviewViewModel(sessionStore: store, manipulations: stubManipulations())

        #expect(viewModel.loadState == .pending)
        #expect(viewModel.isLoadingDraft)
        #expect(!viewModel.isFallback)
        #expect(viewModel.fallbackReasonCode == nil)

        // Production-shaped success path: AppState writes the notes
        // first, then flips status to .ready (so an observer that
        // reads status doesn't see ".ready" paired with a still-nil
        // draft).
        store.setDraftNotes(StructuredNotes(subjective: "Pt reports neck pain"))
        store.setDraftStatus(.ready)
        #expect(viewModel.loadState == .ready)
        #expect(!viewModel.isLoadingDraft)
        #expect(!viewModel.isFallback)

        // Fallback path: AppState seeds an empty draft + flips status
        // to .fallback so the editors stay interactive.
        store.setDraftNotes(StructuredNotes())
        store.setDraftStatus(.fallback(reasonCode: "model_unavailable"))
        #expect(viewModel.loadState == .fallback(reasonCode: "model_unavailable"))
        #expect(!viewModel.isLoadingDraft)
        #expect(viewModel.isFallback)
        #expect(viewModel.fallbackReasonCode == "model_unavailable")
    }

    /// `loadState` defaults to `.fallback(reasonCode: "session_expired")`
    /// when there is no active session — covers the
    /// `SessionStore.checkIdleTimeout()` race where `active` is
    /// cleared while the Review window is still on screen. Defaulting
    /// to `.ready` would silently render the cleared session as a
    /// successful steady state (silent-failure-hunter H3 on bug #100).
    @Test("loadState defaults to .fallback(session_expired) when no session is active")
    func loadStateDefaultsToSessionExpiredWithoutSession() {
        let store = SessionStore()
        let viewModel = ReviewViewModel(sessionStore: store, manipulations: stubManipulations())

        #expect(viewModel.loadState == .fallback(
            reasonCode: ClinicalNotesProcessor.reasonSessionExpired
        ))
        #expect(!viewModel.isLoadingDraft)
        #expect(viewModel.isFallback)
        #expect(viewModel.fallbackReasonCode == ClinicalNotesProcessor.reasonSessionExpired)
    }

    // MARK: - insertRawTranscriptIntoSubjective (#100)

    @Test("insertRawTranscriptIntoSubjective seeds Subjective from the raw transcript")
    func insertRawTranscriptIntoEmptySubjective() {
        let store = makeSessionWith(
            transcript: "Patient reports lower back pain since Tuesday.",
            notes: StructuredNotes(),
            status: .fallback(reasonCode: "model_unavailable")
        )
        let viewModel = ReviewViewModel(sessionStore: store, manipulations: stubManipulations())

        viewModel.insertRawTranscriptIntoSubjective()

        #expect(store.active?.draftNotes?.subjective == "Patient reports lower back pain since Tuesday.")
        #expect(store.active?.draftNotes?.objective == "")
    }

    @Test("insertRawTranscriptIntoSubjective appends with a blank-line separator when Subjective is non-empty")
    func insertRawTranscriptAppendsToExistingSubjective() {
        var notes = StructuredNotes()
        notes.subjective = "Pre-existing edit."
        let store = makeSessionWith(
            transcript: "Patient reports neck pain.",
            notes: notes,
            status: .fallback(reasonCode: "invalid_json_after_retry")
        )
        let viewModel = ReviewViewModel(sessionStore: store, manipulations: stubManipulations())

        viewModel.insertRawTranscriptIntoSubjective()

        #expect(store.active?.draftNotes?.subjective == "Pre-existing edit.\n\nPatient reports neck pain.")
    }

    @Test("insertRawTranscriptIntoSubjective is a no-op when the transcript is empty")
    func insertRawTranscriptNoOpEmptyTranscript() {
        let store = makeSessionWith(
            transcript: "",
            notes: StructuredNotes(),
            status: .fallback(reasonCode: "model_unavailable")
        )
        let viewModel = ReviewViewModel(sessionStore: store, manipulations: stubManipulations())

        viewModel.insertRawTranscriptIntoSubjective()

        #expect(store.active?.draftNotes?.subjective == "")
    }

    @Test("insertRawTranscriptIntoSubjective without an active session surfaces a banner and does not mutate")
    func insertRawTranscriptSurfacesBannerWithoutSession() {
        let store = SessionStore()
        let viewModel = ReviewViewModel(sessionStore: store, manipulations: stubManipulations())

        viewModel.insertRawTranscriptIntoSubjective()

        #expect(store.active == nil)
        #expect(viewModel.errorMessage != nil)
    }
}
