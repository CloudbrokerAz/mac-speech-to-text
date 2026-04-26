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

    // MARK: - Render contract pins (#16)

    /// AC item 1 (#12): the headline is the load-bearing safety
    /// statement and was reviewed for clinical wording. Pin the exact
    /// copy so an accidental softening (e.g. dropping "not a
    /// diagnostic tool") is caught at test time, not in the field.
    func test_safetyDisclaimer_titleCopyIsPinned() throws {
        let view = SafetyDisclaimerView(onAcknowledge: {})
        let inspected = try view.inspect()
        let textValues = inspected
            .findAll(ViewType.Text.self)
            .compactMap { try? $0.string() }
        XCTAssertTrue(
            textValues.contains("This is a drafting assistant, not a diagnostic tool"),
            "Disclaimer title copy must match the reviewed wording exactly. Found texts: \(textValues)"
        )
    }

    /// AC item 1 (#12): the body must include the doctor-responsibility
    /// clause. Substring assertion — leaves room for minor wording
    /// tweaks while pinning the accountability statement.
    func test_safetyDisclaimer_copyContainsResponsibilityClause() throws {
        let view = SafetyDisclaimerView(onAcknowledge: {})
        let inspected = try view.inspect()
        let joined = inspected
            .findAll(ViewType.Text.self)
            .compactMap { try? $0.string() }
            .joined(separator: " ")
        XCTAssertTrue(
            joined.contains("responsible for reviewing, editing, and clinically validating"),
            "Disclaimer body must include the doctor-responsibility clause. Joined text was: \(joined)"
        )
    }

    /// Pin the acknowledge button's label text. The button is the only
    /// dismissal affordance (AC item 2: no escape, no tap-to-dismiss),
    /// so the label is the doctor's contract — "I understand,
    /// continue" is the reviewed wording.
    func test_safetyDisclaimer_acknowledgeButton_labelTextIsPinned() throws {
        let view = SafetyDisclaimerView(onAcknowledge: {})
        let inspected = try view.inspect()
        let button = try inspected
            .find(viewWithAccessibilityIdentifier: "safetyDisclaimerView.acknowledgeButton")
            .find(ViewType.Button.self)
        let labelText = try button.labelView().find(ViewType.Text.self).string()
        XCTAssertEqual(
            labelText,
            "I understand, continue",
            "Acknowledge button label must match the reviewed wording exactly"
        )
    }

    /// Pin `hasAcknowledged: Bool = false` as the initial state — the
    /// acknowledge button must be enabled on first render so the
    /// doctor can dismiss the modal. Catches an accidental flip of
    /// the single-shot guard's initial value (which would deadlock
    /// the modal on first render).
    func test_safetyDisclaimer_acknowledgeButton_isInitiallyEnabled() throws {
        let view = SafetyDisclaimerView(onAcknowledge: {})
        let inspected = try view.inspect()
        let button = try inspected
            .find(viewWithAccessibilityIdentifier: "safetyDisclaimerView.acknowledgeButton")
            .find(ViewType.Button.self)
        XCTAssertFalse(
            button.isDisabled(),
            "Acknowledge button must be enabled on first render"
        )
    }

    /// Pin the modal-overlay structural shape: the disclaimer's root
    /// is a `ZStack` that lays the scrim behind the disclaimer card.
    /// Mirrors the `RecordingModalRenderTests.test_recordingModal_viewHierarchy`
    /// pattern. A refactor that swapped the structural container
    /// (e.g. to a `VStack`) would change the layering and let
    /// interaction leak through to the underlying recording modal.
    ///
    /// Uses the root `zStack()` accessor rather than `find(ZStack.self)`
    /// so the test fails on a real refactor instead of accidentally
    /// matching a SwiftUI-internal `ZStack` reachable via `Background`
    /// / `Overlay` traversal.
    func test_safetyDisclaimer_renderHierarchyRootIsZStack() throws {
        let view = SafetyDisclaimerView(onAcknowledge: {})
        let inspected = try view.inspect()
        XCTAssertNoThrow(try inspected.zStack())
    }
}
