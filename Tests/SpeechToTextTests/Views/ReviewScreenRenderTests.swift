// ReviewScreenRenderTests.swift
// macOS Local Speech-to-Text Application
//
// ViewInspector + crash-detection tests for `ReviewScreen` (#13) and its
// sub-views: SOAPSectionEditor, ManipulationsChecklist,
// ExcludedContentDrawer, RawTranscriptSheet.
//
// Catches the @Observable + actor-existential crash pattern documented in
// `.claude/references/concurrency.md` §1, plus body-evaluation crashes
// that only surface at runtime. Each test instantiates a fresh
// `ReviewViewModel` with a real `SessionStore` + a tiny stub
// `ManipulationsRepository` — no network, no Keychain, no LLM.

import SwiftUI
import ViewInspector
import XCTest
@testable import SpeechToText

extension ReviewScreen: Inspectable {}
extension SOAPSectionEditor: Inspectable {}
extension ManipulationsChecklist: Inspectable {}
extension ExcludedContentDrawer: Inspectable {}
extension RawTranscriptSheet: Inspectable {}

@MainActor
final class ReviewScreenRenderTests: XCTestCase {

    // MARK: - Helpers

    private func makeStubManipulations() -> ManipulationsRepository {
        ManipulationsRepository(all: [
            Manipulation(id: "diversified_hvla", displayName: "Diversified HVLA", clinikoCode: nil),
            Manipulation(id: "activator", displayName: "Activator", clinikoCode: nil),
            Manipulation(id: "thompson", displayName: "Thompson", clinikoCode: nil)
        ])
    }

    private func makeViewModel(populated: Bool = false) -> ReviewViewModel {
        let store = SessionStore()
        if populated {
            var recording = RecordingSession(language: "en", state: .completed)
            recording.transcribedText = "Patient reports R-neck pain x 3/52."
            store.start(from: recording)
            var notes = StructuredNotes()
            notes.subjective = "Pt reports R-neck pain x 3/52."
            notes.excluded = ["Weather chat at start.", "Brief parking discussion."]
            store.setDraftNotes(notes)
            // `start(from:)` defaults `draftStatus` to `.pending`; the
            // populated fixture represents the post-LLM steady state, so
            // flip to `.ready` so the SOAP column renders the edit
            // surface rather than the pending overlay.
            store.setDraftStatus(.ready)
        }
        return ReviewViewModel(
            sessionStore: store,
            manipulations: makeStubManipulations()
        )
    }

    /// Build a view model in `.pending` or `.fallback` load state for
    /// the #100 render-no-crash coverage. Mirrors the production
    /// shape: pending = no draft yet; fallback = empty seed draft so
    /// the editors are interactive.
    private func makeViewModel(loadState: ClinicalNotesDraftStatus) -> ReviewViewModel {
        let store = SessionStore()
        var recording = RecordingSession(language: "en", state: .completed)
        recording.transcribedText = "Patient reports lower back pain."
        store.start(from: recording)
        switch loadState {
        case .pending:
            // No draft, status stays at the start(from:) default.
            break
        case .ready:
            store.setDraftNotes(StructuredNotes(subjective: "Pt reports lower back pain."))
            store.setDraftStatus(.ready)
        case .fallback(let reasonCode):
            store.setDraftNotes(StructuredNotes())
            store.setDraftStatus(.fallback(reasonCode: reasonCode))
        }
        return ReviewViewModel(
            sessionStore: store,
            manipulations: makeStubManipulations()
        )
    }

    // MARK: - ReviewScreen: instantiation

    func test_reviewScreen_instantiatesWithoutCrash() {
        let viewModel = makeViewModel()
        let screen = ReviewScreen(viewModel: viewModel)
        XCTAssertNotNil(screen)
    }

    func test_reviewScreen_bodyAccessDoesNotCrash() {
        let viewModel = makeViewModel()
        let screen = ReviewScreen(viewModel: viewModel)
        let body = screen.body
        XCTAssertNotNil(body)
    }

    /// Mirror of `RecordingModalRenderTests.test_recordingModal_externalViewModelCreation_noCrash`
    /// — VM constructed BEFORE view, then handed in. Verifies the
    /// actor-existential mitigation pattern from `.claude/references/concurrency.md` §1.
    func test_reviewScreen_externalViewModelCreation_noCrash() {
        let viewModel = makeViewModel()
        XCTAssertTrue(viewModel.isExcludedDrawerOpen) // drawer defaults open
        let screen = ReviewScreen(viewModel: viewModel)
        let body = screen.body
        XCTAssertNotNil(body)
    }

    /// Populated session — exercises the `excludedEntries` / draft-notes
    /// rendering paths that an empty session would skip.
    func test_reviewScreen_populated_bodyAccessDoesNotCrash() {
        let viewModel = makeViewModel(populated: true)
        let screen = ReviewScreen(viewModel: viewModel)
        let body = screen.body
        XCTAssertNotNil(body)
    }

    func test_reviewScreen_exposesAccessibilityIdentifier() throws {
        let viewModel = makeViewModel(populated: true)
        let screen = ReviewScreen(viewModel: viewModel)
        let inspected = try screen.inspect()
        XCTAssertNoThrow(try inspected.find(viewWithAccessibilityIdentifier: "reviewScreen"))
    }

    // MARK: - #100 load-state render coverage

    /// Pending state renders without crashing — the SOAP column gets
    /// a `.ultraThinMaterial` overlay with a `ProgressView` while the
    /// LLM is still running.
    func test_reviewScreen_pendingLoadState_bodyAccessDoesNotCrash() {
        let viewModel = makeViewModel(loadState: .pending)
        let screen = ReviewScreen(viewModel: viewModel)
        let body = screen.body
        XCTAssertNotNil(body)
        XCTAssertTrue(viewModel.isLoadingDraft)
    }

    func test_reviewScreen_pendingLoadState_exposesPendingOverlayIdentifier() throws {
        let viewModel = makeViewModel(loadState: .pending)
        let screen = ReviewScreen(viewModel: viewModel)
        let inspected = try screen.inspect()
        XCTAssertNoThrow(try inspected.find(viewWithAccessibilityIdentifier: "reviewScreen.soapColumn.pendingOverlay"))
    }

    /// Fallback state renders without crashing and exposes the
    /// "Insert raw transcript" affordance — the load-bearing UX for
    /// bug #100's "doctor stares at blank fields" scenario.
    func test_reviewScreen_fallbackLoadState_bodyAccessDoesNotCrash() {
        let viewModel = makeViewModel(loadState: .fallback(reasonCode: "model_unavailable"))
        let screen = ReviewScreen(viewModel: viewModel)
        let body = screen.body
        XCTAssertNotNil(body)
        XCTAssertTrue(viewModel.isFallback)
        XCTAssertEqual(viewModel.fallbackReasonCode, "model_unavailable")
    }

    func test_reviewScreen_fallbackLoadState_exposesInsertTranscriptIdentifier() throws {
        let viewModel = makeViewModel(loadState: .fallback(reasonCode: "all_soap_empty_after_retry"))
        let screen = ReviewScreen(viewModel: viewModel)
        let inspected = try screen.inspect()
        XCTAssertNoThrow(try inspected.find(viewWithAccessibilityIdentifier: "reviewScreen.fallbackBanner"))
        XCTAssertNoThrow(try inspected.find(viewWithAccessibilityIdentifier: "reviewScreen.fallback.insertRawTranscript"))
    }

    // MARK: - SOAPSectionEditor

    func test_soapSectionEditor_instantiatesWithoutCrash() {
        struct Host: View {
            @State var text = "Pt reports R-neck pain."
            @FocusState var focused: SOAPField?

            var body: some View {
                SOAPSectionEditor(
                    field: .subjective,
                    text: $text,
                    focusBinding: $focused,
                    onFocus: {}
                )
            }
        }

        let host = Host()
        XCTAssertNotNil(host.body)
    }

    // MARK: - ManipulationsChecklist

    func test_manipulationsChecklist_instantiatesWithoutCrash() {
        let viewModel = makeViewModel(populated: true)
        let view = ManipulationsChecklist(viewModel: viewModel)
        XCTAssertNotNil(view.body)
    }

    func test_manipulationsChecklist_emptyTaxonomy_doesNotCrash() {
        // Defensive: AppState falls back to an empty repository on
        // bundle-load failure (`assertionFailure` in DEBUG, empty in
        // RELEASE). The checklist must render without crashing.
        let store = SessionStore()
        let viewModel = ReviewViewModel(
            sessionStore: store,
            manipulations: ManipulationsRepository(all: [])
        )
        let view = ManipulationsChecklist(viewModel: viewModel)
        XCTAssertNotNil(view.body)
    }

    // MARK: - ExcludedContentDrawer

    func test_excludedContentDrawer_instantiatesWithoutCrash() {
        let viewModel = makeViewModel(populated: true)
        let view = ExcludedContentDrawer(viewModel: viewModel)
        XCTAssertNotNil(view.body)
    }

    func test_excludedContentDrawer_empty_doesNotCrash() {
        let viewModel = makeViewModel() // no draft → no excluded entries
        let view = ExcludedContentDrawer(viewModel: viewModel)
        XCTAssertNotNil(view.body)
    }

    // MARK: - RawTranscriptSheet

    func test_rawTranscriptSheet_instantiatesWithoutCrash() {
        let view = RawTranscriptSheet(transcript: "Hello world.", onDismiss: {})
        XCTAssertNotNil(view.body)
    }

    func test_rawTranscriptSheet_emptyTranscript_doesNotCrash() {
        let view = RawTranscriptSheet(transcript: "", onDismiss: {})
        XCTAssertNotNil(view.body)
    }
}
