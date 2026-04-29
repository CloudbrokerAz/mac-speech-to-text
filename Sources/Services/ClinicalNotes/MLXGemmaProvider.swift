import Foundation
import MLXLLM
import MLXLMCommon
import OSLog
import Tokenizers

/// Concrete `LLMProvider` running Gemma 4 E4B-IT (MLX 4-bit) in-process via
/// `ml-explore/mlx-swift-lm` on Apple Silicon. Class name retained for
/// continuity across the v1→v2 cutover (#18); the actor body is
/// model-agnostic — `mlx-swift-lm`'s `LLMTypeRegistry` resolves the
/// architecture from the downloaded `config.json`.
///
/// **Issue #3 (v1) / #18 (v2).** This is the production-side counterpart
/// to `MockLLMProvider` shipped in #51. The protocol contract
/// (deterministic defaults, PHI-safe logging, retry-once at the processor
/// level) is unchanged — see `LLMProvider.swift` for the protocol docs
/// and `.claude/references/mlx-lifecycle.md` for the load / warmup /
/// fallback story.
///
/// ### Lifecycle
/// Two-phase init: construct cheaply with the model directory, then
/// `warmup()` to load weights into the `ModelContainer` before the first
/// call. Subsequent `generate` / `generateStream` calls reuse the loaded
/// container. The model is held for the app lifetime — eviction would
/// just force a re-load on the next session, and the dominant cost is
/// the cold mmap + dequantize of ~5 GB of Gemma 4 E4B-IT weights.
///
/// ### Concurrency
/// `actor` per the `LLMProvider: Actor` protocol constraint (mockability —
/// actors cannot be subclassed, see `.claude/references/concurrency.md` §6).
/// The underlying `MLXLMCommon.ModelContainer` is itself a thread-safe
/// `final class Sendable` that serialises model access internally; this
/// actor adds a thin layer of state ownership (`container: ModelContainer?`)
/// and request-shaping. We don't add a second serialisation layer because
/// `ModelContainer` already provides it.
///
/// ### Privacy
/// **Never** logs prompt or response content. Structural values only:
/// token counts, latency, error-case names. The
/// `String(describing: type(of: error))` idiom is the canonical
/// PHI-safe error log shape.
public actor MLXGemmaProvider: LLMProvider {
    /// Errors thrown by `MLXGemmaProvider`. Cases carry only structural
    /// metadata; raw upstream `Error` chains are caught and re-raised as
    /// `.modelLoadFailed(kind:)` / `.generationFailed(kind:)` to prevent
    /// `localizedDescription`-driven PHI leakage.
    public enum ProviderError: Error, Sendable, Equatable {
        /// `ModelContainer` failed to load. `kind` is
        /// `String(describing: type(of: error))`.
        case modelLoadFailed(kind: String)
        /// `prepare(input:)` or `generate(...)` failed mid-flight.
        case generationFailed(kind: String)
        /// `generate` was called before `warmup()` and lazy-load also failed.
        case notLoaded
    }

    private let modelDirectory: URL
    private let tokenizerLoader: any TokenizerLoader
    private let logger: Logger
    private var container: ModelContainer?

    /// - Parameters:
    ///   - modelDirectory: directory holding the manifest's files post-download
    ///     (typically `<app-support>/<bundle-id>/Models/<model-dir>/`).
    ///     `ModelDownloader.ensureModelDownloaded()` produces this URL.
    ///   - tokenizerLoader: defaults to a `swift-transformers` AutoTokenizer
    ///     bridge. Overridable in tests.
    public init(
        modelDirectory: URL,
        tokenizerLoader: (any TokenizerLoader)? = nil
    ) {
        self.modelDirectory = modelDirectory
        self.tokenizerLoader = tokenizerLoader ?? SwiftTransformersTokenizerLoader()
        self.logger = Logger(
            subsystem: Bundle.main.bundleIdentifier ?? "com.cloudbroker.mac-speech-to-text",
            category: "mlx-provider"
        )
    }

    /// Eagerly load weights into a `ModelContainer`. Idempotent — a second
    /// call is a no-op once `container` is set. Wired from the Clinical
    /// Notes Mode toggle in `AppState` so the practitioner pays the
    /// load cost up-front rather than on the first "Generate Notes" tap.
    ///
    /// The "starting" / "completed" OSLog signposts are diagnostic
    /// instrumentation introduced for #106: when the next MLX-related
    /// crash report lands, the surrounding signposts localise whether
    /// we crashed pre- or post-load. Cheap to leave in.
    public func warmup() async throws {
        if container != nil { return }
        let started = ContinuousClock.now
        logger.info("MLX warmup starting")
        do {
            let loaded = try await LLMModelFactory.shared.loadContainer(
                from: modelDirectory,
                using: tokenizerLoader
            )
            container = loaded
            let elapsed = ContinuousClock.now - started
            // Log millisecond-precision so sub-second warmups (the
            // common warm-cache case) don't truncate to "0s".
            let ms = (elapsed.components.seconds * 1_000)
                + Int64(elapsed.components.attoseconds / 1_000_000_000_000_000)
            logger.info(
                "MLX warmup completed in \(ms, privacy: .public)ms"
            )
        } catch {
            let kind = String(describing: type(of: error))
            logger.error("MLX warmup failed kind=\(kind, privacy: .public)")
            throw ProviderError.modelLoadFailed(kind: kind)
        }
    }

    public func generate(
        prompt: String,
        options: LLMOptions
    ) async throws -> String {
        // Reuses the same actor method that backs `generateStream` so
        // both surfaces share one code path. Collect chunks into a
        // single result string.
        var collected = ""
        try await runGeneration(
            prompt: prompt,
            options: options
        ) { chunk in
            collected.append(chunk)
        }
        return collected
    }

    /// Single-task `AsyncThrowingStream` adapter — outer cancellation
    /// (e.g. UI consumer drops the stream) propagates straight through
    /// to `runGeneration`'s `Task.checkCancellation` because there's
    /// only one Task in flight. The earlier shape wrapped one stream
    /// inside another and silently leaked compute on cancel.
    public nonisolated func generateStream(
        prompt: String,
        options: LLMOptions
    ) -> AsyncThrowingStream<String, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task { [weak self] in
                guard let self else {
                    continuation.finish(throwing: ProviderError.notLoaded)
                    return
                }
                do {
                    try await self.runGeneration(
                        prompt: prompt,
                        options: options
                    ) { chunk in
                        continuation.yield(chunk)
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: CancellationError())
                } catch let providerError as ProviderError {
                    continuation.finish(throwing: providerError)
                } catch {
                    let kind = String(describing: type(of: error))
                    self.logGenerationError(kind: kind)
                    continuation.finish(
                        throwing: ProviderError.generationFailed(kind: kind)
                    )
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Internals

    /// Actor-isolated generation core. Accepts a `@Sendable` chunk-yield
    /// closure so both the collect-to-String (`generate`) and stream
    /// (`generateStream`) surfaces share the same stop-sequence flushing
    /// + cancellation behaviour. Throws `CancellationError` directly
    /// when the parent Task is cancelled — the public surfaces translate.
    private func runGeneration(
        prompt: String,
        options: LLMOptions,
        yield: @Sendable (String) -> Void
    ) async throws {
        let container = try await requireContainer()
        let parameters = Self.makeParameters(from: options)
        let stops = options.stop

        let userInput = UserInput(prompt: prompt)
        let prepared = try await container.prepare(input: userInput)
        let stream = try await container.generate(
            input: prepared,
            parameters: parameters
        )

        // Per-chunk autorelease drain. Long async streams + Obj-C bridge
        // work (mlx-swift-lm chunk decoding, OSLog formatting, the
        // `yield` continuation) accumulate temporaries on the actor's
        // executor between suspension points. The canonical Cocoa
        // pattern for any long sync loop containing bridged work is to
        // wrap the body in `autoreleasepool` so each iteration drains
        // independently — see `NSAutoreleasePool` "long-running loop"
        // guidance.
        //
        // Closure-body conventions:
        //   - `try Task.checkCancellation()` stays **outside** the
        //     `autoreleasepool` because Swift's `autoreleasepool` is
        //     non-throwing; cancellation must propagate as a thrown
        //     `CancellationError`, not be swallowed by the closure.
        //   - The closure body is intentionally non-throwing — `yield`
        //     and the string operations don't throw — so we use the
        //     non-`try` form.
        //   - `break` is hoisted to the `shouldBreak` flag so the
        //     post-stop-match emit ordering (yield prefix → break)
        //     survives the closure boundary.
        var pendingTail = ""
        var shouldBreak = false
        for await item in stream {
            try Task.checkCancellation()
            autoreleasepool {
                guard case let .chunk(text) = item else { return }
                if stops.isEmpty {
                    yield(text)
                    return
                }
                pendingTail += text
                if let stopRange = Self.firstStopRange(in: pendingTail, stops: stops) {
                    let prefix = String(pendingTail[..<stopRange.lowerBound])
                    if !prefix.isEmpty {
                        yield(prefix)
                    }
                    shouldBreak = true
                    return
                }
                let safeBoundary = Self.safeFlushBoundary(
                    in: pendingTail,
                    stops: stops
                )
                if safeBoundary > pendingTail.startIndex {
                    let flushable = String(pendingTail[..<safeBoundary])
                    yield(flushable)
                    pendingTail = String(pendingTail[safeBoundary...])
                }
            }
            if shouldBreak { break }
        }
    }

    /// Lazy-load on first call if `warmup()` was skipped — surfaces the same
    /// `.modelLoadFailed` shape so callers can fall back to raw-transcript
    /// (`.rawTranscriptFallback(reason: reasonLLMError)` in the processor).
    private func requireContainer() async throws -> ModelContainer {
        if let container { return container }
        try await warmup()
        guard let container else {
            throw ProviderError.notLoaded
        }
        return container
    }

    /// Logs a `generationFailed` event with PHI-safe `kind` only — no
    /// `localizedDescription`, no prompt, no completion text.
    private nonisolated func logGenerationError(kind: String) {
        // Construct the logger inside the call so this stays nonisolated;
        // the `logger` property is actor-isolated and can't be touched here.
        let log = Logger(
            subsystem: Bundle.main.bundleIdentifier ?? "com.cloudbroker.mac-speech-to-text",
            category: "mlx-provider"
        )
        log.error("MLX generate failed kind=\(kind, privacy: .public)")
    }

    /// Map our `LLMOptions` onto MLX's `GenerateParameters`. `temperature: 0`
    /// triggers MLX's `ArgMaxSampler` (greedy) — `topP` becomes irrelevant
    /// at temperature zero, which is the deterministic default our prompt
    /// builder + JSON-schema guard assume.
    static func makeParameters(from options: LLMOptions) -> GenerateParameters {
        var p = GenerateParameters()
        p.temperature = options.temperature
        p.topP = options.topP
        p.maxTokens = options.maxTokens
        return p
    }

    /// First range of any stop sequence inside `text`. Returns the
    /// earliest match across all stops (greedy-left). Returns `nil` if no
    /// stop is fully present yet — the caller may have only received a
    /// partial match and should keep buffering.
    static func firstStopRange(
        in text: String,
        stops: [String]
    ) -> Range<String.Index>? {
        var earliest: Range<String.Index>?
        for stop in stops where !stop.isEmpty {
            guard let range = text.range(of: stop) else { continue }
            if let current = earliest {
                if range.lowerBound < current.lowerBound {
                    earliest = range
                }
            } else {
                earliest = range
            }
        }
        return earliest
    }

    /// Safe flush boundary when buffering for stop-sequence matching:
    /// returns the largest index up to which we can flush without risking
    /// emitting a partial stop sequence we'd later need to claw back.
    /// Concretely, retain the last `(maxStopLength - 1)` characters.
    static func safeFlushBoundary(
        in text: String,
        stops: [String]
    ) -> String.Index {
        let maxStopLen = stops.map(\.count).max() ?? 0
        let keepBack = max(0, maxStopLen - 1)
        guard text.count > keepBack else { return text.startIndex }
        return text.index(text.endIndex, offsetBy: -keepBack)
    }
}

// MARK: - TokenizerLoader bridge

/// Loads tokenizer files from a local directory via `swift-transformers`
/// (`Tokenizers.AutoTokenizer.from(modelFolder:)`) and wraps the result so
/// it satisfies `MLXLMCommon.Tokenizer`.
///
/// This is the explicit form of `MLXHuggingFace`'s `#huggingFaceTokenizerLoader()`
/// macro — written out by hand to avoid the macro plugin (and the extra
/// `MLXHuggingFace` + `HuggingFace` SPM products) since the bridge is
/// only ~30 lines. If we later want HF Hub-based loading, switching to the
/// macro is a one-line change.
public struct SwiftTransformersTokenizerLoader: TokenizerLoader {
    public init() {}

    public func load(from directory: URL) async throws -> any MLXLMCommon.Tokenizer {
        let upstream = try await Tokenizers.AutoTokenizer.from(modelFolder: directory)
        return SwiftTransformersTokenizerBridge(upstream)
    }
}

/// Bridges `Tokenizers.Tokenizer` (swift-transformers) to
/// `MLXLMCommon.Tokenizer`. Thin pass-through with one shape adjustment:
/// upstream uses `decode(tokens:skipSpecialTokens:)`, downstream uses
/// `decode(tokenIds:skipSpecialTokens:)`.
private struct SwiftTransformersTokenizerBridge: MLXLMCommon.Tokenizer {
    private let upstream: any Tokenizers.Tokenizer

    init(_ upstream: any Tokenizers.Tokenizer) {
        self.upstream = upstream
    }

    func encode(text: String, addSpecialTokens: Bool) -> [Int] {
        upstream.encode(text: text, addSpecialTokens: addSpecialTokens)
    }

    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String {
        upstream.decode(tokens: tokenIds, skipSpecialTokens: skipSpecialTokens)
    }

    func convertTokenToId(_ token: String) -> Int? {
        upstream.convertTokenToId(token)
    }

    func convertIdToToken(_ id: Int) -> String? {
        upstream.convertIdToToken(id)
    }

    var bosToken: String? { upstream.bosToken }
    var eosToken: String? { upstream.eosToken }
    var unknownToken: String? { upstream.unknownToken }

    func applyChatTemplate(
        messages: [[String: any Sendable]],
        tools: [[String: any Sendable]]?,
        additionalContext: [String: any Sendable]?
    ) throws -> [Int] {
        do {
            return try upstream.applyChatTemplate(
                messages: messages,
                tools: tools,
                additionalContext: additionalContext
            )
        } catch Tokenizers.TokenizerError.missingChatTemplate {
            throw MLXLMCommon.TokenizerError.missingChatTemplate
        }
    }
}
