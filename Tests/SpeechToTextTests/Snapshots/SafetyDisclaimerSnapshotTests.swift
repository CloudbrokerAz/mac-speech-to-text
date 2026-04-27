// SafetyDisclaimerSnapshotTests.swift
// macOS Local Speech-to-Text Application
//
// Image-snapshot regression tests for `SafetyDisclaimerView` (#12). The
// disclaimer is the load-bearing safety surface for Clinical Notes Mode
// — the headline, body copy, and acknowledge button are clinically
// reviewed wording and a silent visual change (truncation, contrast
// failure, layout shift) would land in the field invisibly.
//
// These tests are XCTest-based because `pointfreeco/swift-snapshot-testing`
// only provides a public `assertSnapshot` integration with XCTest today.
// They live alongside `SafetyDisclaimerViewRenderTests` (ViewInspector
// crash tests) — the snapshot tests catch what ViewInspector cannot
// (typography, sizing, contrast) but they cost more in maintenance, so
// the suite stays narrow per `.claude/references/testing-conventions.md`.
//
// **CI carve-out.** This class is in the by-name skip list in
// `.github/workflows/ci.yml` because the CI runner is `macos-15` while
// the dev / remote-Mac pre-push host is `macos-26`, and image goldens
// differ across macOS major versions due to font hinting + Core
// Animation render diffs. The class runs locally and on every pre-push
// to the remote Mac. See `Tests/SpeechToTextTests/Snapshots/README.md`.

import SnapshotTesting
import SwiftUI
import XCTest
@testable import SpeechToText

/// Image snapshots for the one-time safety disclaimer (#12).
///
/// Two states cover the full visual surface:
///   - light appearance, default size — the canonical render.
///   - dark appearance, default size — verifies the amber accent + the
///     `.ultraThinMaterial` card don't lose contrast under dark mode.
///
/// Animated state (`isVisible` ramping from 0 → 1) is intentionally NOT
/// snapshotted — `.onAppear` triggers the spring animation, and the
/// snapshot capture races against it. We capture the post-onAppear
/// settled state by relying on `NSHostingView.layoutSubtreeIfNeeded()`
/// in `SnapshotHost.hosting(_:size:appearance:)` to drive layout, but
/// any test that depended on the in-flight scale value would be flaky.
@MainActor
final class SafetyDisclaimerSnapshotTests: XCTestCase {

    /// Standard disclaimer surface — wider than the disclaimer card so
    /// the full backdrop scrim and the centred card are both visible.
    private static let surfaceSize = CGSize(width: 480, height: 480)

    /// Light-mode render. The disclaimer's headline + body copy are the
    /// load-bearing safety wording — a regression here is a regression in
    /// what the doctor reads before they tap "I understand, continue".
    func test_safetyDisclaimer_lightMode() {
        let view = SafetyDisclaimerView(onAcknowledge: {})
        let hosting = SnapshotHost.hosting(
            view,
            size: Self.surfaceSize,
            appearance: .light
        )
        assertSnapshot(of: hosting, as: .image)
    }

    /// Dark-mode render. The amber accent on the warning glyph + the
    /// acknowledge button must remain visible against the dark
    /// `.ultraThinMaterial` backdrop.
    func test_safetyDisclaimer_darkMode() {
        let view = SafetyDisclaimerView(onAcknowledge: {})
        let hosting = SnapshotHost.hosting(
            view,
            size: Self.surfaceSize,
            appearance: .dark
        )
        assertSnapshot(of: hosting, as: .image)
    }
}
