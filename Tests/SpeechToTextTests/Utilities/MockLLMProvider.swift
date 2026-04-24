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
    }

    private var behavior: Behavior
    private var callLog: [Call] = []

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

    // MARK: - LLMProvider

    public func generate(
        prompt: String,
        options: LLMOptions
    ) async throws -> String {
        callLog.append(Call(prompt: prompt, options: options))
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
        }
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
