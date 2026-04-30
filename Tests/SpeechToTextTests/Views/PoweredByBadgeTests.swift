import SwiftUI
import ViewInspector
import XCTest
@testable import SpeechToText

/// Render + state-pill tests for the `PoweredByBadge` component embedded in
/// `AboutSection` (#104, Deliverable B). The badge itself is `fileprivate`,
/// so these tests exercise it indirectly through the public `AboutSection`
/// surface — instantiating the section with / without a
/// `ClinicalNotesModelStatusViewModel`, then inspecting the published
/// accessibility identifiers.
///
/// PHI-free by construction — the VM only carries model bytes, directory,
/// and download state. No transcript / patient data flows through the
/// badge.
@MainActor
final class PoweredByBadgeTests: XCTestCase {

    // Realistic Gemma 4 manifest size — keeps the subtitle copy plausible.
    private static let sampleManifestBytes: Int64 = 5_249_808_308

    // MARK: - Helpers

    private func makeAbout(
        modelStatusViewModel: ClinicalNotesModelStatusViewModel? = nil
    ) -> AboutSection {
        AboutSection(
            viewModel: AboutSectionViewModel(),
            modelStatusViewModel: modelStatusViewModel
        )
    }

    private func makeVM(
        state: LLMDownloadState,
        progress: Double = 0
    ) -> ClinicalNotesModelStatusViewModel {
        ClinicalNotesModelStatusViewModel(
            state: state,
            progress: progress,
            manifestSizeBytes: Self.sampleManifestBytes
        )
    }

    /// All six `LLMDownloadState` variants — kept as a fixture so the
    /// "Parakeet has no pill" exhaustiveness test doesn't drift if the
    /// enum ever grows a case.
    private func allStates() -> [LLMDownloadState] {
        [
            .idle,
            .downloading,
            .verified(directory: URL(fileURLWithPath: "/tmp/test/gemma-4")),
            .ready,
            .failed,
            .cancelled
        ]
    }

    // MARK: - Without VM: Parakeet only

    func test_aboutSection_withoutVM_rendersOnlyParakeet() throws {
        let view = makeAbout()
        let inspected = try view.inspect()

        XCTAssertNoThrow(
            try inspected.find(viewWithAccessibilityIdentifier: "aboutSection.poweredByBadge.nvidia-parakeet-tdt"),
            "Parakeet badge must always render"
        )
        XCTAssertThrowsError(
            try inspected.find(viewWithAccessibilityIdentifier: "aboutSection.poweredByBadge.gemma-4-e4b-it"),
            "Gemma 4 badge must be hidden when no model-status VM is supplied"
        )
    }

    // MARK: - With VM: state-pill copy per state

    func test_aboutSection_withVMReady_rendersGemmaBadgeAndReadyPill() throws {
        let viewModel = makeVM(state: .ready, progress: 1)
        let view = makeAbout(modelStatusViewModel: viewModel)
        let inspected = try view.inspect()

        XCTAssertNoThrow(
            try inspected.find(viewWithAccessibilityIdentifier: "aboutSection.poweredByBadge.gemma-4-e4b-it"),
            "Gemma 4 badge must render when VM is supplied"
        )
        let pill = try inspected.find(
            viewWithAccessibilityIdentifier: "aboutSection.poweredByBadge.gemma-4-e4b-it.statePill"
        )
        let pillText = try pill.text().string()
        XCTAssertTrue(
            pillText.contains("Ready"),
            "State pill in .ready must read 'Ready'. Got: \(pillText)"
        )
    }

    func test_aboutSection_withVMIdle_pillSaysNotDownloaded() throws {
        let viewModel = makeVM(state: .idle)
        let view = makeAbout(modelStatusViewModel: viewModel)
        let inspected = try view.inspect()

        let pill = try inspected.find(
            viewWithAccessibilityIdentifier: "aboutSection.poweredByBadge.gemma-4-e4b-it.statePill"
        )
        let pillText = try pill.text().string()
        XCTAssertTrue(
            pillText.contains("Not downloaded"),
            "State pill in .idle must read 'Not downloaded'. Got: \(pillText)"
        )
    }

    func test_aboutSection_withVMDownloading_pillShowsPercent() throws {
        let viewModel = makeVM(state: .downloading, progress: 0.42)
        let view = makeAbout(modelStatusViewModel: viewModel)
        let inspected = try view.inspect()

        let pill = try inspected.find(
            viewWithAccessibilityIdentifier: "aboutSection.poweredByBadge.gemma-4-e4b-it.statePill"
        )
        let pillText = try pill.text().string()
        XCTAssertTrue(
            pillText.contains("42"),
            "State pill in .downloading must include the percent value '42'. Got: \(pillText)"
        )
        XCTAssertTrue(
            pillText.contains("Downloading"),
            "State pill in .downloading must read 'Downloading …'. Got: \(pillText)"
        )
    }

    func test_aboutSection_withVMFailed_pillSaysFailed() throws {
        let viewModel = makeVM(state: .failed)
        let view = makeAbout(modelStatusViewModel: viewModel)
        let inspected = try view.inspect()

        let pill = try inspected.find(
            viewWithAccessibilityIdentifier: "aboutSection.poweredByBadge.gemma-4-e4b-it.statePill"
        )
        let pillText = try pill.text().string()
        XCTAssertTrue(
            pillText.contains("Failed"),
            "State pill in .failed must read 'Failed'. Got: \(pillText)"
        )
    }

    // MARK: - Parakeet has no state pill regardless of VM state

    func test_aboutSection_parakeetBadgeNeverShowsStatePill() throws {
        for state in allStates() {
            let viewModel = makeVM(state: state, progress: 0.5)
            let view = makeAbout(modelStatusViewModel: viewModel)
            let inspected = try view.inspect()

            // Parakeet badge always present.
            XCTAssertNoThrow(
                try inspected.find(viewWithAccessibilityIdentifier: "aboutSection.poweredByBadge.nvidia-parakeet-tdt"),
                "Parakeet badge must render in every state. State: \(state)"
            )
            // Parakeet's pill identifier never present.
            XCTAssertThrowsError(
                try inspected.find(
                    viewWithAccessibilityIdentifier: "aboutSection.poweredByBadge.nvidia-parakeet-tdt.statePill"
                ),
                "Parakeet badge must never expose a state pill. State: \(state)"
            )
        }
    }
}
