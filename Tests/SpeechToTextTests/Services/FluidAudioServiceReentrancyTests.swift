import Foundation
import Testing
@testable import SpeechToText

/// Reentrancy-guard tests for `FluidAudioService` (#40d).
///
/// Covers the single-flight `transcribeInFlight` + `transcribeWaiters`
/// queue introduced to serialise reentrant `transcribe()` calls against
/// the non-`Sendable`, non-actor `AsrManager` SDK class. See
/// `Sources/Services/FluidAudioService.swift` type-level doc-comment for
/// the architectural framing and `.claude/references/concurrency.md` §2
/// for the `nonisolated(unsafe)` justification pattern.
///
/// Swift Testing rather than `XCTestCase` per the styleguide: new
/// pure-logic / async tests use `@Test` / `@Suite` / `#expect`. The
/// older `FluidAudioServiceTests.XCTestCase` continues to host the
/// pre-existing init / language / shutdown / error-description cases.
@Suite("FluidAudioService reentrancy guard (#40d)")
struct FluidAudioServiceReentrancyTests {
    /// Smoke test for the single-flight wrapper boilerplate: under
    /// contention the wrapper does not deadlock, does not crash, and
    /// every concurrent call surfaces `notInitialized` rather than
    /// mismatched / mixed errors. Exercises the *fast* path; the
    /// *wait* path is covered by `serialisesConcurrentCallsViaWaitPath`.
    @Test(
        "Concurrent calls on uninitialised service all return notInitialized",
        .tags(.fast)
    )
    func concurrentCalls_allReturnNotInitialized() async {
        let service = FluidAudioService()
        let samples: [Int16] = Array(repeating: 100, count: 1600)
        let callCount = 8

        let errors: [Error?] = await withTaskGroup(of: Error?.self) { group in
            for _ in 0..<callCount {
                group.addTask {
                    do {
                        _ = try await service.transcribe(
                            samples: samples,
                            sampleRate: 16_000.0
                        )
                        return nil
                    } catch {
                        return error
                    }
                }
            }
            var collected: [Error?] = []
            for await error in group { collected.append(error) }
            return collected
        }

        #expect(errors.count == callCount)
        for error in errors {
            #expect((error as? FluidAudioError) == .notInitialized)
        }
    }

    /// Forces the *wait* path of the single-flight guard: the holder is
    /// kept in flight long enough that subsequent callers genuinely
    /// queue on `transcribeWaiters`. Verifies FIFO hand-off works
    /// (every caller gets resumed) without a missed `resume()` (which
    /// would hang the test) and proves serialisation by asserting the
    /// elapsed wall-clock approaches `callCount × delay`.
    ///
    /// Tagged `.slow` because the simulated delay × 5 callers takes
    /// ~250ms — well above the project's `.fast` budget.
    @Test(
        "Wait path: concurrent calls serialise via single-flight queue",
        .tags(.slow)
    )
    func serialisesConcurrentCallsViaWaitPath() async {
        let service = FluidAudioService(
            simulatedError: .transcription,
            transcribeSimulatedDelay: .milliseconds(50)
        )
        let samples: [Int16] = Array(repeating: 100, count: 1600)
        let callCount = 5
        let started = Date()

        let errors: [Error?] = await withTaskGroup(of: Error?.self) { group in
            for _ in 0..<callCount {
                group.addTask {
                    do {
                        _ = try await service.transcribe(
                            samples: samples,
                            sampleRate: 16_000.0
                        )
                        return nil
                    } catch {
                        return error
                    }
                }
            }
            var collected: [Error?] = []
            for await error in group { collected.append(error) }
            return collected
        }
        let elapsed = Date().timeIntervalSince(started)

        #expect(errors.count == callCount)
        for error in errors {
            if case .transcriptionFailed = error as? FluidAudioError {
                // pass
            } else {
                Issue.record("Expected .transcriptionFailed, got \(String(describing: error))")
            }
        }

        // If the calls had run *concurrently* (guard broken), elapsed
        // would be ~one delay. Forgiving lower bound (75%) absorbs
        // test-runner jitter while still catching a fully-broken guard.
        let lowerBound = Double(callCount) * 0.050 * 0.75
        #expect(
            elapsed >= lowerBound,
            "expected serialised execution (~\(callCount) × 50ms), got \(elapsed)s"
        )
    }

    /// After concurrent calls all complete, the service must be ready
    /// to accept another call — i.e. the in-flight slot was released.
    /// Catches the bug class where the slot is handed to a waiter on
    /// the failure path but the flag never clears (next caller hangs).
    @Test(
        "Service is usable after contention (slot is released cleanly)",
        .tags(.fast)
    )
    func isUsableAfterContention() async {
        let service = FluidAudioService()
        let samples: [Int16] = Array(repeating: 100, count: 1600)

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<4 {
                group.addTask {
                    _ = try? await service.transcribe(samples: samples, sampleRate: 16_000.0)
                }
            }
        }

        do {
            _ = try await service.transcribe(samples: samples, sampleRate: 16_000.0)
            Issue.record("Expected throw .notInitialized; call returned a result")
        } catch let error as FluidAudioError {
            #expect(error == .notInitialized)
        } catch {
            Issue.record("Wrong error type: \(error)")
        }
    }

    /// Verifies that `shutdown()` drains queued waiters so their
    /// `CheckedContinuation`s don't leak (the runtime would surface a
    /// "leaked checked continuation" warning) and their callers don't
    /// hang forever. Uses the wait-path delay seam to ensure waiters
    /// are genuinely queued before shutdown.
    ///
    /// Tagged `.slow` because the holder's 200ms delay is what gives
    /// the queued caller time to enter the wait path before we tear
    /// the service down.
    @Test(
        "shutdown() drains queued waiters so their continuations don't hang",
        .tags(.slow)
    )
    func shutdown_drainsQueuedWaiters() async {
        let service = FluidAudioService(
            simulatedError: .transcription,
            transcribeSimulatedDelay: .milliseconds(200)
        )
        let samples: [Int16] = Array(repeating: 100, count: 1600)

        async let holder: Error? = {
            do {
                _ = try await service.transcribe(samples: samples, sampleRate: 16_000.0)
                return nil
            } catch {
                return error
            }
        }()
        try? await Task.sleep(for: .milliseconds(20))

        async let queued: Error? = {
            do {
                _ = try await service.transcribe(samples: samples, sampleRate: 16_000.0)
                return nil
            } catch {
                return error
            }
        }()
        try? await Task.sleep(for: .milliseconds(20))

        await service.shutdown()

        let holderError = await holder
        let queuedError = await queued

        // Both calls return (no hang). The holder finishes its simulated
        // delay then throws transcriptionFailed. The queued caller is
        // woken by shutdown's drain; it then hits the notInitialized
        // guard inside runTranscribe (asrManager is now nil).
        #expect(holderError != nil, "holder should have surfaced an error")
        #expect(queuedError != nil, "queued caller should have surfaced an error")
    }
}
