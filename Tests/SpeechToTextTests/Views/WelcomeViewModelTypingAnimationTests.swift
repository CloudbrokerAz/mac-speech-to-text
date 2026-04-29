// WelcomeViewModelTypingAnimationTests.swift
// macOS Local Speech-to-Text Application
//
// Pure-logic + lifecycle tests for the typing animation surface in
// `WelcomeViewModel`. Companion to issue #83 — verifies the
// `MainActor.assumeIsolated` codepath instantiates, ticks, and tears down
// without crashing. The Sendable-warning fix itself is enforced at compile
// time + by the `swift build -c release` zero-warning gate; these tests
// provide a runtime regression backstop on the public surface area.
//
// Swift Testing per `.claude/CLAUDE.md` operating rule #2 (new pure-logic /
// async tests use Swift Testing). Tagged `.fast` so they run on every CI PR.

import Foundation
import Testing
@testable import SpeechToText

@Suite("WelcomeViewModel typing animation surface", .tags(.fast))
@MainActor
struct WelcomeViewModelTypingAnimationTests {
    // MARK: - displayedText (pure logic)

    @Test("displayedText returns empty string when no characters typed yet")
    func displayedText_isEmpty_whenCharacterCountIsZero() {
        let viewModel = makeViewModel()
        viewModel.currentPhraseIndex = 0
        viewModel.displayedCharacterCount = 0

        #expect(viewModel.displayedText == "")
    }

    @Test("displayedText returns full phrase when character count saturates")
    func displayedText_isFullPhrase_whenCharacterCountAtMax() {
        let viewModel = makeViewModel()
        viewModel.currentPhraseIndex = 0
        let phrase = viewModel.samplePhrases[0]
        viewModel.displayedCharacterCount = phrase.count

        #expect(viewModel.displayedText == phrase)
    }

    @Test("displayedText clamps at phrase length when count overshoots")
    func displayedText_clamps_whenCharacterCountExceedsPhrase() {
        let viewModel = makeViewModel()
        viewModel.currentPhraseIndex = 0
        let phrase = viewModel.samplePhrases[0]
        viewModel.displayedCharacterCount = phrase.count + 1000

        #expect(viewModel.displayedText == phrase)
    }

    @Test(
        "displayedText returns the leading prefix at every character count",
        arguments: 0...20
    )
    func displayedText_isPrefix_acrossCharacterCounts(count: Int) {
        let viewModel = makeViewModel()
        viewModel.currentPhraseIndex = 0
        viewModel.displayedCharacterCount = count

        let phrase = viewModel.samplePhrases[0]
        let expected = String(phrase.prefix(count))
        #expect(viewModel.displayedText == expected)
    }

    // MARK: - Animation lifecycle (regression backstop for #83)

    /// Render-crash + tick test for the `MainActor.assumeIsolated` codepath
    /// introduced by issue #83. If the new Timer block ever regresses to a
    /// shape that crosses an isolation boundary unsafely, this test surfaces
    /// it as a trap or a hung counter rather than a silent compile-time
    /// warning. Real `Timer.scheduledTimer` ticks at 30 ms, so we wait long
    /// enough for at least a couple of fires.
    @Test("startPhraseAnimation advances displayed character count and stops cleanly")
    func startPhraseAnimation_advancesAndStops_withoutCrash() async throws {
        let viewModel = makeViewModel()

        viewModel.startPhraseAnimation()
        // Three ticks at 30ms each, plus a small slop margin for run-loop scheduling.
        try await Task.sleep(nanoseconds: 150_000_000)

        let countAfterTicking = viewModel.displayedCharacterCount
        viewModel.stopPhraseAnimation()

        // The closure incremented at least once, observable on the public surface.
        #expect(countAfterTicking > 0)

        // After stop, no further ticks should be in flight; sleep again and
        // confirm the counter is stable. (If the timer survived stop, the
        // count would keep climbing.)
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(viewModel.displayedCharacterCount == countAfterTicking)
    }

    // MARK: - Helpers

    private func makeViewModel() -> WelcomeViewModel {
        WelcomeViewModel(
            permissionService: MockPermissionService(),
            settingsService: SettingsService(
                userDefaults: UserDefaults(suiteName: "test.welcome.\(UUID().uuidString)") ?? .standard
            )
        )
    }
}
