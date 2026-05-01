import Foundation
import Testing

/// Pins the `URLProtocolStubGate` contract: serialised access across
/// concurrent tasks and gate release on a throwing body. The gate is
/// the only mechanism keeping cross-suite Swift Testing tests from
/// clobbering each other's `URLProtocolStub` responder, so a regression
/// here would re-open the race observed in PR #84 CI commit
/// `964d877`. See issue #85.
///
/// FIFO ordering of queued waiters is *not* asserted: the use case
/// (URLProtocolStub callers needing exclusive responder access) only
/// requires mutual exclusion, not order, and asserting order without
/// internal-state visibility is flake bait under CI scheduling jitter.
@Suite("URLProtocolStubGate", .tags(.fast))
struct URLProtocolStubGateTests {

    /// Sendable scratchpad for tests that hand work between concurrent
    /// tasks and the body being asserted on.
    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [String] = []

        func append(_ value: String) {
            lock.lock(); defer { lock.unlock() }
            values.append(value)
        }

        var snapshot: [String] {
            lock.lock(); defer { lock.unlock() }
            return values
        }
    }

    @Test("single task can acquire the gate without contention")
    func singleAcquire_runsBody() async throws {
        let gate = URLProtocolStubGate()
        let result: Int = try await gate.withGate { 42 }
        #expect(result == 42)
    }

    /// The core serialisation pin. Two tasks both call `withGate`; the
    /// gate must guarantee their bodies do **not** interleave. Uses
    /// `AsyncStream` signals rather than `Task.sleep` so the test is
    /// deterministic regardless of scheduler jitter — the failure mode
    /// of a sleep-based variant would be the exact kind of CI flake
    /// the gate exists to prevent.
    @Test("concurrent acquirers do not interleave bodies")
    func concurrentAcquirers_areSerialised() async throws {
        let gate = URLProtocolStubGate()
        let recorder = Recorder()

        // A signals when it's holding the gate; the test signals A to
        // release. This makes A's hold deterministic without timing.
        let (aHoldingStream, aHoldingCont) = AsyncStream<Void>.makeStream()
        let (aReleaseStream, aReleaseCont) = AsyncStream<Void>.makeStream()

        let aTask = Task {
            await gate.withGate {
                recorder.append("A-start")
                aHoldingCont.yield(())
                aHoldingCont.finish()
                for await _ in aReleaseStream { break }
                recorder.append("A-end")
            }
        }

        // Block until A is actually holding the gate. Pin that we
        // saw the signal — a future refactor that forgets the
        // `yield` would make `aHoldingStream` finish without a
        // value, the for-loop would exit silently, and the test
        // would race forward and pass for the wrong reason. The
        // explicit flag makes that regression fail loudly.
        var sawAHolding = false
        for await _ in aHoldingStream {
            sawAHolding = true
            break
        }
        #expect(sawAHolding, "A should have signalled it was holding the gate")

        // Spawn B *after* A is holding. Whether B queues on the
        // continuation list or arrives just-in-time after A releases,
        // the gate must serialise B's body behind A's body. Both code
        // paths through `acquire()` (busy vs not-busy) satisfy the
        // assertion, so the test is robust without observing internal
        // state.
        let bTask = Task {
            await gate.withGate {
                recorder.append("B-start")
                recorder.append("B-end")
            }
        }

        // Release A. B's body proceeds — never before this point.
        aReleaseCont.yield(())
        aReleaseCont.finish()

        await aTask.value
        await bTask.value

        #expect(recorder.snapshot == ["A-start", "A-end", "B-start", "B-end"])
    }

    @Test("throwing body still releases the gate so subsequent acquirers proceed")
    func throwingBody_releasesGate() async throws {
        struct BoomError: Error {}
        let gate = URLProtocolStubGate()

        await #expect(throws: BoomError.self) {
            try await gate.withGate { throw BoomError() }
        }

        // Second acquirer must not deadlock — runs to completion.
        let didRun = Recorder()
        try await gate.withGate {
            didRun.append("ran")
        }
        #expect(didRun.snapshot == ["ran"])
    }
}
