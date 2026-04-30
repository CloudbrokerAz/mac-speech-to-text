import Foundation
import Testing
@testable import SpeechToText

/// Swift Testing coverage for the new Settings-side model lifecycle methods
/// on `AppState` (#104, Deliverable A): `cancelClinicalNotesModelDownload()`
/// and `removeClinicalNotesModel()`. The full download path is exercised by
/// `MLXGemmaProviderGoldenTests` (gated on `RUN_MLX_GOLDEN=1` and
/// `.requiresHardware`); we don't repeat that here. These tests are
/// `.fast` — pure state-machine / file-cleanup checks against a real
/// `AppState`, no network or LLM inference.
@Suite("AppState model status (#104)", .tags(.fast))
@MainActor
struct AppStateModelStatusTests {

    @Test("cancelClinicalNotesModelDownload is safe with no active task")
    func cancelClinicalNotesModelDownload_safeWhenNoneInFlight() async {
        let appState = AppState()
        // Default state at fresh init: nothing in flight, slot is nil.
        // Cancel must be a structural no-op — no crash, no state change.
        appState.cancelClinicalNotesModelDownload()
        appState.cancelClinicalNotesModelDownload()
        #expect(appState.llmDownloadState == .idle)
    }

    @Test("removeClinicalNotesModel resets state to idle")
    func removeClinicalNotesModel_resetsState() async {
        let appState = AppState()
        // Force the state machine into a non-idle state so we can witness
        // the reset. We use the public mirror surface: writing the
        // `@Observable` properties directly is the same path the pipeline
        // uses internally.
        appState.llmDownloadState = .failed
        appState.llmDownloadProgress = 0.5

        await appState.removeClinicalNotesModel()

        #expect(appState.llmDownloadState == .idle)
        #expect(appState.llmDownloadProgress == 0)
        // The mirrored VM follows.
        #expect(appState.modelStatusViewModel.state == .idle)
        #expect(appState.modelStatusViewModel.progress == 0)
        #expect(appState.modelStatusViewModel.modelDirectoryURL == nil)
    }

    @Test("removeClinicalNotesModel deletes an on-disk fixture directory when present")
    func removeClinicalNotesModel_deletesFixtureDirectory() async throws {
        let appState = AppState()
        // We can only meaningfully exercise the `removeItem` branch if the
        // bundled manifest loaded. In pathological dev builds without the
        // manifest, AppState wires `llmManifest = nil` and `removeClinicalNotesModel`
        // collapses to the "no manifest" branch — which still resets state
        // (already covered by the previous test), so we soft-skip here.
        guard let manifest = appState.llmManifest else {
            // The structural pre-condition didn't hold; still assert
            // state-only behaviour is correct, then return.
            await appState.removeClinicalNotesModel()
            #expect(appState.llmDownloadState == .idle)
            return
        }
        let dir = ModelDownloader.defaultBaseDirectory()
            .appendingPathComponent(manifest.modelDirectoryName, isDirectory: true)

        // Seed a marker file inside the model directory so we can prove
        // the unlink ran. Using a tiny placeholder keeps disk churn cheap.
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let marker = dir.appendingPathComponent("test-marker.txt")
        try Data("marker".utf8).write(to: marker)
        #expect(FileManager.default.fileExists(atPath: marker.path))

        await appState.removeClinicalNotesModel()

        #expect(!FileManager.default.fileExists(atPath: marker.path))
        #expect(!FileManager.default.fileExists(atPath: dir.path))
        #expect(appState.llmDownloadState == .idle)
        #expect(appState.modelStatusViewModel.state == .idle)
    }

    /// **#120 — `.ready` → remove collapses to `.idle` without
    /// the bridge warning that PR #119 emitted.**
    ///
    /// PR #119 added a structural `OSLog.warning` on the `.ready → remove`
    /// path as a bridge until `MLXGemmaProvider.unload()` shipped (#120).
    /// This test pins down the post-#120 contract: forcing `.ready` then
    /// calling `removeClinicalNotesModel()` collapses cleanly to `.idle`
    /// — and the `await llmProvider?.unload()` call sequenced into the
    /// remove path neither throws nor hangs.
    ///
    /// In tests the `llmProvider` is the real `MLXGemmaProvider` (the
    /// manifest is bundled at `Sources/Resources/Models/.../manifest.json`),
    /// but it has not been warmed in this test, so `unload()` resolves
    /// to its idempotent no-op branch (`guard container != nil`). We
    /// can't observe the mmap release without real weights — that's
    /// covered by the hardware-gated `warmupUnloadReWarmupCycle` test
    /// in `MLXGemmaProviderGoldenTests`.
    @Test("removeClinicalNotesModel from .ready collapses to .idle")
    func removeClinicalNotesModel_fromReady_collapsesToIdle() async {
        let appState = AppState()
        appState.llmDownloadState = .ready

        await appState.removeClinicalNotesModel()

        #expect(appState.llmDownloadState == .idle)
        #expect(appState.modelStatusViewModel.state == .idle)
    }

    /// **#121 — `removeClinicalNotesModel()` clears its in-flight gate
    /// even on the no-manifest early return.**
    /// `isRemovingClinicalNotesModel` is set at the top of the function
    /// and cleared by `defer` so an early-return branch (e.g. the
    /// no-manifest path that flushes state without touching the
    /// directory) can't leave the gate stuck — which would block all
    /// subsequent Generate Notes hand-offs forever. We can't read the
    /// private flag directly, but we can prove the gate clears by
    /// calling `removeClinicalNotesModel()` twice in sequence and
    /// asserting the second call also resolves cleanly to `.idle`. If
    /// the flag had stuck `true`, internal logic that depends on it
    /// (e.g. fresh pipeline short-circuit) would be observable, but at
    /// the AppState public surface this is the cleanest pin.
    @Test("removeClinicalNotesModel clears its in-flight gate via defer")
    func removeClinicalNotesModel_clearsGateAcrossRepeatedCalls() async {
        let appState = AppState()
        await appState.removeClinicalNotesModel()
        #expect(appState.llmDownloadState == .idle)
        await appState.removeClinicalNotesModel()
        #expect(appState.llmDownloadState == .idle)
    }

    /// **#121 — `isClinicalNotesPipelineActive` defaults false at init
    /// and is mirrored into the VM.**
    /// AppState init must NOT spawn a pipeline (no recording has happened
    /// yet), so the gate the row uses to disable Remove must be `false`.
    /// The mirror call inside `updateModelStatusMirror` (driven by
    /// `removeClinicalNotesModel`'s `.idle` no-op write) propagates the
    /// flag onto the VM as `isPipelineActive`. Pinning down both axes
    /// here protects against a regression that left the gate stuck
    /// `true` after init.
    @Test("isClinicalNotesPipelineActive defaults false and mirrors into VM")
    func isClinicalNotesPipelineActive_defaultsFalseAndMirrors() async {
        let appState = AppState()
        #expect(appState.isClinicalNotesPipelineActive == false)
        #expect(appState.modelStatusViewModel.isPipelineActive == false)

        // A no-op remove flushes through `updateModelStatusMirror()` so
        // we observe the propagation into the VM end-to-end.
        await appState.removeClinicalNotesModel()
        #expect(appState.modelStatusViewModel.isPipelineActive == false)
    }

    @Test("modelStatusViewModel mirrors manifest size at init")
    func modelStatusViewModel_mirrorsManifestSize() async {
        let appState = AppState()
        // The wired VM reflects the bundled manifest. We don't assert on a
        // hard-coded byte count (it bumps with manifest revisions); we just
        // confirm the wiring delivers the same value the manifest carries.
        let expected = appState.llmManifest?.totalBytes ?? 0
        #expect(appState.modelStatusViewModel.manifestSizeBytes == expected)
    }
}
