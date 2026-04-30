import SwiftUI
import ViewInspector
import XCTest
@testable import SpeechToText

/// Render-crash + state-affordance tests for `ClinicalNotesModelStatusRow`
/// (#104, Deliverable A). Each case constructs a fresh
/// `ClinicalNotesModelStatusViewModel` with a hand-built state, mounts the
/// row, and asserts the expected accessibility identifiers are reachable.
/// No production wiring (downloader, file system) is involved — the VM's
/// no-op-closure test convenience init keeps these tests pure.
@MainActor
final class ClinicalNotesModelStatusRowTests: XCTestCase {

    // 5.25 GB — the manifest size we expect to surface in the row's header.
    // Tests don't depend on the exact value but using a realistic one keeps
    // the formatted string assertions plausible.
    private static let sampleManifestBytes: Int64 = 5_250_000_000

    private func makeViewModel(
        state: LLMDownloadState,
        progress: Double = 0,
        modelDirectoryURL: URL? = nil,
        isPipelineActive: Bool = false
    ) -> ClinicalNotesModelStatusViewModel {
        ClinicalNotesModelStatusViewModel(
            state: state,
            progress: progress,
            manifestSizeBytes: Self.sampleManifestBytes,
            modelDirectoryURL: modelDirectoryURL,
            isPipelineActive: isPipelineActive
        )
    }

    // MARK: - Render-crash test

    func test_modelStatusRow_instantiatesWithoutCrash() {
        let viewModel = makeViewModel(state: .idle)
        let view = ClinicalNotesModelStatusRow(viewModel: viewModel)
        XCTAssertNotNil(view)
    }

    // MARK: - Idle

    func test_idleState_showsDownloadButton() throws {
        let viewModel = makeViewModel(state: .idle)
        let view = ClinicalNotesModelStatusRow(viewModel: viewModel)
        XCTAssertNoThrow(
            try view.inspect().find(viewWithAccessibilityIdentifier: "clinicalNotesModelStatusRow.statePill")
        )
        XCTAssertNoThrow(
            try view.inspect().find(viewWithAccessibilityIdentifier: "clinicalNotesModelStatusRow.actionButton")
        )
        // No progress bar when idle.
        XCTAssertThrowsError(
            try view.inspect().find(viewWithAccessibilityIdentifier: "clinicalNotesModelStatusRow.progressBar"),
            "Progress bar must be hidden when not downloading"
        )
        // No disk-usage row when idle (model not on disk).
        XCTAssertThrowsError(
            try view.inspect().find(viewWithAccessibilityIdentifier: "clinicalNotesModelStatusRow.diskUsageRow"),
            "Disk-usage row only shows in .ready"
        )
    }

    // MARK: - Downloading

    func test_downloadingState_showsProgressBarAndCancel() throws {
        let viewModel = makeViewModel(state: .downloading, progress: 0.42)
        let view = ClinicalNotesModelStatusRow(viewModel: viewModel)
        XCTAssertNoThrow(
            try view.inspect().find(viewWithAccessibilityIdentifier: "clinicalNotesModelStatusRow.progressBar")
        )
        XCTAssertNoThrow(
            try view.inspect().find(viewWithAccessibilityIdentifier: "clinicalNotesModelStatusRow.actionButton")
        )
        // No disk-usage row mid-download.
        XCTAssertThrowsError(
            try view.inspect().find(viewWithAccessibilityIdentifier: "clinicalNotesModelStatusRow.diskUsageRow")
        )
    }

    // MARK: - Verifying (post-download warmup)

    func test_verifyingState_showsCancel() throws {
        let dir = URL(fileURLWithPath: "/tmp/test/gemma-4-e4b-it-4bit")
        let viewModel = makeViewModel(state: .verified(directory: dir), progress: 1)
        let view = ClinicalNotesModelStatusRow(viewModel: viewModel)
        XCTAssertNoThrow(
            try view.inspect().find(viewWithAccessibilityIdentifier: "clinicalNotesModelStatusRow.statePill")
        )
        // The action button is "Cancel" in `.verified` state.
        XCTAssertNoThrow(
            try view.inspect().find(viewWithAccessibilityIdentifier: "clinicalNotesModelStatusRow.actionButton")
        )
        // Progress bar hidden — verifying is post-download.
        XCTAssertThrowsError(
            try view.inspect().find(viewWithAccessibilityIdentifier: "clinicalNotesModelStatusRow.progressBar")
        )
    }

    // MARK: - Ready

    func test_readyState_showsRemoveAndReDownload_andDiskUsageRow() throws {
        let dir = URL(fileURLWithPath: "/tmp/test/gemma-4-e4b-it-4bit")
        let viewModel = makeViewModel(state: .ready, progress: 1, modelDirectoryURL: dir)
        let view = ClinicalNotesModelStatusRow(viewModel: viewModel)

        // Remove + redownload buttons.
        XCTAssertNoThrow(
            try view.inspect().find(viewWithAccessibilityIdentifier: "clinicalNotesModelStatusRow.actionButton"),
            "Remove button must be present in .ready"
        )
        XCTAssertNoThrow(
            try view.inspect().find(viewWithAccessibilityIdentifier: "clinicalNotesModelStatusRow.redownloadButton"),
            "Re-download button must be present in .ready"
        )
        // Disk-usage row visible only in .ready.
        XCTAssertNoThrow(
            try view.inspect().find(viewWithAccessibilityIdentifier: "clinicalNotesModelStatusRow.diskUsageRow")
        )
        // Progress bar hidden in .ready.
        XCTAssertThrowsError(
            try view.inspect().find(viewWithAccessibilityIdentifier: "clinicalNotesModelStatusRow.progressBar")
        )
    }

    /// **#121 — Remove + Re-download disabled while pipeline active.**
    /// When `isPipelineActive` is `true` the Settings row gates the
    /// destructive actions so the user can't trip the post-cancel
    /// fallback banner unnecessarily. The drain inside
    /// `AppState.removeClinicalNotesModel()` is the load-bearing
    /// correctness mechanism (cancels + awaits the pipeline before
    /// `unload()`); this UI gate is the polite UX layer on top.
    ///
    /// Both buttons stay reachable in the view tree (so tests using
    /// the existing accessibility identifiers don't have to learn a
    /// new locator), but `.disabled(...)` flips to `true`. The helper
    /// caption is mounted under a new identifier
    /// `clinicalNotesModelStatusRow.pipelineActiveCaption`.
    func test_readyState_pipelineActive_disablesRemoveAndShowsCaption() throws {
        let dir = URL(fileURLWithPath: "/tmp/test/gemma-4-e4b-it-4bit")
        let viewModel = makeViewModel(
            state: .ready,
            progress: 1,
            modelDirectoryURL: dir,
            isPipelineActive: true
        )
        let view = ClinicalNotesModelStatusRow(viewModel: viewModel)

        let removeButton = try view.inspect()
            .find(viewWithAccessibilityIdentifier: "clinicalNotesModelStatusRow.actionButton")
        XCTAssertTrue(
            try removeButton.isDisabled(),
            "Remove button must be disabled while a clinical-notes pipeline is in flight"
        )

        let redownloadButton = try view.inspect()
            .find(viewWithAccessibilityIdentifier: "clinicalNotesModelStatusRow.redownloadButton")
        XCTAssertTrue(
            try redownloadButton.isDisabled(),
            "Re-download must also be disabled while pipeline active (it routes through the same Remove path)"
        )

        XCTAssertNoThrow(
            try view.inspect()
                .find(viewWithAccessibilityIdentifier: "clinicalNotesModelStatusRow.pipelineActiveCaption"),
            "Caption explaining why Remove is disabled must be visible while pipeline active"
        )
    }

    /// Symmetric assertion: when `isPipelineActive == false` the caption
    /// is absent and the buttons are enabled. Pins down that the gate
    /// only activates under the documented condition — protects against
    /// a regression that flips the gate unconditionally.
    func test_readyState_pipelineIdle_enablesRemoveAndHidesCaption() throws {
        let dir = URL(fileURLWithPath: "/tmp/test/gemma-4-e4b-it-4bit")
        let viewModel = makeViewModel(
            state: .ready,
            progress: 1,
            modelDirectoryURL: dir,
            isPipelineActive: false
        )
        let view = ClinicalNotesModelStatusRow(viewModel: viewModel)

        let removeButton = try view.inspect()
            .find(viewWithAccessibilityIdentifier: "clinicalNotesModelStatusRow.actionButton")
        XCTAssertFalse(try removeButton.isDisabled())

        let redownloadButton = try view.inspect()
            .find(viewWithAccessibilityIdentifier: "clinicalNotesModelStatusRow.redownloadButton")
        XCTAssertFalse(try redownloadButton.isDisabled())

        XCTAssertThrowsError(
            try view.inspect()
                .find(viewWithAccessibilityIdentifier: "clinicalNotesModelStatusRow.pipelineActiveCaption"),
            "Caption must be hidden when no pipeline is in flight"
        )
    }

    // MARK: - Failed

    func test_failedState_showsRetry() throws {
        let viewModel = makeViewModel(state: .failed)
        let view = ClinicalNotesModelStatusRow(viewModel: viewModel)
        XCTAssertNoThrow(
            try view.inspect().find(viewWithAccessibilityIdentifier: "clinicalNotesModelStatusRow.statePill")
        )
        XCTAssertNoThrow(
            try view.inspect().find(viewWithAccessibilityIdentifier: "clinicalNotesModelStatusRow.actionButton"),
            "Retry button must be present in .failed"
        )
    }

    // MARK: - Cancelled

    func test_cancelledState_showsDownloadButton() throws {
        let viewModel = makeViewModel(state: .cancelled)
        let view = ClinicalNotesModelStatusRow(viewModel: viewModel)
        XCTAssertNoThrow(
            try view.inspect().find(viewWithAccessibilityIdentifier: "clinicalNotesModelStatusRow.statePill")
        )
        XCTAssertNoThrow(
            try view.inspect().find(viewWithAccessibilityIdentifier: "clinicalNotesModelStatusRow.actionButton"),
            "Download button must be present in .cancelled (cancelled is recoverable)"
        )
    }
}
