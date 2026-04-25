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
