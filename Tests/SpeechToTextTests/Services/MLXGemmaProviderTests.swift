import Foundation
import Testing
@testable import SpeechToText

/// `MLXGemmaProvider` tests that don't require a real model on disk.
///
/// **#3.** The provider's parameter mapping and stop-sequence flush logic
/// is pure-logic and stays in the default CI path. Real-inference golden
/// tests live in `MLXGemmaProviderGoldenTests` and are gated on
/// `RUN_MLX_GOLDEN=1` + `.requiresHardware` so CI's macOS-14 runner skips
/// them.
@Suite("MLXGemmaProvider — pure logic", .tags(.fast))
struct MLXGemmaProviderUnitTests {
    @Test("makeParameters maps temperature, topP, maxTokens 1:1")
    func parameterMapping() {
        let opts = LLMOptions(
            temperature: 0.0,
            topP: 1.0,
            maxTokens: 1024,
            seed: 42,
            stop: []
        )
        let p = MLXGemmaProvider.makeParameters(from: opts)
        #expect(p.temperature == 0.0)
        #expect(p.topP == 1.0)
        #expect(p.maxTokens == 1024)
    }

    @Test("makeParameters honours non-default temperature")
    func parameterMappingNonZeroTemp() {
        let opts = LLMOptions(temperature: 0.7, topP: 0.9, maxTokens: 512)
        let p = MLXGemmaProvider.makeParameters(from: opts)
        #expect(p.temperature == 0.7)
        #expect(p.topP == 0.9)
        #expect(p.maxTokens == 512)
    }

    @Test("firstStopRange returns earliest match across multiple stops")
    func firstStopMatchesEarliest() {
        let text = "subjective: ...} more}"
        let r = MLXGemmaProvider.firstStopRange(in: text, stops: ["}", "more"])
        #expect(r != nil)
        // The first `}` appears before `more`, so it wins.
        let prefix = String(text[..<r!.lowerBound])
        #expect(prefix == "subjective: ...")
    }

    @Test("firstStopRange returns nil when no stop is present")
    func firstStopNilWhenAbsent() {
        let r = MLXGemmaProvider.firstStopRange(
            in: "no closer here",
            stops: ["}"]
        )
        #expect(r == nil)
    }

    @Test("firstStopRange ignores empty stop strings")
    func firstStopIgnoresEmpty() {
        let r = MLXGemmaProvider.firstStopRange(in: "any text", stops: [""])
        #expect(r == nil)
    }

    @Test("safeFlushBoundary retains (maxStopLen − 1) characters at the tail")
    func safeFlushBoundaryRetainsTail() {
        let text = "abcdefghij"
        let boundary = MLXGemmaProvider.safeFlushBoundary(
            in: text,
            stops: ["xyz"]
        )
        // maxStopLen=3 → keep back 2 chars.
        let kept = String(text[boundary...])
        #expect(kept.count == 2)
        #expect(kept == "ij")
    }

    @Test("safeFlushBoundary returns startIndex when text shorter than max-stop tail")
    func safeFlushBoundaryShortText() {
        let text = "ab"
        let boundary = MLXGemmaProvider.safeFlushBoundary(
            in: text,
            stops: ["xyz"]
        )
        #expect(boundary == text.startIndex)
    }

    @Test("safeFlushBoundary returns endIndex when no stops are configured")
    func safeFlushBoundaryNoStops() {
        let text = "anything"
        let boundary = MLXGemmaProvider.safeFlushBoundary(in: text, stops: [])
        // maxStopLen=0 → keepBack=0 → boundary at endIndex (full flush OK).
        #expect(boundary == text.endIndex)
    }

    /// **#120 — `unload()` idempotency on a never-warmed provider.**
    /// `unload()` is the load-bearing release used by
    /// `AppState.removeClinicalNotesModel()` to drop the
    /// `ModelContainer` mmap before unlinking the model directory.
    /// The container starts `nil`, so calling `unload()` before any
    /// `warmup()` must be a structural no-op — and a second call must
    /// also no-op. Both must complete without throwing or blocking.
    ///
    /// The warmup → unload → re-warmup state-machine cycle requires
    /// real weights and lives in `MLXGemmaProviderGoldenTests` below
    /// (`RUN_MLX_GOLDEN=1`, `.requiresHardware`).
    @Test("unload is a no-op on a never-warmed provider and is idempotent")
    func unloadIdempotentBeforeWarmup() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mlx-gemma-unload-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: tempDir,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let provider = MLXGemmaProvider(modelDirectory: tempDir)
        // Two calls back-to-back — both must complete cleanly. The
        // assertion is implicit in not throwing or hanging; the actor
        // serialises the calls so a concurrent re-entry can't trip
        // a half-loaded state.
        await provider.unload()
        await provider.unload()
    }

    /// **#106 — warmup error mapping (shape, not specific error type).**
    /// Verifies that `warmup()` catches *any* underlying error from
    /// `LLMModelFactory.shared.loadContainer` and re-raises it as
    /// `ProviderError.modelLoadFailed(kind:)` with a non-empty kind
    /// string. The kind string carries only the type name — never
    /// `localizedDescription` — so PHI in upstream error chains can't
    /// leak. The test asserts the **mapping shape**: empty-dir input is
    /// just a convenient way to provoke any throw from `loadContainer`
    /// (it might be `URLError`, `POSIXError`, an `LLMError` variant,
    /// etc. — we don't care which).
    ///
    /// Stays in the default CI path because no real model load happens —
    /// `loadContainer` fails fast on an empty directory.
    @Test("warmup re-raises load failure as ProviderError.modelLoadFailed")
    func warmupMapsLoadFailure() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mlx-gemma-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: tempDir,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let provider = MLXGemmaProvider(modelDirectory: tempDir)

        do {
            try await provider.warmup()
            Issue.record("warmup() should have thrown on missing weights")
            return
        } catch let error as MLXGemmaProvider.ProviderError {
            guard case .modelLoadFailed(let kind) = error else {
                Issue.record("expected .modelLoadFailed, got \(error)")
                return
            }
            #expect(!kind.isEmpty, "kind must carry the upstream error type name")
        } catch {
            Issue.record("expected ProviderError.modelLoadFailed, got \(type(of: error))")
        }
    }
}

/// Real-inference tests against a downloaded `MLXGemmaProvider`.
///
/// **Gate:** `RUN_MLX_GOLDEN=1` env var + `.requiresHardware` tag. CI's
/// Linux/macOS-14 default path does NOT exercise these. They run on the
/// remote-Mac nightly job (or locally during dev) — see
/// `.claude/references/mlx-lifecycle.md` for the load expectations.
///
/// Each test relies on a model directory either at the path provided in
/// `MLX_GEMMA_DIR` env var, or — if absent — the default
/// `~/Library/Application Support/<bundle-id>/Models/gemma-4-e4b-it-4bit/`
/// produced by `ModelDownloader.ensureModelDownloaded()`.
@Suite("MLXGemmaProvider — real inference", .tags(.slow, .requiresHardware))
struct MLXGemmaProviderGoldenTests {
    private static var enabled: Bool {
        ProcessInfo.processInfo.environment["RUN_MLX_GOLDEN"] == "1"
    }

    private static func modelDirectory() -> URL? {
        if let override = ProcessInfo.processInfo.environment["MLX_GEMMA_DIR"] {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        let base = ModelDownloader.defaultBaseDirectory()
            .appendingPathComponent("gemma-4-e4b-it-4bit", isDirectory: true)
        if FileManager.default.fileExists(atPath: base.path) {
            return base
        }
        return nil
    }

    @Test("warmup loads ModelContainer in < 30s on M-series", .enabled(if: enabled))
    func warmupLoads() async throws {
        guard let dir = Self.modelDirectory() else {
            Issue.record("model directory not available; set MLX_GEMMA_DIR or run downloader first")
            return
        }
        let provider = MLXGemmaProvider(modelDirectory: dir)
        let started = ContinuousClock.now
        try await provider.warmup()
        let elapsed = ContinuousClock.now - started
        let seconds = elapsed.components.seconds
        // Loose budget — load latency varies wildly with thermal state
        // and disk pressure. The hard contract is just "completes".
        #expect(seconds < 30, "warmup took \(seconds)s, expected <30s")
    }

    /// **#120 — warmup → unload → re-warmup state-machine cycle.**
    /// Verifies that `unload()` releases the `ModelContainer` cleanly
    /// enough for a subsequent `warmup()` to repopulate it and a
    /// follow-up `generate` to succeed. The hardware-gated test is the
    /// only place this can run end-to-end; the fast-path counterpart
    /// in `MLXGemmaProviderUnitTests.unloadIdempotentBeforeWarmup`
    /// covers the never-warmed branch.
    @Test("warmup → unload → re-warmup → generate cycle", .enabled(if: enabled))
    func warmupUnloadReWarmupCycle() async throws {
        guard let dir = Self.modelDirectory() else {
            Issue.record("model directory not available; set MLX_GEMMA_DIR or run downloader first")
            return
        }
        let provider = MLXGemmaProvider(modelDirectory: dir)
        try await provider.warmup()
        await provider.unload()
        // Second warmup must succeed against the same on-disk weights.
        try await provider.warmup()
        let opts = LLMOptions(temperature: 0, topP: 1.0, maxTokens: 8, stop: [])
        // PHI-free synthetic prompt per testing-conventions.md — we only
        // assert that `generate` returns without throwing, not on text
        // shape. Re-warmup soundness is the contract under test, not
        // generation quality (covered by `deterministicGeneration`).
        let prompt = "Briefly summarise: morning standup notes."
        _ = try await provider.generate(prompt: prompt, options: opts)
    }

    @Test("greedy generation is deterministic across two calls", .enabled(if: enabled))
    func deterministicGeneration() async throws {
        guard let dir = Self.modelDirectory() else {
            Issue.record("model directory not available")
            return
        }
        let provider = MLXGemmaProvider(modelDirectory: dir)
        try await provider.warmup()

        let opts = LLMOptions(
            temperature: 0,
            topP: 1.0,
            maxTokens: 32,
            stop: []
        )
        // Synthetic, PHI-free clinical wording per
        // .claude/references/testing-conventions.md.
        let prompt = "Briefly summarise: the patient reports left shoulder pain after gardening yesterday."

        let first = try await provider.generate(prompt: prompt, options: opts)
        let second = try await provider.generate(prompt: prompt, options: opts)
        #expect(first == second, "greedy decode (temp=0) must be deterministic")
    }
}
