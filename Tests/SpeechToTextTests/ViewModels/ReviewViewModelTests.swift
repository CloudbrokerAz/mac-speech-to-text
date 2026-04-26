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
        notes: StructuredNotes? = StructuredNotes()
    ) -> SessionStore {
        let store = SessionStore()
        var recording = RecordingSession(language: "en", state: .completed)
        recording.transcribedText = transcript
        store.start(from: recording)
        if let notes {
            store.setDraftNotes(notes)
        }
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

        viewModel.triggerExport()

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
        let factory: () -> ExportFlowViewModel? = {
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

        viewModel.triggerExport()

        #expect(viewModel.exportFlowSheet != nil)
        #expect(viewModel.errorMessage == nil)
    }

    @Test("triggerExport with a patient but no factory surfaces a 'Cliniko not set up' banner")
    func triggerExportWithoutFactorySurfacesBanner() async {
        let store = makeSessionWith()
        store.setSelectedPatient(id: OpaqueClinikoID(99))

        // Default factory closure returns nil.
        let viewModel = ReviewViewModel(sessionStore: store, manipulations: stubManipulations())

        viewModel.triggerExport()

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
        let factory: () -> ExportFlowViewModel? = {
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

        viewModel.triggerExport()
        #expect(viewModel.exportFlowSheet != nil)

        viewModel.dismissExportFlow()
        #expect(viewModel.exportFlowSheet == nil)
    }

    private func stubManipulationsRepo() -> ManipulationsRepository { stubManipulations() }

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
}
