import Foundation

/// Local LLM abstraction.
///
/// **Issue #3 (v1) / #18 (v2).** Defines the contract
/// `ClinicalNotesProcessor` (#5) binds to. The production implementation —
/// `MLXGemmaProvider` loading Gemma 4 E4B-IT in-process via
/// `ml-explore/mlx-swift-lm` 3.31.x (supersedes v1's Gemma 3 4B-IT) —
/// ships in `MLXGemmaProvider.swift`. Tests use `MockLLMProvider`
/// (`Tests/SpeechToTextTests/Utilities/MockLLMProvider.swift`).
///
/// The protocol is `Actor`-constrained — both `MLXGemmaProvider` and
/// `MockLLMProvider` are actors, and AGENTS.md / `.claude/references/concurrency.md`
/// §6 require mockable services to go through an `Actor`-constrained
/// protocol (Swift actors cannot be subclassed, so test-doubles can't
/// inherit from the concrete type). Callers that store `any LLMProvider`
/// on an `@Observable` class MUST annotate that property
/// `@ObservationIgnored` to avoid the actor-existential crash — see
/// `.claude/references/concurrency.md` §1.
///
/// ### PHI
/// Implementations MUST NOT log `prompt` content or the generated
/// response. `OSLog` with `privacy: .public` is reserved for structural
/// values only — token counts, latency, truncation reasons, error-case
/// names. Thrown errors MUST NOT carry `prompt` or generated-response
/// text in their `localizedDescription` (or any other field that callers
/// might log) — `DecodingError`-style value-quoting is the classic leak
/// vector. See `.claude/references/phi-handling.md`.
public protocol LLMProvider: Actor {
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
    ///
    /// Declared `nonisolated` so callers can build the stream
    /// synchronously from any context; implementations hop back into
    /// the actor via `await` to drive generation.
    nonisolated func generateStream(
        prompt: String,
        options: LLMOptions
    ) -> AsyncThrowingStream<String, any Error>

    /// Release any internal model state so the underlying weights / file
    /// descriptors can be reclaimed. Idempotent — a second call is a
    /// no-op once state has been released. Symmetric counterpart to any
    /// implementation-defined warmup. After `unload()`, the next
    /// `generate` / `generateStream` call MUST behave as if the provider
    /// were freshly constructed (typically by lazy-loading on demand).
    ///
    /// **Caller invariant (#120).** When the on-disk model directory is
    /// being removed, callers MUST `await unload()` before unlinking so
    /// the mmap-backed bytes actually free under POSIX semantics. See
    /// `MLXGemmaProvider.unload()` and `.claude/references/mlx-lifecycle.md`
    /// for the release-before-unlink invariant.
    func unload() async
}

public extension LLMProvider {
    /// Default no-op for providers that have no model state to release
    /// (e.g. trivial test fakes that synthesise responses without
    /// loading weights). Concrete in-process providers like
    /// `MLXGemmaProvider` override this with a real release.
    func unload() async {}
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
