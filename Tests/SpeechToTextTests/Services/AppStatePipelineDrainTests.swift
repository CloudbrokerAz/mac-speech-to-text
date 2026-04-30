import Foundation
import Testing
@testable import SpeechToText

/// Swift Testing coverage for the cancel + drain + unload sequence
/// `AppState.removeClinicalNotesModel()` runs against an in-flight
/// clinical-notes pipeline (#120 + #121).
///
/// **Why this exists.** Before #123 widened `AppState.llmProvider` to
/// `(any LLMProvider)?` and added the `init(llmPipelineOverride:)`
/// seam, both branches were only exercisable against a real
/// `MLXGemmaProvider` mid-`runGeneration` — which requires
/// `RUN_MLX_GOLDEN=1` and a downloaded ~5 GB Gemma 4 model, so the
/// nightly hardware run was the only thing protecting the cancel
/// propagation from regression. A future refactor that subtly broke
/// `Task.checkCancellation()` propagation in `runGeneration`'s chunk
/// loop, or changed the drain order in `removeClinicalNotesModel`,
/// would have shipped silently to main and only burned a downstream
/// PR's nightly. This suite closes that gap with a `MockLLMProvider`
/// in `.suspendUntilCancelled` mode + the
/// `startClinicalNotesPipelineForTesting(transcript:)` seam.
///
/// **What is asserted.**
/// - `removeClinicalNotesModel()` resolves in well under 2 s when an
///   in-flight pipeline is mid-`generate`. (Real upper bound: a
///   single MainActor hop + the mock's `Task.sleep` cancellation
///   handler firing.) A regression that dropped the
///   `existing.task.cancel()` would leak the test out to the mock's
///   60 s sleep deadline; a regression that kept the cancel but
///   skipped the `await existing.task.value` would race the
///   `await llmProvider?.unload()` against a still-running
///   `runGeneration`, leaving the unload-call assertion below
///   stochastically failing.
/// - `MockLLMProvider.unloadCallCount() >= 1` — the wire-through
///   that #120 added to the `LLMProvider` protocol is now reachable
///   from non-hardware tests via the protocol-typed `llmProvider`
///   field. Pre-#123, the call was made on a concrete
///   `MLXGemmaProvider?` so the counter on the mock was unreachable
///   from this code path.
/// - `isClinicalNotesPipelineActive == false` after the drain — the
///   token-guarded clear via `clearClinicalNotesPipelineSlotIfMatching`
///   ran exactly once, regardless of which call site (the pipeline
///   body's trailing line or the drain inside `removeClinicalNotesModel`)
///   got there first.
///
/// All tests are tagged `.fast` and `@MainActor`-isolated. No
/// network, no real LLM, no on-disk model bytes touched (the test's
/// AppState carries `manifest = nil` so the manifest-driven directory
/// remove is a structural no-op).
@Suite("AppState pipeline drain (#123 / #121)", .tags(.fast))
@MainActor
struct AppStatePipelineDrainTests {

    // MARK: - Fixtures

    /// Build a fresh `AppState` wired with a `MockLLMProvider` in
    /// `.suspendUntilCancelled` mode and a `ClinicalNotesProcessor`
    /// pointing at it. Pre-seeds `llmDownloadState = .ready` so the
    /// pipeline's `downloadClinicalNotesModel` short-circuits at the
    /// `.ready` guard rather than reaching the MLX-only cast added in
    /// #123 (production-only — see `Sources/SpeechToTextApp/AppState.swift`
    /// `downloadClinicalNotesModel`'s `as? MLXGemmaProvider` arm).
    /// `manifest`/`downloader` are `nil`: the test never goes through the
    /// download path, and `removeClinicalNotesModel`'s no-manifest branch
    /// is exactly the right shape for a non-hardware drain check.
    ///
    /// Seeds an active `ClinicalSession` on the AppState's per-instance
    /// `SessionStore` so the cancel-fallback writes
    /// (`applyClinicalNotesFallback` → `setDraftStatus`) land cleanly
    /// rather than logging "no active session" warnings into the test
    /// output (silent-failure-hunter F1 on the #123 pre-PR review).
    /// `SessionStore` is per-AppState (not a singleton), so this does
    /// not introduce cross-test interference.
    private func makeAppStateWithSlowMock(
        suspendDuration: Duration = .seconds(60)
    ) throws -> (appState: AppState, mockProvider: MockLLMProvider) {
        let mock = MockLLMProvider(suspendDuration: suspendDuration)
        let manipulations = ManipulationsRepository(all: [])
        let promptBuilder = try ClinicalNotesPromptBuilder.loadFromBundle(
            manipulations: manipulations
        )
        let processor = ClinicalNotesProcessor(
            provider: mock,
            promptBuilder: promptBuilder,
            manipulations: manipulations
        )
        let pipeline = AppState.LLMPipeline(
            downloader: nil,
            provider: mock,
            processor: processor,
            manifest: nil
        )
        let appState = AppState(llmPipelineOverride: pipeline)
        appState.llmDownloadState = .ready
        // Seed the SessionStore so fallback writes have somewhere to
        // land — see doc comment above. The transcript content is
        // structural-only; this is a test fake.
        var recording = RecordingSession(
            language: appState.settings.language.defaultLanguage,
            state: .completed
        )
        recording.transcribedText = "drain-test-seed"
        appState.sessionStore.start(from: recording)
        return (appState, mock)
    }

    /// Spin until `condition()` returns true or the deadline elapses.
    /// Returns `true` on success, `false` on timeout. Polls at 25 ms
    /// granularity — fine-grained enough that the deadline is roughly
    /// what the test asserts, coarse enough that the polling itself
    /// doesn't dominate cost.
    private func waitFor(
        timeout: Duration,
        _ condition: () async -> Bool
    ) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(25))
        }
        return await condition()
    }

    // MARK: - Tests

    /// **The drain happy path** — the load-bearing assertion this
    /// whole issue was filed to enable.
    ///
    /// 1. Start a pipeline against a mock that suspends in `generate`.
    /// 2. Wait for the mock to actually be inside `generate` (i.e.
    ///    `callCount() >= 1` — the suspend has begun).
    /// 3. Call `removeClinicalNotesModel()` and time it.
    /// 4. Assert: well under 2 s, pipeline-active flag flipped false,
    ///    `unload()` was called >= 1 time on the mock.
    @Test("removeClinicalNotesModel cancels an in-flight pipeline and calls unload()")
    func removeClinicalNotesModel_drainsActivePipeline() async throws {
        let (appState, mock) = try makeAppStateWithSlowMock()

        appState.startClinicalNotesPipelineForTesting(transcript: "test transcript for drain")

        // Pipeline-active flag flips synchronously inside the
        // start-pipeline body, before the Task even hits its first
        // suspension point.
        #expect(appState.isClinicalNotesPipelineActive == true)

        // Wait for the mock's `generate` to actually be entered. The
        // pipeline Task runs async; we don't know how many MainActor
        // hops or how much time elapses before `processor.process` →
        // `provider.generate` lands. Polling on `callCount()` is the
        // most direct signal that the suspend is genuinely in flight.
        let entered = await waitFor(timeout: .seconds(5)) {
            await mock.callCount() >= 1
        }
        #expect(entered, "mock provider's generate() was never called within 5s")

        let start = ContinuousClock.now
        await appState.removeClinicalNotesModel()
        let elapsed = ContinuousClock.now - start

        // Load-bearing latency budget: a real cancel + one MainActor
        // hop + the mock's sleep cancellation handler firing should be
        // tens of milliseconds. 2 s is the issue's stated upper bound;
        // we use 1 s here because anything closer to the mock's 60 s
        // ceiling would mean cancel propagation broke.
        #expect(elapsed < .seconds(1), "drain took \(elapsed) — cancel propagation may be broken")

        #expect(appState.isClinicalNotesPipelineActive == false)
        #expect(appState.modelStatusViewModel.isPipelineActive == false)

        // The wire-through #120 added to `LLMProvider`. Pre-#123 this
        // counter was unreachable from AppState integration tests
        // because `llmProvider` was the concrete type.
        let unloadCalls = await mock.unloadCallCount()
        #expect(unloadCalls >= 1, "removeClinicalNotesModel did not invoke unload() on the provider")

        // **The ordering pin.** Per silent-failure-hunter F3 on the
        // pre-PR review: counting unload calls is not enough — a
        // regression that drops `await existing.task.value` from the
        // drain (keeps `cancel()` but skips the await) would still hit
        // unload exactly once and pass `unloadCalls >= 1`. The mock's
        // `unloadInFlightSnapshotsObserved()` captures the in-flight
        // generate count at the moment `unload()` lands on the actor.
        // Correctly-drained: the suspended `generate` has already
        // unwound through its `defer`, so the snapshot reads `0`.
        // Broken-drain (await dropped): unload races onto the actor
        // while `generate` is still suspended on `Task.sleep`, so the
        // snapshot reads `>= 1`. This is the load-bearing assertion
        // the whole #123 issue was filed to make catchable.
        let snapshots = await mock.unloadInFlightSnapshotsObserved()
        let lastSnapshot = snapshots.last ?? -1
        #expect(
            lastSnapshot == 0,
            "unload() observed \(lastSnapshot) in-flight generate(s) — drain await may be missing (cancel ran but `await existing.task.value` did not gate unload)"
        )

        // Final state: the model state-machine collapsed to .idle and
        // the VM mirror followed. Pinning this here as a regression
        // guard against a future refactor that drains the pipeline but
        // forgets to run the trailing state-reset block.
        #expect(appState.llmDownloadState == .idle)
        #expect(appState.modelStatusViewModel.state == .idle)
    }

    /// **Sequential / idempotent drain.** Pins that
    /// `removeClinicalNotesModel()` cleanly composes when called more
    /// than once and that a fresh hand-off after a successful drain
    /// re-enters generate (proves the `defer { isRemovingClinicalNotesModel
    /// = false }` clear at the top of `removeClinicalNotesModel`
    /// actually fires across the full call's lifetime).
    ///
    /// **What this does NOT cover** (called out per silent-failure-hunter
    /// F2 on the #123 pre-PR review): the `isRemovingClinicalNotesModel`
    /// gate's race window is "during the drain's `await existing.task.value`,"
    /// and this test does not interleave a fresh
    /// `startClinicalNotesPipelineForTesting` *during* that await. The
    /// gate would need a `MockLLMProvider.unload()` hook that schedules
    /// the re-entry — deferred to a follow-up issue. The drain happy
    /// path (above) is the test that catches the cancel-propagation
    /// regression #123 was filed to prevent; this test catches a
    /// regression that left the gate stuck `true` (e.g. someone moved
    /// the `defer` clear inside a conditional).
    @Test("Sequential removeClinicalNotesModel calls compose cleanly + post-drain hand-off re-enters generate")
    func removeClinicalNotesModel_reentrantCallsStayDrained() async throws {
        let (appState, mock) = try makeAppStateWithSlowMock()

        appState.startClinicalNotesPipelineForTesting(transcript: "first")
        let entered = await waitFor(timeout: .seconds(5)) {
            await mock.callCount() >= 1
        }
        #expect(entered)

        await appState.removeClinicalNotesModel()
        #expect(appState.isClinicalNotesPipelineActive == false)
        let unloadAfterFirst = await mock.unloadCallCount()
        #expect(unloadAfterFirst >= 1)

        // Second remove call with no in-flight pipeline must be a clean
        // no-op. A regression where `isRemovingClinicalNotesModel` got
        // stuck `true` (e.g. someone moved the `defer` clear to inside
        // a conditional) would leave the state machine deadlocked, but
        // the public surface is the same `.idle` collapse — so we re-pin
        // it here.
        await appState.removeClinicalNotesModel()
        #expect(appState.llmDownloadState == .idle)
        #expect(appState.isClinicalNotesPipelineActive == false)

        // Subsequent hand-off after the drain succeeded must spawn a
        // fresh pipeline (proves the gate cleared via `defer`), and
        // must immediately drain when removed again.
        //
        // Re-prime `.ready` before the second start: the first remove
        // collapsed state to `.idle`, and the test pipeline carries
        // `downloader = nil`, so without this re-prime
        // `runClinicalNotesPipeline` would early-return at
        // `downloadClinicalNotesModel`'s "pipeline unavailable" guard
        // before ever reaching the processor.
        appState.llmDownloadState = .ready
        appState.startClinicalNotesPipelineForTesting(transcript: "second")
        let secondEntered = await waitFor(timeout: .seconds(5)) {
            await mock.callCount() >= 2
        }
        #expect(secondEntered, "post-drain pipeline never reached generate — gate may be stuck")

        await appState.removeClinicalNotesModel()
        #expect(appState.isClinicalNotesPipelineActive == false)
        let unloadAfterSecond = await mock.unloadCallCount()
        #expect(unloadAfterSecond >= unloadAfterFirst + 1)
    }
}
