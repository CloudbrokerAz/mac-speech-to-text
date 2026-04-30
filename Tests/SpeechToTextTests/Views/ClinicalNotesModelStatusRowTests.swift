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
        modelDirectoryURL: URL? = nil
    ) -> ClinicalNotesModelStatusViewModel {
        ClinicalNotesModelStatusViewModel(
            state: state,
            progress: progress,
            manifestSizeBytes: Self.sampleManifestBytes,
            modelDirectoryURL: modelDirectoryURL
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
