// ReviewScreenSnapshotTests.swift
// macOS Local Speech-to-Text Application
//
// Image-snapshot regression tests for `ReviewScreen` (#13). ReviewScreen
// is the doctor's primary edit surface for an LLM-drafted clinical note
// — the two-column layout (SOAP editor left, manipulations + excluded
// drawer right), action bar, and patient chip are wireframe-locked.
//
// The snapshot tests pin the visual contract that ViewInspector cannot
// observe (typography, spacing, column widths, ScrollView presence
// under overflow). Crash detection + accessibility identifiers stay in
// `ReviewScreenRenderTests`.
//
// **CI carve-out.** This class is in the by-name skip list in
// `.github/workflows/ci.yml` for the same reason as
// `SafetyDisclaimerSnapshotTests` — see that file's header and
// `Tests/SpeechToTextTests/Snapshots/README.md`.
//
// **Test data is synthetic, not PHI.** The fixtures here use
// generic clinical-style filler and never reference a real patient,
// chart, or transcript.

import SnapshotTesting
import SwiftUI
import XCTest
@testable import SpeechToText

/// Image snapshots for the ReviewScreen across three load states:
///   - empty: no draft yet; the screen prompts to compose from the raw
///     transcript.
///   - typical: a populated draft with three excluded snippets and a
///     two-manipulation selection — the canonical doctor-facing layout.
///   - overflow-y-long: a draft long enough to force the SOAP column's
///     `ScrollView` to scroll. Pins the column-width vs scroll-bar
///     interaction so a refactor that swaps the ScrollView for a
///     fixed-height container is caught.
///
/// **Window size.** `ReviewScreen` declares `.frame(minWidth: 880,
/// minHeight: 560)`. The snapshot host uses `1100×720` to match the
/// `#Preview` block's frame and give the right column its full 280-pt
/// width plus comfortable left-column reading width.
@MainActor
final class ReviewScreenSnapshotTests: XCTestCase {

    /// Wireframe-locked render size for ReviewScreen snapshots. Mirrors
    /// the `#Preview` in `ReviewScreen.swift` so the goldens align with
    /// the design reference.
    private static let surfaceSize = CGSize(width: 1100, height: 720)

    // MARK: - Fixtures

    /// Manipulation taxonomy used by every test in this class. Keeps
    /// the right-pane checklist deterministic — adding entries to the
    /// real bundled `Manipulations.json` would otherwise re-shuffle the
    /// snapshot. Five entries match the `#Preview` block exactly.
    private static let snapshotManipulations = ManipulationsRepository(all: [
        Manipulation(id: "diversified_hvla", displayName: "Diversified HVLA", clinikoCode: nil),
        Manipulation(id: "gonstead", displayName: "Gonstead", clinikoCode: nil),
        Manipulation(id: "activator", displayName: "Activator", clinikoCode: nil),
        Manipulation(id: "thompson", displayName: "Thompson", clinikoCode: nil),
        Manipulation(id: "sot", displayName: "SOT", clinikoCode: nil)
    ])

    /// Build a `ReviewViewModel` backed by a `SessionStore` populated
    /// with `notes` (or no draft if `notes` is `nil`) and `transcript`.
    /// All synthetic data — no PHI.
    private func makeViewModel(
        notes: StructuredNotes?,
        transcript: String
    ) -> ReviewViewModel {
        let store = SessionStore()
        var recording = RecordingSession(language: "en", state: .completed)
        recording.transcribedText = transcript
        store.start(from: recording)
        if let notes {
            store.setDraftNotes(notes)
        }
        return ReviewViewModel(
            sessionStore: store,
            manipulations: Self.snapshotManipulations
        )
    }

    // MARK: - Snapshots

    /// Empty draft: no `StructuredNotes`, the screen surfaces the
    /// "compose from raw transcript" subtitle and disabled Export
    /// button. Verifies the empty-state header + chip variant.
    func test_reviewScreen_empty() {
        let viewModel = makeViewModel(
            notes: nil,
            transcript: "Brief synthetic transcript for the empty-state snapshot."
        )
        let hosting = SnapshotHost.hosting(
            ReviewScreen(viewModel: viewModel),
            size: Self.surfaceSize,
            appearance: .light
        )
        assertSnapshot(of: hosting, as: .image)
    }

    /// Typical doctor-facing render: short SOAP fields, two
    /// manipulations selected, three excluded snippets. Mirrors the
    /// shape of the `#Preview` block in `ReviewScreen.swift`.
    func test_reviewScreen_typical() {
        let notes = StructuredNotes(
            subjective: "Synthetic complaint: right-sided neck stiffness three weeks, worse with rotation.",
            objective: "Cervical screening unremarkable. C5/C6 segmental restriction, hypertonic right upper trapezius.",
            assessment: "Mechanical cervical dysfunction, no red flags.",
            plan: "Diversified HVLA C5–C6, Activator T2–T4. Reassess on follow-up visit.",
            selectedManipulationIDs: ["diversified_hvla", "activator"],
            excluded: [
                "Brief weather chat at start of consult.",
                "Patient mentioned weekend plans.",
                "Off-topic anecdote about a prior provider."
            ]
        )
        let viewModel = makeViewModel(
            notes: notes,
            transcript: "Synthetic consult transcript covering the above scenario."
        )
        let hosting = SnapshotHost.hosting(
            ReviewScreen(viewModel: viewModel),
            size: Self.surfaceSize,
            appearance: .light
        )
        assertSnapshot(of: hosting, as: .image)
    }

    /// Overflow render: very long SOAP fields force the left-column
    /// `ScrollView` into a scroll state, and the excluded drawer fills
    /// vertically. Pins the column-width / scroll-bar interaction so a
    /// refactor that drops the ScrollView (or changes its content
    /// inset) is caught.
    func test_reviewScreen_overflowYLong() {
        let longParagraph = String(
            repeating: "Synthetic verbose SOAP narrative line. ",
            count: 24
        )
        let notes = StructuredNotes(
            subjective: longParagraph,
            objective: longParagraph,
            assessment: longParagraph,
            plan: longParagraph,
            selectedManipulationIDs: ["diversified_hvla"],
            excluded: (0..<6).map { "Excluded snippet #\($0) — synthetic filler for the overflow snapshot." }
        )
        let viewModel = makeViewModel(
            notes: notes,
            transcript: "Synthetic consult transcript — overflow scenario."
        )
        let hosting = SnapshotHost.hosting(
            ReviewScreen(viewModel: viewModel),
            size: Self.surfaceSize,
            appearance: .light
        )
        assertSnapshot(of: hosting, as: .image)
    }
}
