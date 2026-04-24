import Foundation

/// Local LLM abstraction.
///
/// **Issue #3.** Defines the contract `ClinicalNotesProcessor` (#5) binds
/// to. The first concrete implementation — `MLXGemmaProvider` loading
/// Gemma 3 4B-IT in-process via `mlx-swift-examples` — ships in a
/// separate PR against this same ticket. Tests use `MockLLMProvider`
/// (`Tests/SpeechToTextTests/Utilities/MockLLMProvider.swift`).
///
/// Implementations must be `Sendable` and safe to share across tasks.
/// If the concrete type is actor-backed (as `MLXGemmaProvider` will be)
/// and a caller stores it on an `@Observable` class, that property must
/// be annotated `@ObservationIgnored` to avoid the actor-existential
/// crash — see `.claude/references/concurrency.md` §1.
///
/// ### PHI
/// Implementations MUST NOT log `prompt` content or the generated
/// response. `OSLog` with `privacy: .public` is reserved for structural
/// values only — token counts, latency, truncation reasons, error-case
/// names. Thrown errors MUST NOT carry `prompt` or generated-response
/// text in their `localizedDescription` (or any other field that callers
/// might log) — `DecodingError`-style value-quoting is the classic leak
/// vector. See `.claude/references/phi-handling.md`.
public protocol LLMProvider: Sendable {
    /// Generate a full completion for `prompt` using `options`.
    ///
    /// Implementations surface inference, tokenisation, and
    /// resource-exhaustion failures as throws. A "model returned no
    /// tokens" condition is a valid empty `String`, not a throw —
    /// callers distinguish "empty completion" from "generation failed"
    /// by inspecting the returned value vs. catching.
    func generate(
        prompt: String,
        options: LLMOptions
    ) async throws -> String

    /// Stream text fragments as they are produced.
    ///
    /// Each element is one or more UTF-8 text fragments; callers
    /// reassemble by appending in order. Cancelling the awaiting task
    /// cancels the underlying generation if the implementation supports
    /// it. Terminal errors are delivered via the stream, not thrown
    /// from this factory.
    func generateStream(
        prompt: String,
        options: LLMOptions
    ) -> AsyncThrowingStream<String, any Error>
}

/// Sampling configuration for a single `LLMProvider` call.
///
/// Defaults are **deterministic** — temperature `0` and a fixed `seed`
/// — so clinical-notes generation is reproducible across runs for the
/// same transcript, per the EPIC #1 contract. Callers that want
/// nondeterminism (e.g. exploratory UIs) opt in explicitly by raising
/// `temperature` and/or setting `seed` to `nil`.
public struct LLMOptions: Sendable, Equatable {
    /// Sampling temperature. `0` yields greedy decoding.
    public var temperature: Float
    /// Top-p nucleus sampling cutoff in `[0, 1]`. Ignored at temperature 0.
    public var topP: Float
    /// Hard upper bound on generated tokens. Implementations may stop
    /// earlier on stop-sequence hit or EOS.
    public var maxTokens: Int
    /// Deterministic seed. `nil` asks the implementation to pick (which
    /// makes the call non-reproducible).
    public var seed: UInt64?
    /// Strings that terminate generation when produced. Matched
    /// greedy-left; the matched sequence is not included in the
    /// returned string.
    public var stop: [String]

    public init(
        temperature: Float = 0,
        topP: Float = 1.0,
        maxTokens: Int = 1024,
        seed: UInt64? = 42,
        stop: [String] = []
    ) {
        self.temperature = temperature
        self.topP = topP
        self.maxTokens = maxTokens
        self.seed = seed
        self.stop = stop
    }
}
