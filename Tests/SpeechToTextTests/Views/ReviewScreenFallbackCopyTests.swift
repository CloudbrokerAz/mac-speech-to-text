// ReviewScreenFallbackCopyTests.swift
// macOS Local Speech-to-Text Application
//
// Coverage for #104 Deliverable C — fallback-banner copy branches on
// `ReviewViewModel.fallbackReasonCode`, and the
// `model_unavailable` variant exposes a deep-link button to Settings →
// Clinical Notes.
//
// Two surfaces tested in one file:
//   - Swift Testing `.fast` suite for the per-reason-code subtitle copy
//     plus the `openClinicalNotesSettings` handler routing.
//   - XCTest + ViewInspector class for the deep-link button's visibility
//     across reason codes (matches the existing `ReviewScreenRenderTests`
//     idiom — accessibility-identifier based assertions).
//
// PHI: synthetic fixtures only. Reason codes are structural `String`
// constants on `ClinicalNotesProcessor` — never PHI. See
// `.claude/references/phi-handling.md`.

import Foundation
import SwiftUI
import Testing
import ViewInspector
import XCTest
@testable import SpeechToText

// MARK: - Helpers

@MainActor
private enum ReviewScreenFallbackCopyFixture {
    static func stubManipulations() -> ManipulationsRepository {
        ManipulationsRepository(all: [
            Manipulation(id: "diversified_hvla", displayName: "Diversified HVLA", clinikoCode: nil)
        ])
    }

    /// Build a `ReviewViewModel` whose `loadState` is
    /// `.fallback(reasonCode:)` for the supplied code. Mirrors the
    /// fixture shape used by `ReviewScreenRenderTests` so the two
    /// suites stay in lockstep.
    static func makeFallbackViewModel(
        reasonCode: String,
        openClinicalNotesSettingsHandler: @escaping @MainActor () -> Void = {}
    ) -> ReviewViewModel {
        let store = SessionStore()
        var recording = RecordingSession(language: "en", state: .completed)
        recording.transcribedText = "Synthetic transcript for fallback-copy coverage."
        store.start(from: recording)
        store.setDraftNotes(StructuredNotes())
        store.setDraftStatus(.fallback(reasonCode: reasonCode))
        return ReviewViewModel(
            sessionStore: store,
            manipulations: stubManipulations(),
            openClinicalNotesSettingsHandler: openClinicalNotesSettingsHandler
        )
    }

    /// Walk the rendered ReviewScreen and return the joined `Text`
    /// contents inside the fallback banner. Lets the subtitle-copy
    /// assertions pin user-visible wording without exposing the
    /// `private` `fallbackBannerSubtitle` accessor.
    static func joinedFallbackBannerText(viewModel: ReviewViewModel) throws -> String {
        let screen = ReviewScreen(viewModel: viewModel)
        let inspected = try screen.inspect()
        let banner = try inspected.find(viewWithAccessibilityIdentifier: "reviewScreen.fallbackBanner")
        return banner
            .findAll(ViewType.Text.self)
            .compactMap { try? $0.string() }
            .joined(separator: " ")
    }
}

// MARK: - Subtitle copy (Swift Testing)

@Suite("ReviewScreen fallback banner subtitle copy", .tags(.fast))
@MainActor
struct ReviewScreenFallbackBannerSubtitleTests {

    @Test("model_unavailable copy points the doctor to Settings")
    func fallbackBannerSubtitle_modelUnavailable_pointsToSettings() throws {
        let viewModel = ReviewScreenFallbackCopyFixture.makeFallbackViewModel(
            reasonCode: ClinicalNotesProcessor.reasonModelUnavailable
        )
        let joined = try ReviewScreenFallbackCopyFixture.joinedFallbackBannerText(viewModel: viewModel)
        #expect(
            joined.contains("isn't ready"),
            "model_unavailable copy must surface the readiness explanation. Joined banner text: \(joined)"
        )
        #expect(
            joined.contains("Settings"),
            "model_unavailable copy must mention Settings as the next step. Joined banner text: \(joined)"
        )
    }

    @Test("model_download_cancelled copy points the doctor to Settings to finish")
    func fallbackBannerSubtitle_modelDownloadCancelled_pointsToSettings() throws {
        let viewModel = ReviewScreenFallbackCopyFixture.makeFallbackViewModel(
            reasonCode: ClinicalNotesProcessor.reasonModelDownloadCancelled
        )
        let joined = try ReviewScreenFallbackCopyFixture.joinedFallbackBannerText(viewModel: viewModel)
        #expect(
            joined.contains("cancelled"),
            "model_download_cancelled copy must say cancelled. Joined banner text: \(joined)"
        )
        #expect(
            joined.contains("Settings"),
            "model_download_cancelled copy must mention Settings. Joined banner text: \(joined)"
        )
    }

    @Test("session_expired copy prompts the doctor to re-record")
    func fallbackBannerSubtitle_sessionExpired_promptsReRecord() throws {
        let viewModel = ReviewScreenFallbackCopyFixture.makeFallbackViewModel(
            reasonCode: ClinicalNotesProcessor.reasonSessionExpired
        )
        let joined = try ReviewScreenFallbackCopyFixture.joinedFallbackBannerText(viewModel: viewModel)
        #expect(
            joined.contains("Session expired"),
            "session_expired copy must surface the lifecycle reason. Joined banner text: \(joined)"
        )
    }

    @Test("llm_error keeps the generic edit-or-insert copy")
    func fallbackBannerSubtitle_llmError_keepsGenericCopy() throws {
        let viewModel = ReviewScreenFallbackCopyFixture.makeFallbackViewModel(
            reasonCode: ClinicalNotesProcessor.reasonLLMError
        )
        let joined = try ReviewScreenFallbackCopyFixture.joinedFallbackBannerText(viewModel: viewModel)
        #expect(
            joined.contains("Edit the SOAP"),
            "llm_error must fall back to the generic copy. Joined banner text: \(joined)"
        )
    }

    @Test("invalid_json_after_retry keeps the generic edit-or-insert copy")
    func fallbackBannerSubtitle_invalidJSON_keepsGenericCopy() throws {
        let viewModel = ReviewScreenFallbackCopyFixture.makeFallbackViewModel(
            reasonCode: ClinicalNotesProcessor.reasonInvalidJSONAfterRetry
        )
        let joined = try ReviewScreenFallbackCopyFixture.joinedFallbackBannerText(viewModel: viewModel)
        #expect(
            joined.contains("Edit the SOAP"),
            "invalid_json_after_retry must fall back to the generic copy. Joined banner text: \(joined)"
        )
    }

    @Test("all_soap_empty_after_retry keeps the generic edit-or-insert copy")
    func fallbackBannerSubtitle_allEmpty_keepsGenericCopy() throws {
        let viewModel = ReviewScreenFallbackCopyFixture.makeFallbackViewModel(
            reasonCode: ClinicalNotesProcessor.reasonAllSOAPEmptyAfterRetry
        )
        let joined = try ReviewScreenFallbackCopyFixture.joinedFallbackBannerText(viewModel: viewModel)
        #expect(
            joined.contains("Edit the SOAP"),
            "all_soap_empty_after_retry must fall back to the generic copy. Joined banner text: \(joined)"
        )
    }
}

// MARK: - Handler routing (Swift Testing)

/// Tiny `actor` flag used by the handler-routing test to capture the
/// closure invocation deterministically across the `@MainActor`
/// boundary. Avoids the `nonisolated(unsafe)` SwiftLint warning.
actor InvocationFlag {
    private(set) var didFire: Bool = false

    func mark() {
        didFire = true
    }

    func value() -> Bool { didFire }
}

@Suite("ReviewViewModel.openClinicalNotesSettings", .tags(.fast))
@MainActor
struct ReviewViewModelOpenClinicalNotesSettingsTests {

    @Test("openClinicalNotesSettings invokes the injected handler")
    func openClinicalNotesSettings_invokesInjectedHandler() async {
        let flag = InvocationFlag()
        let viewModel = ReviewScreenFallbackCopyFixture.makeFallbackViewModel(
            reasonCode: ClinicalNotesProcessor.reasonModelUnavailable,
            openClinicalNotesSettingsHandler: {
                Task { await flag.mark() }
            }
        )

        viewModel.openClinicalNotesSettings()

        // The handler dispatches a child Task so the flag write may
        // race the assertion. Yield until the actor reports the
        // mutation rather than gating on a timer.
        for _ in 0..<50 where await flag.value() == false {
            await Task.yield()
        }

        #expect(await flag.value(), "Injected handler must be invoked exactly once")
    }
}

// MARK: - Deep-link button visibility (XCTest + ViewInspector)

@MainActor
final class ReviewScreenOpenClinicalNotesSettingsButtonVisibilityTests: XCTestCase {

    /// `model_unavailable` and `model_download_cancelled` should both
    /// expose the deep-link button — both recover via Settings → Clinical
    /// Notes (start the download / finish the cancelled download). Every
    /// other fallback reason must omit it so the doctor's attention stays
    /// on the editing surface.
    func test_openClinicalNotesSettingsButton_visibleOnlyForModelLifecycleReasons() throws {
        let visibleCases: [String] = [
            ClinicalNotesProcessor.reasonModelUnavailable,
            ClinicalNotesProcessor.reasonModelDownloadCancelled
        ]
        let hiddenCases: [String] = [
            ClinicalNotesProcessor.reasonSessionExpired,
            ClinicalNotesProcessor.reasonLLMError,
            ClinicalNotesProcessor.reasonInvalidJSONAfterRetry,
            ClinicalNotesProcessor.reasonAllSOAPEmptyAfterRetry
        ]

        for reason in visibleCases {
            let viewModel = ReviewScreenFallbackCopyFixture.makeFallbackViewModel(reasonCode: reason)
            let screen = ReviewScreen(viewModel: viewModel)
            let inspected = try screen.inspect()
            XCTAssertNoThrow(
                try inspected.find(viewWithAccessibilityIdentifier: "reviewScreen.fallback.openClinicalNotesSettings"),
                "Deep-link button must be visible for reason=\(reason)"
            )
            // Sanity: the existing raw-transcript affordance also stays
            // — the deep-link is *additive*, not a replacement.
            XCTAssertNoThrow(
                try inspected.find(viewWithAccessibilityIdentifier: "reviewScreen.fallback.insertRawTranscript"),
                "Insert raw transcript button must remain visible for reason=\(reason)"
            )
        }

        for reason in hiddenCases {
            let viewModel = ReviewScreenFallbackCopyFixture.makeFallbackViewModel(reasonCode: reason)
            let screen = ReviewScreen(viewModel: viewModel)
            let inspected = try screen.inspect()
            XCTAssertThrowsError(
                try inspected.find(viewWithAccessibilityIdentifier: "reviewScreen.fallback.openClinicalNotesSettings"),
                "Deep-link button must NOT be visible for reason=\(reason)"
            )
        }
    }
}
