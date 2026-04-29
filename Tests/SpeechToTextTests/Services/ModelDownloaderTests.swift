import Foundation
import Testing
import CryptoKit
@testable import SpeechToText

@Suite("ModelDownloader", .tags(.fast), .serialized)
struct ModelDownloaderTests {
    // MARK: - Serialisation note
    //
    // `.serialized` is load-bearing: `URLProtocolStub` keeps a single
    // global `currentResponder`, and `URLProtocolStub.install` /
    // `URLProtocolStub.reset` mutate it. Tests running in parallel
    // would race — one's `defer { reset() }` would null the responder
    // mid-flight in another test, falling through to the real network
    // (HF, which 401s unauthenticated requests). Per-suite serialisation
    // scopes the global cleanly.
    // MARK: - Test scaffolding

    /// Per-test temp directory. Each test creates a fresh sub-folder so the
    /// downloader's atomic-rename + idempotency machinery has a clean slate.
    private static func makeTempBase() throws -> URL {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("model-downloader-tests")
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: tmp,
            withIntermediateDirectories: true
        )
        return tmp
    }

    /// Small canned manifest with a 4-byte payload `"hello"`'s prefix
    /// `"hell"` so we can pre-compute the sha256 once and reuse across
    /// tests that exercise the verification path.
    private static let helloPayload = Data("hell".utf8) // 4 bytes
    private static let helloSHA256: String = {
        let digest = SHA256.hash(data: helloPayload)
        return digest.map { String(format: "%02x", $0) }.joined()
    }()

    private static func helloManifest(includeHash: Bool = true) -> ModelManifest {
        ModelManifest(
            modelId: "fixtures/hello-model",
            revision: "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef",
            files: [
                ModelFile(
                    path: "weights.bin",
                    size: Int64(helloPayload.count),
                    sha256: includeHash ? helloSHA256 : nil
                )
            ]
        )
    }

    private static func makeOKResponder(
        path: String = "/fixtures/hello-model/resolve/deadbeefdeadbeefdeadbeefdeadbeefdeadbeef/weights.bin",
        body: Data = helloPayload
    ) -> @Sendable (URLRequest) throws -> (HTTPURLResponse, Data) {
        return { request in
            let url = request.url ?? URL(string: "https://huggingface.co\(path)")!
            let response = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Length": "\(body.count)"]
            )!
            return (response, body)
        }
    }

    // MARK: - Idempotency

    @Test("second call is a no-op when files already verify")
    func idempotentSkipWhenFilesPresent() async throws {
        let base = try Self.makeTempBase()
        defer { try? FileManager.default.removeItem(at: base) }

        // Pre-place a verified copy at <base>/<model-dir>/weights.bin.
        let modelDir = base.appendingPathComponent("hello-model", isDirectory: true)
        try FileManager.default.createDirectory(
            at: modelDir,
            withIntermediateDirectories: true
        )
        try Self.helloPayload.write(
            to: modelDir.appendingPathComponent("weights.bin")
        )

        // The responder should NEVER fire — if it does, the test fails.
        let config = URLProtocolStub.install { _ in
            Issue.record("Downloader should not have made any requests")
            throw URLError(.cancelled)
        }
        defer { URLProtocolStub.reset() }

        let downloader = ModelDownloader(
            manifest: Self.helloManifest(),
            baseDirectory: base,
            session: URLSession(configuration: config)
        )
        let resolved = try await downloader.ensureModelDownloaded()
        #expect(resolved == modelDir)
    }

    @Test("emits .completed exactly once on the no-download path")
    func noDownloadProgressEvents() async throws {
        let base = try Self.makeTempBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let modelDir = base.appendingPathComponent("hello-model", isDirectory: true)
        try FileManager.default.createDirectory(
            at: modelDir,
            withIntermediateDirectories: true
        )
        try Self.helloPayload.write(
            to: modelDir.appendingPathComponent("weights.bin")
        )

        let events = EventCollector()
        let config = URLProtocolStub.install { _ in
            Issue.record("Should not request anything")
            throw URLError(.cancelled)
        }
        defer { URLProtocolStub.reset() }

        let downloader = ModelDownloader(
            manifest: Self.helloManifest(),
            baseDirectory: base,
            session: URLSession(configuration: config)
        )
        _ = try await downloader.ensureModelDownloaded { events.append($0) }
        let captured = await events.snapshot()
        // Single .completed — no .starting / .fileStarted because the
        // pre-flight loop short-circuited.
        #expect(captured.count == 1)
        if case .completed = captured.first {} else {
            Issue.record("expected .completed first, got \(String(describing: captured.first))")
        }
    }

    // MARK: - Happy-path download

    @Test("downloads, verifies sha256, and atomically writes the file")
    func happyPathDownload() async throws {
        let base = try Self.makeTempBase()
        defer { try? FileManager.default.removeItem(at: base) }

        let config = URLProtocolStub.install(Self.makeOKResponder())
        defer { URLProtocolStub.reset() }

        let downloader = ModelDownloader(
            manifest: Self.helloManifest(),
            baseDirectory: base,
            session: URLSession(configuration: config)
        )
        let resolved = try await downloader.ensureModelDownloaded()
        let written = try Data(
            contentsOf: resolved.appendingPathComponent("weights.bin")
        )
        #expect(written == Self.helloPayload)
    }

    @Test("happy path emits .starting → .fileStarted → .fileVerified → .completed")
    func happyPathProgressOrdering() async throws {
        let base = try Self.makeTempBase()
        defer { try? FileManager.default.removeItem(at: base) }

        let events = EventCollector()
        let config = URLProtocolStub.install(Self.makeOKResponder())
        defer { URLProtocolStub.reset() }

        let downloader = ModelDownloader(
            manifest: Self.helloManifest(),
            baseDirectory: base,
            session: URLSession(configuration: config)
        )
        _ = try await downloader.ensureModelDownloaded { events.append($0) }

        let captured = await events.snapshot()
        // Loose check on event sequence — .bytesReceived may or may not
        // fire for a 4-byte file depending on the chunk-flush threshold,
        // so we assert structure not exact count.
        guard captured.count >= 3 else {
            Issue.record("expected ≥3 events, got \(captured.count)")
            return
        }
        if case .starting = captured.first {} else {
            Issue.record("first event should be .starting")
        }
        let last = captured.last
        if case .completed = last {} else {
            Issue.record("last event should be .completed; got \(String(describing: last))")
        }
        // .fileVerified must appear once for our single file.
        let verifiedCount = captured.filter {
            if case .fileVerified = $0 { return true } else { return false }
        }.count
        #expect(verifiedCount == 1)
    }

    // MARK: - Error paths

    @Test("HTTP 404 raises .httpStatus")
    func http404SurfacesAsHTTPStatus() async throws {
        let base = try Self.makeTempBase()
        defer { try? FileManager.default.removeItem(at: base) }

        let config = URLProtocolStub.install { request in
            let url = request.url ?? URL(string: "https://huggingface.co/")!
            let response = HTTPURLResponse(
                url: url,
                statusCode: 404,
                httpVersion: "HTTP/1.1",
                headerFields: nil
            )!
            return (response, Data())
        }
        defer { URLProtocolStub.reset() }

        let downloader = ModelDownloader(
            manifest: Self.helloManifest(),
            baseDirectory: base,
            session: URLSession(configuration: config)
        )
        await #expect(throws: ModelDownloader.DownloaderError.self) {
            _ = try await downloader.ensureModelDownloaded()
        }
    }

    @Test("size mismatch raises .sizeMismatch and does not move the partial file into place")
    func sizeMismatchRaises() async throws {
        let base = try Self.makeTempBase()
        defer { try? FileManager.default.removeItem(at: base) }

        // Manifest expects 4 bytes; we serve 8.
        let config = URLProtocolStub.install(
            Self.makeOKResponder(body: Data("hellworld".utf8))
        )
        defer { URLProtocolStub.reset() }

        let downloader = ModelDownloader(
            manifest: Self.helloManifest(),
            baseDirectory: base,
            session: URLSession(configuration: config)
        )
        do {
            _ = try await downloader.ensureModelDownloaded()
            Issue.record("expected sizeMismatch; succeeded instead")
        } catch let err as ModelDownloader.DownloaderError {
            if case .sizeMismatch = err {} else {
                Issue.record("expected .sizeMismatch; got \(err)")
            }
        }
        // No file at the final destination, no `.partial` lingering.
        let dest = base
            .appendingPathComponent("hello-model")
            .appendingPathComponent("weights.bin")
        let partial = base
            .appendingPathComponent("hello-model")
            .appendingPathComponent("weights.bin.partial")
        #expect(!FileManager.default.fileExists(atPath: dest.path))
        #expect(!FileManager.default.fileExists(atPath: partial.path))
    }

    @Test("hash mismatch raises .hashMismatch")
    func hashMismatchRaises() async throws {
        let base = try Self.makeTempBase()
        defer { try? FileManager.default.removeItem(at: base) }

        // Right size (4 bytes), wrong content.
        let config = URLProtocolStub.install(
            Self.makeOKResponder(body: Data("XXXX".utf8))
        )
        defer { URLProtocolStub.reset() }

        let downloader = ModelDownloader(
            manifest: Self.helloManifest(),
            baseDirectory: base,
            session: URLSession(configuration: config)
        )
        do {
            _ = try await downloader.ensureModelDownloaded()
            Issue.record("expected hashMismatch; succeeded instead")
        } catch let err as ModelDownloader.DownloaderError {
            if case .hashMismatch = err {} else {
                Issue.record("expected .hashMismatch; got \(err)")
            }
        }
    }

    @Test("nil manifest sha256 → size-only check passes when bytes match")
    func nilSha256SizeOnlyPasses() async throws {
        let base = try Self.makeTempBase()
        defer { try? FileManager.default.removeItem(at: base) }

        // Wrong content but right size, manifest doesn't carry a hash.
        let config = URLProtocolStub.install(
            Self.makeOKResponder(body: Data("XXXX".utf8))
        )
        defer { URLProtocolStub.reset() }

        let downloader = ModelDownloader(
            manifest: Self.helloManifest(includeHash: false),
            baseDirectory: base,
            session: URLSession(configuration: config)
        )
        _ = try await downloader.ensureModelDownloaded()
        let written = try Data(
            contentsOf: base
                .appendingPathComponent("hello-model")
                .appendingPathComponent("weights.bin")
        )
        #expect(written == Data("XXXX".utf8))
    }

    // MARK: - URL composition

    @Test("HF URL composes from <model-id>/resolve/<revision>/<path>")
    func huggingFaceURLShape() throws {
        let url = try ModelDownloader.huggingFaceURL(
            modelId: "mlx-community/gemma-4-e4b-it-4bit",
            revision: "cc3b666c01c20395e0dcebd53854504c7d9821f9",
            path: "model.safetensors"
        )
        #expect(url.absoluteString
                == "https://huggingface.co/mlx-community/gemma-4-e4b-it-4bit/resolve/cc3b666c01c20395e0dcebd53854504c7d9821f9/model.safetensors")
    }

    @Test("HF URL rejects malformed inputs")
    func huggingFaceURLRejectsMalformed() {
        // Each of these must throw rather than silently producing a
        // degenerate URL that lands as a misleading 404 in production.
        for bad in [
            // (modelId, revision, path)
            ("", "rev", "f"),                // empty modelId
            ("noslash", "rev", "f"),         // modelId without /
            ("a/b", "", "f"),                // empty revision
            ("a/b", "rev", ""),              // empty path
            ("a/b", "rev", "/abs"),          // absolute path
            ("a/b", "rev", "../etc/passwd"), // traversal
            ("a/b", "rev", "x/../y")         // embedded traversal
        ] {
            #expect(throws: ModelDownloader.DownloaderError.self) {
                _ = try ModelDownloader.huggingFaceURL(
                    modelId: bad.0,
                    revision: bad.1,
                    path: bad.2
                )
            }
        }
    }

    // MARK: - waitForFileBytes (issue #94)

    @Test("waitForFileBytes returns immediately when the file already has expected bytes")
    func waitForFileBytes_returnsWhenSizeAlreadySatisfied() async throws {
        let base = try Self.makeTempBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let file = base.appendingPathComponent("ready.bin")
        try Self.helloPayload.write(to: file)

        let size = try await ModelDownloader.waitForFileBytes(
            at: file,
            expectedBytes: Int64(Self.helloPayload.count)
        )
        #expect(size == Int64(Self.helloPayload.count))
    }

    @Test("waitForFileBytes resolves once a delayed writer reaches the expected size")
    func waitForFileBytes_returnsOnceFileGrowsToExpected() async throws {
        let base = try Self.makeTempBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let file = base.appendingPathComponent("growing.bin")
        // Start as a 0-byte file — mimics URLSession's tempURL the moment
        // download(for:) returns but before the writer thread has flushed.
        try Data().write(to: file)

        // Background writer: appends the payload after ~50 ms, simulating
        // the URLSession writer thread catching up after the continuation
        // has already resumed.
        let payload = Self.helloPayload
        let target = file
        Task.detached {
            try? await Task.sleep(nanoseconds: 50_000_000) // 50 ms
            try? payload.write(to: target)
        }

        let size = try await ModelDownloader.waitForFileBytes(
            at: file,
            expectedBytes: Int64(payload.count),
            timeoutSeconds: 2.0
        )
        #expect(size == Int64(payload.count))
    }

    @Test("waitForFileBytes returns the actually-observed size when the file never reaches expected")
    func waitForFileBytes_returnsObservedSizeOnTimeout() async throws {
        let base = try Self.makeTempBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let file = base.appendingPathComponent("short.bin")
        // 1 byte, never grows. Short timeout — the helper waits the
        // full deadline (no stable-plateau optimisation) and returns
        // the last-observed size so the caller's sizeMismatch
        // diagnostic carries the actually-observed count, not 0.
        try Data("x".utf8).write(to: file)

        let size = try await ModelDownloader.waitForFileBytes(
            at: file,
            expectedBytes: 100,
            timeoutSeconds: 0.05
        )
        #expect(size == 1)
    }

    @Test("waitForFileBytes returns 0 when the file does not exist within the timeout")
    func waitForFileBytes_returnsZeroForMissingFile() async throws {
        let base = try Self.makeTempBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let missing = base.appendingPathComponent("never-created.bin")

        let size = try await ModelDownloader.waitForFileBytes(
            at: missing,
            expectedBytes: 4,
            timeoutSeconds: 0.05
        )
        #expect(size == 0)
    }

    // MARK: - Streamed sha256 helper

    @Test("sha256Hex(of:) matches CryptoKit one-shot hash")
    func sha256MatchesCryptoKit() async throws {
        let base = try Self.makeTempBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let file = base.appendingPathComponent("payload.bin")
        let data = Data((0..<10_000).map { UInt8($0 & 0xff) })
        try data.write(to: file)

        let oneShot = SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
        let streamed = try await ModelDownloader.sha256Hex(of: file)
        #expect(streamed == oneShot)
    }
}

// MARK: - Helpers

/// Sendable accumulator for `DownloadProgress` events. Synchronous lock
/// rather than an actor: the downloader's progress callback shape is
/// `@Sendable (DownloadProgress) -> Void` (sync), and an actor-backed
/// implementation that fire-and-forgets a `Task` introduces a race
/// against the test's read where pending appends may not have drained
/// even after `Task.yield()`. A lock-protected box appends synchronously
/// from the callback site so `snapshot()` always sees every event.
private final class EventCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [ModelDownloader.DownloadProgress] = []

    func append(_ event: ModelDownloader.DownloadProgress) {
        lock.lock()
        events.append(event)
        lock.unlock()
    }

    func snapshot() async -> [ModelDownloader.DownloadProgress] {
        lock.lock()
        defer { lock.unlock() }
        return events
    }
}
