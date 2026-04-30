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
