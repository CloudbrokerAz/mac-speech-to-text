import Foundation

/// Process-wide gate for tests that install `URLProtocolStub`.
///
/// Wrap a test body in `withGate { ... }` so it acquires exclusive access
/// to the singleton's `currentResponder` before installing, and releases
/// when the body exits.
///
/// ## Why this exists
///
/// `URLProtocolStub` keeps a single process-wide `currentResponder`.
/// Swift Testing's `.serialized` trait is **suite-local** — two Swift
/// Testing suites that both stub HTTP race against each other across the
/// suite boundary because the scheduler still parallelises between
/// suites. The race manifests as one suite's `defer { reset() }`
/// clobbering another suite's responder mid-flight, producing
/// `URLError(-2000)` or fall-through to the real network (e.g. PR #84
/// CI commit `964d877`: a Hugging Face 401 against
/// `ModelDownloaderTests.happyPathDownload`).
///
/// XCTest scheduling has empirically coexisted with Swift Testing since
/// #20 without flakes, so XCTest test classes that use `URLProtocolStub`
/// (e.g. `ClinikoClientTests`, `TreatmentNoteExporterTests`) do **not**
/// need to adopt the gate. The gate is only required for Swift Testing
/// `@Test` bodies.
///
/// ## Adoption status
///
/// Adopters as of issue #85:
/// - `Tests/SpeechToTextTests/Services/ModelDownloaderTests.swift`
/// - `Tests/SpeechToTextTests/Services/Cliniko/ClinikoStatusThreadingTests.swift`
///
/// `Tests/SpeechToTextTests/ViewModels/ExportFlowViewModelTests.swift`
/// is a third Swift Testing `@Suite` that calls `URLProtocolStub.install`
/// from a `@MainActor`-isolated context. Migration is tracked separately
/// (the `@MainActor` + `@Sendable` interaction needs a wider refactor
/// than #85's scope) — until that lands, the suite remains protected
/// only by its `.serialized` trait, which is suite-local and therefore
/// still races against gated suites. Treat this as a known gap.
///
/// See `.claude/references/testing-conventions.md` §"URLProtocolStub
/// process-wide gate" and `Sources/Services/Cliniko/AGENTS.md`
/// §Testing for adoption rules. Issue #85.
///
/// ## Usage
///
/// ```swift
/// @Suite("Cliniko status threading", .tags(.fast))
/// struct ClinikoStatusThreadingTests {
///     @Test func sendWithStatus_returns200() async throws {
///         try await URLProtocolStubGate.shared.withGate {
///             let config = URLProtocolStub.install { request in
///                 // ...build response...
///             }
///             defer { URLProtocolStub.reset() }
///             // ...exercise SUT...
///         }
///     }
/// }
/// ```
///
/// ## Cancellation
///
/// Tests do not typically cancel mid-run; if a Task is cancelled while
/// waiting on the gate the queued continuation will never resume and
/// the waiter slot leaks. Acceptable in a test-only utility — production
/// code must not depend on this gate.
///
/// ## Reentrancy
///
/// Non-reentrant: a `withGate` body that recurses into another
/// `withGate` call on the same actor instance will deadlock. Tests
/// should never need this.
actor URLProtocolStubGate {
    /// The singleton every test acquires through.
    static let shared = URLProtocolStubGate()

    /// `true` while a `withGate` body is in flight. Mutated only on the
    /// actor's executor, so no external locking is required.
    private var busy = false

    /// FIFO queue of tasks suspended in `acquire()` waiting for the
    /// gate to free up. `release()` resumes the head waiter directly,
    /// keeping `busy == true` — a hand-off that avoids the
    /// thundering-herd race where every waiter would re-check `busy`
    /// and contend.
    private var waiters: [CheckedContinuation<Void, Never>] = []

    /// Acquire the gate, run `body`, release the gate. Re-throws any
    /// error from `body` after the gate has been released, so a
    /// failing test cannot starve subsequent suites.
    func withGate<T: Sendable>(
        _ body: @Sendable () async throws -> T
    ) async rethrows -> T {
        await acquire()
        // `release()` is sync from inside the actor; the `defer` runs
        // after the `await body()` continuation re-enters via the
        // actor's executor, so calling release() in a `defer` is safe
        // even when `body` throws.
        defer { release() }
        return try await body()
    }

    private func acquire() async {
        if busy {
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                waiters.append(cont)
            }
            // Resumed via `release()` direct hand-off — `busy` is
            // already `true` for us, so no further mutation is needed.
            return
        }
        busy = true
    }

    private func release() {
        if waiters.isEmpty {
            busy = false
            return
        }
        let next = waiters.removeFirst()
        next.resume()
    }
}
