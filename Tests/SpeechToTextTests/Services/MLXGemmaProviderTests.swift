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
/// `~/Library/Application Support/<bundle-id>/Models/gemma-3-text-4b-it-4bit/`
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
            .appendingPathComponent("gemma-3-text-4b-it-4bit", isDirectory: true)
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
