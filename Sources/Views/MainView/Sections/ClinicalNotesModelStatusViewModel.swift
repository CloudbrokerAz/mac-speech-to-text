// ClinicalNotesModelStatusViewModel.swift
// macOS Local Speech-to-Text Application
//
// Issue #104 (Deliverable A) — Settings-side surface for the Gemma 4 model
// download lifecycle. Mirrors the relevant `AppState` properties so the
// `ClinicalNotesModelStatusRow` view can bind without reaching into the
// app-wide observable. PHI-free by construction — the model bytes and
// directory are not patient-adjacent. See `.claude/references/mlx-lifecycle.md`
// for the lifecycle this VM surfaces and `.claude/references/phi-handling.md`
// for the logging policy (this VM logs nothing on its own).

import Foundation
import Observation

/// Observable state for the "Model status" row inside `ClinicalNotesSection`.
///
/// `AppState` constructs and owns one instance, mirrors its own
/// `llmDownloadState` / `llmDownloadProgress` into this VM, and routes the
/// three user actions (Download, Cancel, Remove) through injected closures.
/// Defaulting the closures to no-ops keeps `ClinicalNotesModelStatusRowTests`
/// dependency-free.
///
/// Concurrency: `@Observable @MainActor` — the closures cross the actor
/// boundary as `@Sendable` so the row's button taps can fire them
/// directly. Callers run them inside a `Task { await ... }` from the UI.
@Observable
@MainActor
final class ClinicalNotesModelStatusViewModel {
    /// Mirrors `AppState.llmDownloadState`. Drives every visible affordance
    /// in the row — pill copy, button shape, progress-bar visibility.
    var state: LLMDownloadState

    /// Mirrors `AppState.llmDownloadProgress`, in `[0, 1]`. Only consulted
    /// while `state == .downloading`. Clamped at the property so consumers
    /// (the row's progress bar, the About-section pill) don't have to
    /// repeat the clamp at every read site (type-design-analyzer suggestion).
    var progress: Double {
        didSet {
            let clamped = min(max(progress, 0), 1)
            // `didSet` re-fires on a self-write only when the new value
            // differs, so the loop terminates on the first tail call.
            if clamped != progress { progress = clamped }
        }
    }

    /// Manifest's `total_bytes`. May be `0` if the bundled manifest is
    /// missing — in that pathological case the row reads "Gemma 4 E4B-IT —
    /// 0 bytes" rather than crashing. The byte-count formatter handles 0
    /// gracefully ("Zero KB").
    var manifestSizeBytes: Int64

    /// Set when the model directory has been verified on disk. Surfaced in
    /// the disk-usage caption row that only appears in `.ready`.
    var modelDirectoryURL: URL?

    /// Mirrors `AppState.isClinicalNotesPipelineActive` (#121). When `true`,
    /// the Settings-row "Remove" button must be disabled — releasing the
    /// `ModelContainer` mid-generation cannot reclaim the mmap-backed
    /// bytes (Swift actor reentrancy + a strong local container binding
    /// inside `runGeneration`), so the row gates the affordance until
    /// the active pipeline completes. The drain inside
    /// `AppState.removeClinicalNotesModel()` is the load-bearing
    /// correctness mechanism; this flag drives the UX gate that keeps
    /// users from hitting the post-cancel fallback banner unnecessarily.
    var isPipelineActive: Bool

    /// Tap handler for the primary "Download model" / "Retry" affordance.
    /// `@Sendable` so the row can fire it from a `Task` without capturing
    /// VM state. Defaults to a no-op so test fixtures don't have to wire
    /// production hooks.
    @ObservationIgnored let onDownload: @Sendable () async -> Void

    /// Tap handler for the "Cancel" affordance — visible during
    /// `.downloading` and during the post-download `.verified` warmup
    /// window where cancel is still meaningful.
    @ObservationIgnored let onCancel: @Sendable () async -> Void

    /// Tap handler for the "Remove" affordance — visible when the model is
    /// `.ready`. Removes the on-disk directory and resets state.
    @ObservationIgnored let onRemove: @Sendable () async -> Void

    /// Production wiring constructor. `AppState.init` calls this with
    /// closures that route to `AppState.downloadClinicalNotesModel()`,
    /// `cancelClinicalNotesModelDownload()`, and `removeClinicalNotesModel()`.
    init(
        state: LLMDownloadState = .idle,
        progress: Double = 0,
        manifestSizeBytes: Int64 = 0,
        modelDirectoryURL: URL? = nil,
        isPipelineActive: Bool = false,
        onDownload: @escaping @Sendable () async -> Void = {},
        onCancel: @escaping @Sendable () async -> Void = {},
        onRemove: @escaping @Sendable () async -> Void = {}
    ) {
        self.state = state
        self.progress = progress
        self.manifestSizeBytes = manifestSizeBytes
        self.modelDirectoryURL = modelDirectoryURL
        self.isPipelineActive = isPipelineActive
        self.onDownload = onDownload
        self.onCancel = onCancel
        self.onRemove = onRemove
    }
}
