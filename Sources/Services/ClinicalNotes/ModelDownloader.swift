import CryptoKit
import Foundation
import OSLog

/// Downloads + verifies the bundled `ModelManifest`'s files into a stable
/// on-disk location for `MLXGemmaProvider` to mmap from.
///
/// **Issue #3 (v1) / #18 (v2).** The clinical-notes LLM (~5.2 GB of
/// MLX 4-bit Gemma 4 E4B-IT weights — supersedes v1's 2.6 GB Gemma 3
/// 4B-IT) is **not** bundled in the .app — see the locked-decision
/// update in `.claude/CLAUDE.md` and `.claude/references/mlx-lifecycle.md`.
/// The downloader fetches the manifest's files from Hugging Face on
/// first run (triggered by the user enabling Clinical Notes Mode in
/// Settings, the same `warmup()` hook that pre-loads the model),
/// verifies sha256 against the manifest, and atomically renames into
/// `~/Library/Application Support/<bundle-id>/Models/<model-dir>/`.
///
/// ### Privacy
/// Manifest data, file paths, byte counts, and HF URLs are all PHI-free
/// by construction. `OSLog` calls use `privacy: .public` for these values.
/// The downloader **never** sees transcripts, draft notes, or any
/// patient-identifying data — those live downstream in
/// `SessionStore` / `ClinicalNotesProcessor`.
///
/// ### Concurrency
/// `actor` for single-threaded mutation of the download state. The progress
/// callback is `@Sendable` and may be invoked from inside the actor's
/// executor; UI layers should hop to `@MainActor` themselves rather than
/// relying on this actor's isolation. `Task.checkCancellation()` is honoured
/// at every per-file boundary so a cancelled `Settings` toggle does not
/// leak a 5 GB download.
public actor ModelDownloader {
    /// PHI-free progress event surfaced via the optional callback to
    /// `ensureModelDownloaded(progress:)`. Every payload field is structural
    /// — sizes, paths, error tags — never user content.
    public enum DownloadProgress: Sendable, Equatable {
        /// Download began. `totalBytes` is the manifest sum; the UI layer
        /// uses it as the progress-bar denominator.
        case starting(totalBytes: Int64)
        /// A specific file began transferring (or was skipped because it
        /// already exists + verifies). `expectedBytes` is the manifest size.
        case fileStarted(path: String, expectedBytes: Int64)
        /// Cumulative bytes received for the current file. The UI layer
        /// rolls up across files itself; we don't aggregate here so the
        /// per-file callback shape is simple.
        case bytesReceived(path: String, received: Int64, total: Int64)
        /// File finished + verified. Atomically renamed into place.
        case fileVerified(path: String)
        /// All files present + verified.
        case completed(directory: URL)
        /// Cancelled mid-flight. Idempotent re-call will resume from the
        /// next missing file.
        case cancelled
    }

    /// Sendable callback shape for progress reporting. `nil` to suppress.
    public typealias ProgressCallback = @Sendable (DownloadProgress) -> Void

    /// Errors thrown by `ensureModelDownloaded`. Cases carry only structural
    /// metadata — never PHI, never raw `Error` chains that might quote
    /// downstream PHI.
    public enum DownloaderError: Error, Equatable, Sendable {
        /// Hugging Face responded with a non-2xx status. `path` is the
        /// manifest-relative file path; `status` is the HTTP code.
        case httpStatus(path: String, status: Int)
        /// Bytes received do not match the manifest's `size`.
        case sizeMismatch(path: String, expected: Int64, got: Int64)
        /// Computed sha256 does not match the manifest's `sha256`.
        case hashMismatch(path: String)
        /// Network / I/O failure. `kind` is `String(describing: type(of: error))`
        /// — captures the error class without stringifying its contents.
        case io(path: String, kind: String)
        /// Manifest is malformed (missing keys, negative sizes, etc.).
        case malformedManifest(reason: String)
        /// Disk-space pre-check failed. `availableBytes` is the volume's
        /// "important usage" capacity at the time of the check.
        case insufficientDiskSpace(needed: Int64, available: Int64)
    }

    private let manifest: ModelManifest
    private let baseDirectory: URL
    private let session: URLSession
    private let logger: Logger

    /// - Parameters:
    ///   - manifest: pinned `ModelManifest` (typically loaded from
    ///     `Resources/Models/<model-dir>/manifest.json` via `Bundle.main`).
    ///   - baseDirectory: parent directory under which `<model-dir>/` is
    ///     written. Defaults to `~/Library/Application Support/<bundle-id>/Models/`.
    ///   - session: injected for tests (`URLProtocolStub`); production uses
    ///     `URLSession.shared`.
    public init(
        manifest: ModelManifest,
        baseDirectory: URL? = nil,
        session: URLSession = .shared
    ) {
        self.manifest = manifest
        if let baseDirectory {
            self.baseDirectory = baseDirectory
        } else {
            self.baseDirectory = Self.defaultBaseDirectory()
        }
        self.session = session
        self.logger = Logger(
            subsystem: Bundle.main.bundleIdentifier ?? "com.cloudbroker.mac-speech-to-text",
            category: "model-downloader"
        )
    }

    /// Per-bundle Application-Support root. Falls back to the Caches
    /// directory if Application Support is somehow unavailable, so the
    /// downloader still functions on pathological environments where
    /// the system directory is missing or unwritable.
    public static func defaultBaseDirectory() -> URL {
        let fm = FileManager.default
        let bundleId = Bundle.main.bundleIdentifier ?? "com.cloudbroker.mac-speech-to-text"
        let root: URL
        if let appSupport = try? fm.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) {
            root = appSupport
        } else if let caches = try? fm.url(
            for: .cachesDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) {
            root = caches
        } else {
            // Last-resort: tmp. This branch is essentially unreachable on
            // a normal macOS install — both Application Support and Caches
            // would have to be inaccessible — but never crash on launch.
            root = URL(fileURLWithPath: NSTemporaryDirectory())
        }
        return root
            .appendingPathComponent(bundleId, isDirectory: true)
            .appendingPathComponent("Models", isDirectory: true)
    }

    /// Idempotent: returns immediately if every manifest file is already
    /// present at the expected size + (when supplied) sha256. Otherwise
    /// downloads the missing/stale ones, verifies, and atomically renames
    /// into place.
    ///
    /// Returns the directory containing the verified model files —
    /// `<baseDirectory>/<modelDirName>/`.
    public func ensureModelDownloaded(
        progress: ProgressCallback? = nil
    ) async throws -> URL {
        let modelDir = try makeModelDirectory()
        let needsBytes = try await bytesToDownload(into: modelDir)
        if needsBytes == 0 {
            logger.info("Model already complete at \(modelDir.path, privacy: .public)")
            progress?(.completed(directory: modelDir))
            return modelDir
        }

        try preflightDiskSpace(needed: needsBytes)
        progress?(.starting(totalBytes: manifest.totalBytes))

        for file in manifest.files {
            try Task.checkCancellation()
            let dest = modelDir.appendingPathComponent(file.path)
            if try await fileSatisfiesManifest(file, at: dest) {
                progress?(.fileVerified(path: file.path))
                continue
            }
            progress?(.fileStarted(path: file.path, expectedBytes: file.size))
            try await downloadAndVerify(file: file, into: modelDir, progress: progress)
            progress?(.fileVerified(path: file.path))
        }

        progress?(.completed(directory: modelDir))
        logger.info("Model download verified at \(modelDir.path, privacy: .public)")
        return modelDir
    }

    // MARK: - Cancellation
    //
    // There is no explicit `cancel()` on this actor: cancellation flows
    // through Swift structured concurrency. Cancel the parent `Task` that
    // called `ensureModelDownloaded(progress:)` and `URLSession.download(for:)`
    // unwinds via `CancellationError`, which the per-file catch translates
    // into a `.cancelled` progress event before re-throwing. A previous
    // shape held a `URLSessionDataTask?` field for explicit cancel — that
    // was dead code after the refactor to `download(for:)` and was removed
    // (Gemini Code Assist on PR #70).

    // MARK: - Internals

    /// On-disk model directory (`<baseDirectory>/<modelDirName>/`). The
    /// directory name is derived from the manifest's `modelId` so two
    /// different models can coexist on disk. See
    /// `ModelManifest.modelDirectoryName` for the derivation rule.
    private func makeModelDirectory() throws -> URL {
        let dir = baseDirectory.appendingPathComponent(
            manifest.modelDirectoryName,
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: dir,
            withIntermediateDirectories: true
        )
        return dir
    }

    /// Sum of bytes still required to satisfy the manifest. 0 means every
    /// file is already complete + verified.
    private func bytesToDownload(into modelDir: URL) async throws -> Int64 {
        var total: Int64 = 0
        for file in manifest.files {
            let dest = modelDir.appendingPathComponent(file.path)
            if try await fileSatisfiesManifest(file, at: dest) {
                continue
            }
            total += file.size
        }
        return total
    }

    /// Per-file completeness check. Size must match exactly; sha256 must
    /// match when the manifest carries one. A `nil` manifest hash means
    /// "size-only check, integrity bounded by the manifest revision pin".
    private func fileSatisfiesManifest(
        _ file: ModelFile,
        at url: URL
    ) async throws -> Bool {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        guard let size = attrs?[.size] as? Int64, size == file.size else {
            return false
        }
        guard let expectedHash = file.sha256, !expectedHash.isEmpty else {
            return true
        }
        let actual = try await Self.sha256Hex(of: url)
        return actual.caseInsensitiveCompare(expectedHash) == .orderedSame
    }

    /// Download + verify + atomic-rename a single file.
    ///
    /// Uses `URLSession.download(for:)` rather than `bytes(for:)`. Two
    /// reasons: (a) per-byte AsyncSequence iteration over a multi-GB
    /// body is wall-clock catastrophic — billions of suspensions and
    /// `Data.append` calls; (b) `download(for:)` propagates Swift
    /// `CancellationError` through `Task.cancel()` cleanly, whereas
    /// `bytes(for:)` reifies cancellation into `URLError(.cancelled)`,
    /// which would land in the generic `catch` and surface as
    /// `DownloaderError.io` rather than the user-friendly `.cancelled`
    /// progress event. Hashing happens after the download via
    /// `Self.sha256Hex(of:)`, which streams in 4 MB chunks off disk.
    ///
    /// Limitation acknowledged (Gemini Code Assist, PR #70): the async
    /// `download(for:)` returns the full body to a temp URL and surfaces
    /// no intra-file progress, so the UI bar is static during a single
    /// large file (the ~5.2 GB `model.safetensors` dominates wall-clock).
    /// A `URLSessionDownloadDelegate`-based shape would surface
    /// per-byte progress at the cost of a delegate seam + Sendable-shaped
    /// progress closure marshalling. Deferred until the Settings UI for
    /// download progress is actually wired (today's UI consumer is just
    /// the `AppState.llmDownloadProgress` observable, which advances at
    /// per-file boundaries). Tracked as a follow-up.
    private func downloadAndVerify(
        file: ModelFile,
        into modelDir: URL,
        progress: ProgressCallback?
    ) async throws {
        let url = try Self.huggingFaceURL(
            modelId: manifest.modelId,
            revision: manifest.revision,
            path: file.path
        )
        let request = URLRequest(url: url)

        let tempURL: URL
        let response: URLResponse
        do {
            (tempURL, response) = try await session.download(for: request)
        } catch is CancellationError {
            progress?(.cancelled)
            throw CancellationError()
        } catch let urlError as URLError where urlError.code == .cancelled {
            // URLSession reifies `Task.cancel()` into `URLError(.cancelled)`
            // for some transports. Map back to the structural shape so UI
            // sees `.cancelled`, not `.io(URLError)`.
            progress?(.cancelled)
            throw CancellationError()
        } catch {
            throw DownloaderError.io(
                path: file.path,
                kind: String(describing: type(of: error))
            )
        }

        try Self.assertHTTPSuccess(response: response, path: file.path)

        // Wait for URLSession's internal writer to finish flushing
        // `tempURL` before we touch it. `download(for:)`'s continuation
        // can resume before the writer has drained all delegate-buffered
        // body bytes to the temp file — surfacing as transient
        // `sizeMismatch(expected:N, got:0)` (issue #94). Polling the
        // size attribute is cheap on the happy path (one stat) and
        // gives up promptly when the file is genuinely short, so the
        // size guard below still produces the correct diagnostic for
        // a real short response.
        let durableTempSize = try await Self.waitForFileBytes(
            at: tempURL,
            expectedBytes: file.size
        )
        guard durableTempSize == file.size else {
            try? FileManager.default.removeItem(at: tempURL)
            throw DownloaderError.sizeMismatch(
                path: file.path,
                expected: file.size,
                got: durableTempSize
            )
        }

        // After the download completes, validate size against the
        // manifest *before* the (more expensive) sha256 hash. We move
        // the temp file into our `<file>.partial` slot first so the
        // verify step is atomic with the rename and any failure leaves
        // a single recoverable artifact rather than two.
        let partialURL = modelDir.appendingPathComponent("\(file.path).partial")
        try FileManager.default.createDirectory(
            at: partialURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if FileManager.default.fileExists(atPath: partialURL.path) {
            try FileManager.default.removeItem(at: partialURL)
        }
        try FileManager.default.moveItem(at: tempURL, to: partialURL)

        try await verifyAndRename(
            file: file,
            partialURL: partialURL,
            modelDir: modelDir,
            progress: progress
        )
    }

    /// Validate size + sha256 (when supplied), then atomic-rename
    /// `<file>.partial` → `<file>`. Cleans the partial on any failure.
    /// `progress.bytesReceived` is emitted once at full size for UI
    /// feedback (the underlying `download(for:)` API does not surface
    /// streaming progress; per-file `.fileStarted` / `.fileVerified`
    /// remain the primary granularity).
    private func verifyAndRename(
        file: ModelFile,
        partialURL: URL,
        modelDir: URL,
        progress: ProgressCallback?
    ) async throws {
        let attrs = try FileManager.default.attributesOfItem(atPath: partialURL.path)
        let written = (attrs[.size] as? Int64) ?? -1
        guard written == file.size else {
            try? FileManager.default.removeItem(at: partialURL)
            throw DownloaderError.sizeMismatch(
                path: file.path,
                expected: file.size,
                got: written
            )
        }
        progress?(.bytesReceived(
            path: file.path,
            received: written,
            total: file.size
        ))

        if let expected = file.sha256, !expected.isEmpty {
            let actualHex = try await Self.sha256Hex(of: partialURL)
            guard actualHex.caseInsensitiveCompare(expected) == .orderedSame else {
                try? FileManager.default.removeItem(at: partialURL)
                throw DownloaderError.hashMismatch(path: file.path)
            }
        }

        let dest = modelDir.appendingPathComponent(file.path)
        do {
            if FileManager.default.fileExists(atPath: dest.path) {
                try FileManager.default.removeItem(at: dest)
            }
            try FileManager.default.moveItem(at: partialURL, to: dest)
        } catch {
            // If the destination overwrite fails (permissions, race),
            // the partial file would otherwise linger and `bytesToDownload`
            // wouldn't notice (it only checks `dest`). Clean it explicitly.
            try? FileManager.default.removeItem(at: partialURL)
            throw DownloaderError.io(
                path: file.path,
                kind: String(describing: type(of: error))
            )
        }
    }

    /// Common HTTP-success guard. Pulled out so the parent download
    /// function stays inside the cyclomatic-complexity budget.
    /// `NonHTTPResponse` is defensive cruft for `URLProtocolStub`-driven
    /// tests; `URLSession` over HTTPS always produces `HTTPURLResponse`
    /// in production.
    private static func assertHTTPSuccess(
        response: URLResponse,
        path: String
    ) throws {
        guard let http = response as? HTTPURLResponse else {
            throw DownloaderError.io(path: path, kind: "NonHTTPResponse")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw DownloaderError.httpStatus(path: path, status: http.statusCode)
        }
    }

    /// Disk-space precondition: caller needs `needed` bytes plus a small
    /// headroom buffer. Throws `insufficientDiskSpace` on shortage so the
    /// UI layer can tell the user *before* a multi-GB download starts and
    /// inevitably fails halfway.
    private func preflightDiskSpace(needed: Int64) throws {
        let buffer: Int64 = 256 * 1024 * 1024 // 256 MB headroom
        let required = needed + buffer
        let values = try? baseDirectory.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey]
        )
        // `volumeAvailableCapacityForImportantUsageKey` is the
        // user-perspective free space (purgeable + free). nil means we
        // couldn't measure; do not block the download in that case.
        guard let available = values?.volumeAvailableCapacityForImportantUsage else {
            return
        }
        if available < required {
            throw DownloaderError.insufficientDiskSpace(
                needed: required,
                available: available
            )
        }
    }

    // MARK: - Static helpers

    /// `https://huggingface.co/<model-id>/resolve/<revision>/<path>` — HF's
    /// stable, redirect-followed URL pattern. URLSession follows the
    /// 302 → CDN redirect transparently.
    ///
    /// Throws `DownloaderError.malformedManifest` rather than silently
    /// returning a degenerate URL — the prior shape would have surfaced
    /// a misleading `httpStatus(404)` from `huggingface.co/` in release
    /// builds while only `assertionFailure`-ing in debug. Path validation
    /// (no `..`, non-empty, no leading `/`) is repeated here as
    /// belt-and-braces against `ModelFile`'s decode-time check.
    static func huggingFaceURL(
        modelId: String,
        revision: String,
        path: String
    ) throws -> URL {
        guard !modelId.isEmpty, modelId.contains("/") else {
            throw DownloaderError.malformedManifest(reason: "modelId")
        }
        guard !revision.isEmpty else {
            throw DownloaderError.malformedManifest(reason: "revision")
        }
        guard !path.isEmpty,
              !path.hasPrefix("/"),
              !path.contains("..") else {
            throw DownloaderError.malformedManifest(reason: "path:\(path)")
        }
        var components = URLComponents()
        components.scheme = "https"
        components.host = "huggingface.co"
        components.path = "/\(modelId)/resolve/\(revision)/\(path)"
        guard let url = components.url else {
            throw DownloaderError.malformedManifest(reason: "url-components:\(path)")
        }
        return url
    }

    /// Polls `url`'s on-disk size until it satisfies `expectedBytes`,
    /// stops growing, or the deadline elapses. Returns the size observed
    /// at exit so the caller can decide whether the file is durable
    /// enough to move/verify.
    ///
    /// **Issue #94.** Without this, `URLSession.download(for:)` can
    /// resume its async continuation before the system's internal
    /// writer has finished draining the response body into the temp URL
    /// — surfacing as a transient `sizeMismatch(expected:N, got:0)` in
    /// CI under `URLProtocolStub` (where the protocol thread synchronously
    /// fires `didLoad` immediately followed by `urlProtocolDidFinishLoading`,
    /// giving URLSession's writer no opportunity to interleave). The race
    /// is also possible in production on slow disks. Polling is the
    /// surgical fix — switching to `URLSessionDownloadDelegate` would
    /// give a documented "writer flushed" signal but is a wider refactor
    /// (deferred — see the comment on `downloadAndVerify`).
    ///
    /// Returns when one of: (a) the file's size reaches `expectedBytes`,
    /// (b) the deadline elapses. We deliberately do *not* early-exit on
    /// a "stable plateau" (size unchanged for N polls): a ~15 ms gap
    /// between flushes is normal in chunked production downloads and
    /// would produce a spurious `sizeMismatch` on a perfectly healthy
    /// transfer. Errors stat'ing the file (e.g. the writer has not yet
    /// created it) are treated as "0 bytes for now" and re-polled.
    /// The 2-second default is a wide buffer over the few-millisecond
    /// flush window observed in CI; on a genuinely short server
    /// response this is the worst-case wait before the caller raises
    /// `sizeMismatch`.
    static func waitForFileBytes(
        at url: URL,
        expectedBytes: Int64,
        timeoutSeconds: Double = 2.0
    ) async throws -> Int64 {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(timeoutSeconds))
        let pollInterval = Duration.milliseconds(5)
        // Stat-then-check ensures the size returned at deadline is the
        // freshly-observed value, not a stale pre-sleep one — so a file
        // that reaches `expectedBytes` during the final `Task.sleep`
        // still resolves as a success rather than getting clipped to
        // the previous iteration's read (Gemini Code Assist, PR #111).
        // `attributesOfItem` is intentional here: `URL.resourceValues`
        // caches per-URL and we re-stat the same path every iteration,
        // so the cache makes the loop see a stale size after the writer
        // has already grown the file.
        while true {
            try Task.checkCancellation()
            let size: Int64 = {
                guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
                      let value = attrs[.size] as? Int64 else { return 0 }
                return value
            }()
            if size >= expectedBytes || clock.now >= deadline {
                return size
            }
            try await Task.sleep(for: pollInterval, clock: clock)
        }
    }

    /// Streamed sha256 over a file on disk. Reads in 4 MB chunks so a
    /// multi-GB safetensors file does not balloon resident memory during
    /// the idempotency check.
    static func sha256Hex(of url: URL) async throws -> String {
        try await Task.detached(priority: .utility) {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            var hasher = SHA256()
            let chunk = 4 * 1024 * 1024
            while true {
                let data = try handle.read(upToCount: chunk) ?? Data()
                if data.isEmpty { break }
                hasher.update(data: data)
            }
            let digest = hasher.finalize()
            return digest.map { String(format: "%02x", $0) }.joined()
        }.value
    }
}
