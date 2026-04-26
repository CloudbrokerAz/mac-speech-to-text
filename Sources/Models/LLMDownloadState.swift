import Foundation

/// Coarse-grained UI-binding state for the clinical-notes LLM pipeline
/// (`ModelDownloader` + `MLXGemmaProvider`).
///
/// **Issue #3.** The `@Observable` `AppState` exposes one of these so a
/// future Settings-side download surface can drive a progress sheet,
/// retry button, and "model ready" indicator without reaching into the
/// downloader's per-byte event stream. The granular `bytesReceived`
/// events stay inside the `applyDownloadProgress` aggregator, which
/// updates a separate `Double` property.
///
/// PHI-free by construction — every payload is structural (a directory
/// URL the model lives at) or unit (`Void`-bearing cases).
public enum LLMDownloadState: Sendable, Equatable {
    /// Pipeline has not yet been driven; manifest is bundled but no
    /// download has been attempted this launch.
    case idle

    /// Files are being fetched from Hugging Face. Pair with
    /// `AppState.llmDownloadProgress` for the `[0, 1]` value.
    case downloading

    /// All manifest files present + sha256-verified at `directory`.
    /// Provider warmup is the next step before generation can run.
    case verified(directory: URL)

    /// Model loaded into the `ModelContainer`; `MLXGemmaProvider.generate`
    /// is ready to serve.
    case ready

    /// Active download was cancelled. Re-entering the pipeline resumes
    /// from the next missing file (the downloader is idempotent).
    case cancelled

    /// Last attempt to ensure the model failed (download IO, hash
    /// mismatch, or warmup load failure). The exact cause is logged
    /// structurally; UI surfaces a generic "couldn't prepare model"
    /// with a retry affordance.
    case failed
}
