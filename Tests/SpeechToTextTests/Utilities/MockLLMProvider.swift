import Foundation
@testable import SpeechToText

/// In-memory test fake for `LLMProvider`. Never loads a real model,
/// never allocates GPU memory, and never performs I/O.
///
/// Used anywhere a test needs an `LLMProvider` — the real
/// `MLXGemmaProvider` is only exercised via gated goldens
/// (`RUN_MLX_GOLDEN=1`, nightly), never in CI.
///
/// ### Response modes
///
/// 1. **Fixed** — every `generate` call returns the same string.
///    Use for smoke tests of consumers that don't care about the
///    response shape.
/// 2. **Queued** — pop-front, one per call. Covers
///    `ClinicalNotesProcessor` (#5)'s retry-once flow: enqueue an
///    invalid-JSON response followed by a valid one and assert the
///    processor returns `.success`.
/// 3. **Error** — every call throws the injected error. Covers
///    `ClinicalNotesProcessor` (#5)'s `.rawTranscriptFallback` path.
///
/// `setBehavior(_:)` swaps the mode between calls if a single test
/// needs a more elaborate script than one `Behavior` expresses.
///
/// ### Call log
///
/// Every `generate` and `generateStream` call is recorded on an
/// actor-isolated `callLog`, queryable via `calls()` / `lastCall()` /
/// `callCount()` for assertions.
///
/// ### Thread safety
///
/// Actor-isolated. `generateStream` is `nonisolated` because
/// `AsyncThrowingStream` construction must be synchronous; it hops
/// back into the actor to call `generate`.
public actor MockLLMProvider: LLMProvider {
    /// Record of a single `generate` / `generateStream` invocation.
    public struct Call: Sendable, Equatable {
        public let prompt: String
        public let options: LLMOptions
    }

    /// How the next call(s) should behave. See the type-level doc
    /// comment for the three response modes.
    public enum Behavior: Sendable {
        /// Every call returns the same string.
        case fixedResponse(String)
        /// Queue of responses. Each call pops the front element; calls
        /// after the queue is exhausted throw `responseQueueExhausted`.
        case queuedResponses([String])
        /// Every call throws the wrapped error.
        case error(any Error & Sendable)
        /// Every call sleeps for `duration` then would return
        /// `eventualResponse` — long enough that natural completion
        /// can't race tests that exercise cancellation paths. Used by
        /// `AppState` drain tests (#123) to pin the cancel + await
        /// branch of `removeClinicalNotesModel` without a real Gemma 4
        /// model in flight. Cancelling the awaiting Task trips the
        /// sleep's cancellation handler and `generate` re-throws the
        /// `CancellationError` so consumers (`ClinicalNotesProcessor`)
        /// land in their existing `catch is CancellationError` arm.
        case suspendUntilCancelled(duration: Duration, eventualResponse: String)
    }

    private var behavior: Behavior
    private var callLog: [Call] = []
    private var unloadCalls: Int = 0
    /// Refcount of `generate` calls currently between their entry +
    /// their `defer` decrement. Increments on every `generate` start,
    /// decrements via `defer` on every exit (return, throw, or
    /// cancellation rethrow from `Task.sleep`). Actor-serialised — the
    /// mock's actor isolation makes `+= 1` / `-= 1` atomic w.r.t.
    /// other actor methods. Used by the #123 drain-causality check.
    private var inFlightGenerateCount: Int = 0
    /// One entry per `unload()` call, captured at the moment unload
    /// began executing. Each entry is the value of
    /// `inFlightGenerateCount` at that instant. After a correctly-drained
    /// `removeClinicalNotesModel` (cancel → `await existing.task.value` →
    /// `await llmProvider?.unload()`), the most recent entry is `0`
    /// because the in-flight generate has unwound through its `defer`
    /// before unload gets the actor's serial executor. After a broken
    /// drain (e.g. someone dropped `await existing.task.value`), the
    /// most recent entry is `>= 1` because unload landed on the actor
    /// while the suspended `generate` was still mid-`Task.sleep`. This
    /// is the silent-failure-hunter F3 causality pin — the whole reason
    /// #123 exists.
    private var unloadInFlightSnapshots: [Int] = []

    /// Fixed-response mode. Default empty string is useful for tests
    /// that only care whether the consumer called `generate` at all.
    public init(response: String = "") {
        self.behavior = .fixedResponse(response)
    }

    /// Queued-responses mode. One response per call, front-first.
    public init(responses: [String]) {
        self.behavior = .queuedResponses(responses)
    }

    /// Error-injection mode. Every call throws `error`.
    public init(error: any Error & Sendable) {
        self.behavior = .error(error)
    }

    /// Suspend-until-cancelled mode (#123). Every call sleeps for
    /// `duration` (default 60s — far longer than any reasonable test
    /// timeout) then would return `eventualResponse`. Cancelling the
    /// awaiting Task trips `Task.sleep`'s cancellation handler and
    /// `generate` re-throws the resulting `CancellationError`, so
    /// `ClinicalNotesProcessor` lands in its
    /// `catch is CancellationError` → `reasonModelRemovedMidFlight`
    /// arm. Use this from tests that need to assert the cancel + drain
    /// branch added by #121 to `AppState.removeClinicalNotesModel`.
    public init(
        suspendDuration: Duration = .seconds(60),
        eventualResponse: String = ""
    ) {
        self.behavior = .suspendUntilCancelled(
            duration: suspendDuration,
            eventualResponse: eventualResponse
        )
    }

    // MARK: - LLMProvider

    public func generate(
        prompt: String,
        options: LLMOptions
    ) async throws -> String {
        callLog.append(Call(prompt: prompt, options: options))
        // `defer` runs on the actor when this method exits, regardless
        // of how (return, throw, cancellation rethrow). The increment
        // here + defer decrement is the load-bearing causality
        // instrumentation for the #123 drain test — see the doc comment
        // on `unloadInFlightSnapshots`.
        inFlightGenerateCount += 1
        defer { inFlightGenerateCount -= 1 }
        switch behavior {
        case .fixedResponse(let response):
            return response
        case .queuedResponses(let queue):
            guard let next = queue.first else {
                throw MockLLMProviderError.responseQueueExhausted
            }
            behavior = .queuedResponses(Array(queue.dropFirst()))
            return next
        case .error(let err):
            throw err
        case .suspendUntilCancelled(let duration, let eventualResponse):
            // `Task.sleep` checks cancellation and throws
            // `CancellationError` if the wrapping Task was cancelled —
            // exactly the propagation behaviour real `MLXGemmaProvider`
            // chunk loops surface via `Task.checkCancellation()`. The
            // re-throw lets `ClinicalNotesProcessor` land in its
            // existing cancellation arm. The eventual return is only
            // reached if `duration` actually elapses, which a sane
            // test never lets happen.
            try await Task.sleep(for: duration)
            return eventualResponse
        }
    }

    /// Test-fake `unload()` overriding the protocol default. Increments
    /// `unloadCalls` so consumers can assert wire-through from
    /// `AppState.removeClinicalNotesModel()` (#120) — the production
    /// `MLXGemmaProvider.unload()` releases the `ModelContainer` mmap;
    /// the fake just records that the call landed.
    ///
    /// Also captures `inFlightGenerateCount` into `unloadInFlightSnapshots`
    /// so the #123 drain test can assert ordering: a correctly-drained
    /// remove (cancel → `await existing.task.value` → `unload`) sees
    /// `0` here because the in-flight generate has unwound through its
    /// `defer` before unload lands on the actor. A broken drain that
    /// dropped the `await existing.task.value` would land here while
    /// `generate` is still suspended on `Task.sleep`, capturing `>= 1`.
    public func unload() async {
        unloadInFlightSnapshots.append(inFlightGenerateCount)
        unloadCalls += 1
    }

    public nonisolated func generateStream(
        prompt: String,
        options: LLMOptions
    ) -> AsyncThrowingStream<String, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task { [weak self] in
                guard let self else {
                    continuation.finish()
                    return
                }
                do {
                    let full = try await self.generate(
                        prompt: prompt,
                        options: options
                    )
                    continuation.yield(full)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Test helpers

    /// Snapshot of every call observed so far.
    public func calls() -> [Call] { callLog }

    /// Number of calls observed so far.
    public func callCount() -> Int { callLog.count }

    /// Most recent call, or `nil` if none has been made.
    public func lastCall() -> Call? { callLog.last }

    /// Number of times `unload()` has been called against this fake.
    /// Used by `AppState` integration tests (#120) to assert
    /// `removeClinicalNotesModel()` releases the container before
    /// unlinking the directory.
    public func unloadCallCount() -> Int { unloadCalls }

    /// Snapshots of `inFlightGenerateCount` captured at the start of
    /// each `unload()` call, in call order. The drain-causality check
    /// (#123) reads the most recent entry: `0` proves the in-flight
    /// `generate` had unwound through its `defer` before unload landed,
    /// `>= 1` proves unload raced ahead of generate's cancellation
    /// unwind — i.e. `await existing.task.value` was dropped from the
    /// drain. Empty when `unload()` has never been called.
    public func unloadInFlightSnapshotsObserved() -> [Int] { unloadInFlightSnapshots }

    /// Swap the response mode mid-test.
    public func setBehavior(_ newBehavior: Behavior) {
        behavior = newBehavior
    }

    /// Clear the recorded call log. Behaviour is unchanged.
    public func reset() {
        callLog.removeAll(keepingCapacity: false)
    }
}

/// Failures surfaced by `MockLLMProvider` itself (not by the system
/// under test).
public enum MockLLMProviderError: Error, Equatable, Sendable {
    /// A queued-response mock was called more times than responses were
    /// supplied. Indicates the test is under-specified — enqueue
    /// another response or switch to `.fixedResponse`.
    case responseQueueExhausted
}
