// SafetyDisclaimerViewRenderTests.swift
// macOS Local Speech-to-Text Application
//
// ViewInspector + crash-detection tests for SafetyDisclaimerView (#12).
// Acceptance criteria item 4: "Crash-detection test:
// SafetyDisclaimerView() instantiates without crash."
//
// Catches the @Observable + actor-existential crash pattern documented in
// `.claude/references/concurrency.md` §1, plus body-evaluation crashes
// that only surface at runtime.

import SwiftUI
import ViewInspector
import XCTest
@testable import SpeechToText

extension SafetyDisclaimerView: Inspectable {}

@MainActor
final class SafetyDisclaimerViewRenderTests: XCTestCase {

    // MARK: - Crash-detection: instantiation

    /// Critical: the disclaimer carries no `@Observable` view models or
    /// actor existentials, but the crash-detection contract still applies
    /// — every new SwiftUI view in this codebase has an instantiation
    /// test (see `.claude/references/testing-conventions.md`).
    func test_safetyDisclaimer_instantiatesWithoutCrash() {
        let view = SafetyDisclaimerView(onAcknowledge: {})
        XCTAssertNotNil(view)
    }

    /// Body access is where view-tree crashes actually surface — the
    /// executor check fires when SwiftUI walks the View hierarchy.
    func test_safetyDisclaimer_bodyAccessDoesNotCrash() {
        let view = SafetyDisclaimerView(onAcknowledge: {})
        let body = view.body
        XCTAssertNotNil(body)
    }

    /// Pin the spec contract: the disclaimer must publish a stable
    /// accessibility identifier so the host-side ViewInspector can
    /// confirm presence in render tests against the recording modal.
    func test_safetyDisclaimer_exposesAccessibilityIdentifier() throws {
        let view = SafetyDisclaimerView(onAcknowledge: {})
        let inspected = try view.inspect()
        XCTAssertNoThrow(try inspected.find(viewWithAccessibilityIdentifier: "safetyDisclaimerView"))
    }

    // MARK: - Acknowledge callback

    /// AC item 2: "Cannot be dismissed except via 'I understand,
    /// continue' button." Verify the button is wired to the
    /// `onAcknowledge` closure rather than dismissed silently.
    func test_safetyDisclaimer_acknowledgeButtonInvokesCallback() throws {
        var invoked = false
        let view = SafetyDisclaimerView(onAcknowledge: { invoked = true })

        let inspected = try view.inspect()
        let button = try inspected.find(viewWithAccessibilityIdentifier: "safetyDisclaimerView.acknowledgeButton")
            .find(ViewType.Button.self)
        try button.tap()

        XCTAssertTrue(invoked, "Tapping the acknowledge button must invoke the supplied closure")
    }

    // Note: the disclaimer's `hasAcknowledged` `@State` guard prevents a
    // rapid double-tap from firing `onAcknowledge` twice at runtime, but
    // ViewInspector's `tap()` invokes the captured action closure against
    // a frozen view snapshot and does not propagate `@State` updates back
    // to a re-inspected button — so a synthetic double-tap test against
    // SafetyDisclaimerView reads the stale initial state both times.
    // The runtime contract is verified at the modal layer instead: the
    // `isDismissing` guard at the top of
    // `LiquidGlassRecordingModal.handleSafetyDisclaimerAcknowledged`
    // serves as the modal-side single-shot, and the ack itself is
    // idempotent (`RecordingViewModel.acknowledgeSafetyDisclaimer` is
    // safe to call repeatedly — re-saving the same `true` value).
}
