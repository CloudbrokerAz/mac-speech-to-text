import Foundation
import Observation

/// Owns the clinical-notes Gemma model download / warmup / cancel / remove
/// state machine and the in-flight pipeline task slots (#ARC-1).
/// Extracted from `AppState` so the app root state object delegates rather
/// than embedding ~500 lines of MLX lifecycle bookkeeping.
@MainActor
final class ClinicalNotesModelLifecycleController {
    unowned let host: AppState

    init(host: AppState) {
        self.host = host
    }

    func startClinicalNotesPipeline(transcript: String) {
        // Re-entrant guard for #121 / silent-failure-hunter Scenario 4:
        // if a Settings-initiated `removeClinicalNotesModel()` is mid-drain
        // we must NOT spawn a fresh pipeline — it would re-mmap the model
        // directory we're about to unlink and re-introduce the exact race
        // the drain closes. The Settings row's gate on Remove is one
        // surface; this check covers the menu-bar / hotkey / Generate-Notes
        // surfaces that bypass the Settings UI.
        if host.isRemovingClinicalNotesModel {
            AppLogger.app.info(
                "AppState: clinical-notes hand-off declined — model removal in flight"
            )
            applyClinicalNotesFallback(reasonCode: ClinicalNotesProcessor.reasonModelUnavailable)
            return
        }

        // Re-entrant Generate Notes (a second tap arriving while Pipeline
        // A is still running): cancel A and chain B behind it so A's
        // `runGeneration` unwinds, releases its captured container, and
        // the slot ends up holding only B. Without this chain the slot
        // assignment below would orphan A's task handle — A keeps
        // running, captures the container into a strong local that
        // survives any subsequent `unload()`, and `removeClinicalNotesModel`
        // can no longer drain it (Gemini Code Assist HIGH on PR #124).
        // The previous task is captured into B's body so `await` is
        // legal here in this synchronous notification handler; the
        // slot flips to B immediately so `removeClinicalNotesModel`
        // arriving during B's prologue still finds the load-bearing
        // handle.
        let previousTask = host.clinicalNotesPipelineTask?.task
        previousTask?.cancel()

        // Kick off LLM processing without blocking the UI present.
        // `runClinicalNotesPipeline` ensures-download + warms-up + runs
        // the processor; every terminal branch flips `draftStatus` so
        // the Review screen never silently lingers in `.pending`.
        //
        // The task handle is stored on `host.clinicalNotesPipelineTask` so
        // `removeClinicalNotesModel` can drain it before releasing the
        // ModelContainer (#121). Identity-guarded clear inside the same
        // Task body — mirrors the `host.clinicalNotesDownloadTask` pattern at
        // `downloadClinicalNotesModel` so a re-entrant Generate Notes tap
        // that started a fresh pipeline doesn't have its slot clobbered
        // by the original task's completion path. The clear runs via
        // `clearClinicalNotesPipelineSlotIfMatching(token:)` so this site
        // and `removeClinicalNotesModel` stay in sync.
        let token = UUID()
        let task: Task<Void, Never> = Task { @MainActor [weak self, token, previousTask] in
            // Wait for any cancelled predecessor to fully unwind before
            // we touch the provider. `Task<Void, Never>.value` resolves
            // when the body returns, including via the cancellation
            // path. If `removeClinicalNotesModel` cancels *this* task
            // before the predecessor finishes, we still complete the
            // await (cancellation propagates a level deeper) and then
            // exit before `runClinicalNotesPipeline` starts.
            if let previousTask {
                await previousTask.value
            }
            await self?.runClinicalNotesPipeline(transcript: transcript)
            self?.clearClinicalNotesPipelineSlotIfMatching(token: token)
        }
        host.clinicalNotesPipelineTask = (token: token, task: task)
        host.isClinicalNotesPipelineActive = true
        updateModelStatusMirror()
    }

    #if DEBUG
    /// Test-only seam (#123). Drives the same pipeline-start logic as
    /// the production `.clinicalNotesGenerateRequested` notification
    /// path, minus the `SessionStore.start` + `ReviewWindowController.shared.present()`
    /// side-effects that headless test environments may not support and
    /// that would otherwise risk cross-test interference via the
    /// MainActor-singleton review controller. Tests pre-seed
    /// `host.llmDownloadState = .ready` so the `runClinicalNotesPipeline`
    /// body proceeds straight to the processor (skipping
    /// `downloadClinicalNotesModel`'s MLX-only cast). Compiled out of
    /// release builds.
    func startClinicalNotesPipelineForTesting(transcript: String) {
        startClinicalNotesPipeline(transcript: transcript)
    }
    #endif

    /// Token-guarded clear for `host.clinicalNotesPipelineTask` (#121). Called
    /// from both the pipeline Task body's trailing line and the drain
    /// inside `removeClinicalNotesModel()`; centralising the three
    /// writes (`slot = nil`, `host.isClinicalNotesPipelineActive = false`,
    /// `updateModelStatusMirror()`) prevents the two sites from drifting.
    /// No-op if the slot is empty or holds a different generation —
    /// re-entrant Generate Notes that swapped the slot keeps its slot.
    func clearClinicalNotesPipelineSlotIfMatching(token: UUID) {
        guard host.clinicalNotesPipelineTask?.token == token else { return }
        host.clinicalNotesPipelineTask = nil
        host.isClinicalNotesPipelineActive = false
        updateModelStatusMirror()
    }

    /// Drive the LLM pipeline end-to-end for a single transcript. Idempotent
    /// across model state — re-entry while a download is in flight returns
    /// fast (the downloader is itself idempotent + actor-serialised).
    /// Every terminal branch flips `SessionStore.draftStatus` so the
    /// Review screen surfaces the correct UX (loading overlay, ready
    /// editors, or fallback banner). Failures resolve to a fallback with
    /// a structural reason sentinel — never PHI.
    func runClinicalNotesPipeline(transcript: String) async {
        guard
            let processor = host.clinicalNotesProcessor
        else {
            AppLogger.app.warning(
                "AppState: clinical-notes pipeline unavailable (missing manifest or template)"
            )
            // The Review window is already on screen in `.pending`; flip
            // it to fallback so the editors become interactive and the
            // banner explains why the LLM never ran.
            applyClinicalNotesFallback(reasonCode: ClinicalNotesProcessor.reasonModelUnavailable)
            return
        }

        // Delegate the download+warmup phase to the shared helper so the
        // Settings-side "Download model" button (#104) and the Generate-Notes
        // path drive the same pipeline. The helper updates `host.llmDownloadState`
        // / `host.llmDownloadProgress` / `host.modelStatusViewModel` consistently.
        await downloadClinicalNotesModel()

        // Branch on the helper's terminal state. Cancellation is a distinct
        // user gesture from a network/load failure — same recovery path
        // (deep-link to Settings) but the banner copy differs so the
        // practitioner isn't told "model unavailable" when they actively
        // tapped Cancel (silent-failure-hunter H1).
        switch host.llmDownloadState {
        case .ready:
            break  // proceed to processor
        case .cancelled:
            applyClinicalNotesFallback(reasonCode: ClinicalNotesProcessor.reasonModelDownloadCancelled)
            return
        case .idle, .downloading, .verified, .failed:
            applyClinicalNotesFallback(reasonCode: ClinicalNotesProcessor.reasonModelUnavailable)
            return
        }

        let outcome = await processor.process(transcript: transcript)
        switch outcome {
        case .success(let notes):
            host.sessionStore.setDraftNotes(notes)
            host.sessionStore.setDraftStatus(.ready)
            AppLogger.app.info("AppState: clinical-notes draft populated")
        case .rawTranscriptFallback(let reason):
            AppLogger.app.info(
                "AppState: clinical-notes fell back reason=\(reason, privacy: .public)"
            )
            applyClinicalNotesFallback(reasonCode: reason)
        }
    }

    /// Flip the Review surface to fallback UX with a structural reason
    /// code (`reasonModelUnavailable`, `reasonLLMError`,
    /// `reasonInvalidJSONAfterRetry`, `reasonAllSOAPEmptyAfterRetry`).
    /// Seeds an empty `StructuredNotes` so the editors are interactive
    /// — the doctor edits manually or taps "Insert raw transcript" on
    /// the fallback banner. Idempotent — ordered as draft-then-status
    /// so observers that read the status don't see `.fallback` paired
    /// with a still-`nil` draft.
    func applyClinicalNotesFallback(reasonCode: String) {
        host.sessionStore.setDraftNotes(StructuredNotes())
        host.sessionStore.setDraftStatus(.fallback(reasonCode: reasonCode))
    }

    /// Translate a `ModelDownloader.DownloadProgress` event into the
    /// `@Observable` properties the (future) Settings UI surface binds
    /// against. Aggregates per-file progress into a single overall
    /// `host.llmDownloadProgress` in `[0, 1]` so the bar advances smoothly
    /// across the multi-file manifest (file boundaries no longer leave
    /// the UI looking frozen).
    func applyDownloadProgress(_ event: ModelDownloader.DownloadProgress) {
        // Late events from a torn-down download (terminal `.cancelled` /
        // `.failed` already set) must not advance the progress bar or
        // re-flip state. The progress callback is dispatched via a Task
        // hop, so a `.bytesReceived` queued before cancel can land after
        // `runDownloadAndWarmup`'s catch arm has already terminated state
        // (silent-failure-hunter M1).
        switch host.llmDownloadState {
        case .cancelled, .failed:
            return
        case .idle, .downloading, .verified, .ready:
            break
        }
        switch event {
        case .starting(let totalBytes):
            host.llmDownloadProgress = 0
            host.llmDownloadCompletedBytes = 0
            host.llmDownloadTotalBytes = totalBytes
            host.llmDownloadState = .downloading
        case .fileStarted(let path, let expected):
            AppLogger.app.info(
                "AppState: clinical-notes download begin file=\(path, privacy: .public) bytes=\(expected, privacy: .public)"
            )
        case .bytesReceived(_, let received, let total):
            // Aggregate progress across the whole manifest, not just the
            // active file: previously-completed bytes plus the active
            // file's running tally. Latches at 1.0 so a stale event after
            // `.completed` cannot regress the bar.
            let denom = max(host.llmDownloadTotalBytes, 1)
            let raw = Double(host.llmDownloadCompletedBytes + received) / Double(denom)
            host.llmDownloadProgress = min(max(raw, host.llmDownloadProgress), 1.0)
            _ = total // expected denominator at the per-file level — we use the manifest-wide denom instead
        case .fileVerified(let path):
            // A verified file's bytes graduate from "in flight" to
            // "completed" so the next file's `bytesReceived` rolls up
            // from the right baseline. The manifest is the authority for
            // the file's size.
            if let file = downloadedFileSize(path: path) {
                host.llmDownloadCompletedBytes += file
            }
            AppLogger.app.info(
                "AppState: clinical-notes download verified file=\(path, privacy: .public)"
            )
        case .completed(let dir):
            host.llmDownloadProgress = 1
            host.llmDownloadState = .verified(directory: dir)
        case .cancelled:
            host.llmDownloadState = .cancelled
        }
        updateModelStatusMirror()
    }

    /// Push the latest `host.llmDownloadState` / `host.llmDownloadProgress` /
    /// model-directory into `host.modelStatusViewModel`. Called from every site
    /// that mutates either of the source fields so the Settings UI surface
    /// (#104) never lags the underlying state. Cheap — three property
    /// writes on a `@MainActor`-isolated VM. PHI-free; the model directory
    /// is structural.
    func updateModelStatusMirror() {
        host.modelStatusViewModel.state = host.llmDownloadState
        host.modelStatusViewModel.progress = host.llmDownloadProgress
        host.modelStatusViewModel.isPipelineActive = host.isClinicalNotesPipelineActive
        switch host.llmDownloadState {
        case .verified(let directory):
            host.modelStatusViewModel.modelDirectoryURL = directory
        case .ready:
            // `.verified(directory:)` already wrote `modelDirectoryURL` on
            // the immediately-prior transition. Re-resolving here would be
            // a no-op at best and could mask a desync at worst (type-design
            // analyzer Nit 1). Leave the prior value in place.
            break
        case .idle, .cancelled, .failed:
            host.modelStatusViewModel.modelDirectoryURL = nil
        case .downloading:
            // Keep any prior directory hint until the next terminal state.
            break
        }
    }

    // MARK: - Settings-side model lifecycle (#104)

    /// Trigger a Gemma 4 download + warmup with no transcript and no Review
    /// surface side-effects. Used by the Settings model-status row's
    /// "Download model" / "Retry" actions. Idempotent across model state —
    /// a re-entrant call while a download Task is in flight returns
    /// immediately. Every terminal branch updates `host.llmDownloadState`
    /// + the mirrored `host.modelStatusViewModel`. PHI-free; model bytes only.
    ///
    /// Awaits the in-flight task on re-entry so the caller's `await`
    /// resolves after the model is actually ready. The `Task` storage
    /// makes `cancelClinicalNotesModelDownload()` actionable.
    func downloadClinicalNotesModel() async {
        // Already-ready short-circuit: re-running download/warmup when
        // the model is loaded just causes a `.downloading` → `.verified`
        // → `.ready` UI flicker and a redundant warmup. The Generate-Notes
        // path delegates here on every tap; this gate keeps it fast on
        // the steady-state common case (Gemini Code Assist PR #119).
        if host.llmDownloadState == .ready { return }

        // Re-entry: there's already a download in flight. Await its
        // completion (cancelled-but-still-unwinding tasks complete
        // promptly) and return. We deliberately don't gate on
        // `!isCancelled`: a cancelled task whose body is still running
        // would otherwise let a second caller spawn a parallel task,
        // and our slot can only hold one. The body's catch arm will
        // flip state to `.cancelled` before the task resolves.
        if let existing = host.clinicalNotesDownloadTask {
            await existing.task.value
            return
        }

        guard
            let downloader = host.modelDownloader,
            let provider = host.llmProvider
        else {
            AppLogger.app.warning(
                "AppState: clinical-notes download requested but pipeline unavailable"
            )
            host.llmDownloadState = .failed
            updateModelStatusMirror()
            return
        }
        // `runDownloadAndWarmup` requires the concrete `MLXGemmaProvider`
        // because `warmup()` is MLX-specific (#123 — `LLMProvider`'s
        // protocol surface intentionally stays minimal; warmup stays on
        // the concrete type per the issue's "Out of scope" section). In
        // production this cast is total because `makeLLMPipeline`
        // constructs `MLXGemmaProvider`. In non-hardware tests using a
        // `MockLLMProvider` injected via the `llmPipelineOverride:` init
        // seam, callers MUST pre-set `host.llmDownloadState = .ready` so this
        // method's short-circuit at the top fires before reaching here.
        // The structural-log-and-fail below is the defensive arm for a
        // future test that forgets that pre-condition.
        guard let mlxProvider = provider as? MLXGemmaProvider else {
            AppLogger.app.warning(
                "AppState: clinical-notes download skipped — non-MLX provider injected; tests must pre-set host.llmDownloadState=.ready (#123)"
            )
            host.llmDownloadState = .failed
            updateModelStatusMirror()
            return
        }

        let token = UUID()
        let task: Task<Void, Never> = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.runDownloadAndWarmup(downloader: downloader, provider: mlxProvider)
        }
        host.clinicalNotesDownloadTask = (token: token, task: task)
        await task.value
        // Identity-guarded clear: only nil the slot if it's still the
        // generation we set. `removeClinicalNotesModel()` may have
        // claimed the slot while we were suspended on `task.value`, and
        // an unconditional `= nil` would clobber the fresh task it set.
        if host.clinicalNotesDownloadTask?.token == token {
            host.clinicalNotesDownloadTask = nil
        }
    }

    /// Body of the download + warmup phase, isolated so
    /// `downloadClinicalNotesModel` can store / cancel the wrapping Task.
    /// Mirrors the original inline pipeline shape from
    /// `runClinicalNotesPipeline` — the two now share this implementation.
    func runDownloadAndWarmup(
        downloader: ModelDownloader,
        provider: MLXGemmaProvider
    ) async {
        // Concurrency note: progress events are dispatched via per-event
        // `Task { @MainActor in ... }` hops and can land out of order with
        // respect to each other. `applyDownloadProgress` is hardened to
        // be monotonic (latches at 1.0) and terminal-state-aware (early
        // out on `.cancelled` / `.failed`), so a stale event after this
        // helper has flipped to a terminal state cannot regress UI.
        // Track which phase threw so error logs distinguish a network /
        // hash failure during fetch from an MLX load failure during
        // warmup. Cheap; helps post-mortem on real crash reports.
        var phase = "download"
        do {
            host.llmDownloadState = .downloading
            updateModelStatusMirror()
            let modelDir = try await downloader.ensureModelDownloaded { [weak self] event in
                Task { @MainActor [weak self] in
                    self?.applyDownloadProgress(event)
                }
            }
            host.llmDownloadState = .verified(directory: modelDir)
            updateModelStatusMirror()
            phase = "warmup"
            try await provider.warmup()
            host.llmDownloadState = .ready
            updateModelStatusMirror()
        } catch is CancellationError {
            AppLogger.app.info(
                "AppState: clinical-notes download cancelled phase=\(phase, privacy: .public)"
            )
            if host.llmDownloadState != .cancelled {
                host.llmDownloadState = .cancelled
            }
            updateModelStatusMirror()
        } catch let urlError as URLError where urlError.code == .cancelled {
            // URLSession reifies `Task.cancel()` as `URLError(.cancelled)`
            // for some transports; treat it identically to `CancellationError`
            // so the user-cancel UX matches.
            AppLogger.app.info(
                "AppState: clinical-notes download cancelled (URLError.cancelled) phase=\(phase, privacy: .public)"
            )
            if host.llmDownloadState != .cancelled {
                host.llmDownloadState = .cancelled
            }
            updateModelStatusMirror()
        } catch {
            AppLogger.app.error(
                "AppState: clinical-notes download failed phase=\(phase, privacy: .public) kind=\(String(describing: type(of: error)), privacy: .public)"
            )
            host.llmDownloadState = .failed
            updateModelStatusMirror()
        }
    }

    /// Cancel the active model download / warmup, if any. Safe to call
    /// when no download is in flight — the no-op is the common case
    /// after a `.ready` state is reached. Doesn't await; cancellation
    /// propagates through `Task.cancel()` and lands in the in-flight
    /// task's `catch is CancellationError` arm.
    func cancelClinicalNotesModelDownload() {
        guard let entry = host.clinicalNotesDownloadTask else { return }
        AppLogger.app.info("AppState: cancelling clinical-notes model download")
        entry.task.cancel()
    }

    /// Remove the on-disk Gemma 4 model directory and reset the download
    /// state machine to `.idle`. Used by the Settings row's "Remove" action.
    /// Idempotent — a missing directory is a no-op apart from the state
    /// reset. Cancels any in-flight download first so the `Task` can't
    /// race the unlink.
    ///
    /// PHI-free: only the model directory is touched. The path is logged
    /// as `.private` per `phi-handling.md` (user-home paths count as PII
    /// in the OSLog channel).
    ///
    /// **Release-before-unlink invariant (#120).** When the provider is
    /// `.ready`, its `ModelContainer` mmaps the model directory we're
    /// about to remove. POSIX `removeItem` succeeds even with a live
    /// mmap, but the bytes don't free until the last reference drops —
    /// so we call `await host.llmProvider?.unload()` before the unlink so the
    /// user actually reclaims the ~5 GB they expect from "Remove model".
    /// `unload()` is idempotent and safe to call from any state, so we
    /// don't need to gate on `host.llmDownloadState == .ready`.
    ///
    /// **Pipeline drain (#121).** Before `unload()` we also cancel +
    /// await any in-flight clinical-notes pipeline. `runGeneration`
    /// inside `MLXGemmaProvider` binds the container into a strong local
    /// that survives `host.container = nil` due to actor reentrancy, so
    /// `unload()` alone wouldn't release the mmap if a generate were
    /// suspended on a chunk. Cancelling the wrapping Task trips
    /// `Task.checkCancellation()` in the chunk loop; the processor
    /// catches `CancellationError` and resolves to
    /// `.rawTranscriptFallback(reason: reasonModelRemovedMidFlight)` —
    /// honest UX for "you removed the model mid-stream" — and the
    /// unload is then race-free.
    func removeClinicalNotesModel() async {
        // Block any fresh pipeline from spawning while we're draining +
        // unloading + unlinking. Cleared via `defer` so any early return
        // (no-manifest branch, removeItem failure) leaves the gate open.
        // See `host.isRemovingClinicalNotesModel`'s doc comment for the race
        // this closes (#121, silent-failure-hunter Scenario 4).
        host.isRemovingClinicalNotesModel = true
        defer { host.isRemovingClinicalNotesModel = false }

        cancelClinicalNotesModelDownload()
        // Wait for any cancelled task to unwind before we delete on-disk
        // state — otherwise the downloader's `.partial` rename can race
        // the directory removal. Identity-guarded clear so a re-entrant
        // download started by a parallel caller isn't clobbered.
        if let existing = host.clinicalNotesDownloadTask {
            await existing.task.value
            if host.clinicalNotesDownloadTask?.token == existing.token {
                host.clinicalNotesDownloadTask = nil
            }
        }

        // Drain any in-flight clinical-notes pipeline before we touch
        // the provider (#121). The pipeline calls `processor.process` →
        // `provider.generate` → `MLXGemmaProvider.runGeneration`, which
        // captures the `ModelContainer` into a strong local that
        // survives `host.container = nil` due to Swift actor reentrancy.
        // Cancelling the wrapping Task trips `Task.checkCancellation()`
        // inside the chunk loop; the processor catches `CancellationError`
        // and resolves to `.rawTranscriptFallback(reason:
        // reasonModelRemovedMidFlight)`, so the Review screen flips out
        // of its loading overlay into the banner that names the user's
        // gesture honestly. Identity-guarded clear mirrors the
        // download-task pattern above.
        if let existing = host.clinicalNotesPipelineTask {
            existing.task.cancel()
            await existing.task.value
            clearClinicalNotesPipelineSlotIfMatching(token: existing.token)
        }

        // Release any live `ModelContainer` mmap before unlinking the
        // directory — see the doc comment above for the POSIX rationale.
        // Sequenced after the in-flight task awaits so we can't race a
        // warmup that's about to set `container` or a generation whose
        // local container binding would otherwise pin the mmap past the
        // unlink. Idempotent no-op when the provider was never warmed.
        await host.llmProvider?.unload()

        guard let manifest = host.llmManifest else {
            // No manifest means no `<bundleId>/Models/<dir>/` to clear; just
            // collapse the state machine.
            host.llmDownloadState = .idle
            host.llmDownloadProgress = 0
            host.llmDownloadCompletedBytes = 0
            host.llmDownloadTotalBytes = 0
            updateModelStatusMirror()
            return
        }
        let dir = ModelDownloader.defaultBaseDirectory()
            .appendingPathComponent(manifest.modelDirectoryName, isDirectory: true)
        if FileManager.default.fileExists(atPath: dir.path) {
            do {
                try FileManager.default.removeItem(at: dir)
                AppLogger.app.info(
                    "AppState: removed Gemma 4 model directory at \(dir.path, privacy: .private)"
                )
            } catch {
                // Surface failure as `.failed` (silent-failure-hunter H4):
                // collapsing to `.idle` after a failed unlink would mislead
                // the user into thinking the model is gone, while the next
                // `Download model` tap silently re-uses the still-on-disk
                // bytes — they'd think a re-download succeeded when it
                // never ran. Surface state honestly so the row's "Retry"
                // affordance is reachable.
                AppLogger.app.error(
                    "AppState: failed to remove Gemma 4 model directory kind=\(String(describing: type(of: error)), privacy: .public)"
                )
                host.llmDownloadState = .failed
                updateModelStatusMirror()
                return
            }
        } else {
            AppLogger.app.info("AppState: Gemma 4 model directory already absent")
        }

        host.llmDownloadState = .idle
        host.llmDownloadProgress = 0
        host.llmDownloadCompletedBytes = 0
        host.llmDownloadTotalBytes = 0
        updateModelStatusMirror()
    }

    /// Lookup the manifest-declared size of a file by its repo-relative
    /// path. Returns `nil` for an unknown path so the aggregator can
    /// no-op rather than miscount.
    func downloadedFileSize(path: String) -> Int64? {
        guard let downloader = host.modelDownloader else { return nil }
        // The downloader's manifest is the source of truth. We only need
        // the size lookup, which is cheap and does not require entering
        // the actor — but we don't have direct access to the manifest
        // through the downloader's public API. Cache via the bundled
        // manifest read once at init time. (The manifest is already
        // in-memory inside `makeLLMPipeline`; we save a copy here.)
        _ = downloader
        return host.llmManifest?.files.first(where: { $0.path == path })?.size
    }

}
