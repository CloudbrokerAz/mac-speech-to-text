import Foundation

/// Pinned record of a Hugging Face model snapshot consumed by `ModelDownloader`.
///
/// **Issue #3.** The clinical-notes LLM (Gemma 3 4B-IT, MLX 4-bit) ships
/// as a first-run download into `~/Library/Application Support/<bundle-id>/Models/`
/// rather than bundled into the .app — the locked-decision change is recorded
/// in `.claude/CLAUDE.md` and `.claude/references/mlx-lifecycle.md`. The
/// manifest is the integrity record that the downloader walks: it pins a
/// HF git revision SHA so re-downloads cannot silently swap weights, and
/// holds per-file sha256s for the large LFS-tracked binary blobs.
///
/// PHI: the manifest carries no PHI of any kind. It is safe to log every
/// field with `privacy: .public`.
public struct ModelManifest: Codable, Sendable, Equatable {
    /// Hugging Face repo id (e.g. `"mlx-community/gemma-3-text-4b-it-4bit"`).
    public let modelId: String

    /// Hugging Face git commit SHA that this manifest pins. The downloader
    /// pulls files at `https://huggingface.co/<modelId>/resolve/<revision>/<path>`,
    /// so a manifest re-publish requires bumping `revision` and re-computing
    /// any changed file hashes.
    public let revision: String

    /// Files to download. Order is for human-readability only; the downloader
    /// streams them concurrently up to a fixed parallelism (the large file
    /// dominates wall-clock anyway).
    public let files: [ModelFile]

    /// Sum of `files[i].size`. Used by the progress stream as the "total
    /// bytes" denominator and by `ModelDownloader` for the disk-space
    /// pre-check (`URLResourceKey.volumeAvailableCapacityForImportantUsageKey`).
    public let totalBytes: Int64

    /// Repo-name segment of `modelId` — i.e. everything after the final
    /// `/` (e.g. `"mlx-community/gemma-3-text-4b-it-4bit"` →
    /// `"gemma-3-text-4b-it-4bit"`). Used as the on-disk directory name
    /// under `~/Library/Application Support/<bundle-id>/Models/`.
    /// Falls back to `"model"` for the (impossible-by-decode-validation)
    /// case where `modelId` has no `/` segment.
    public var modelDirectoryName: String {
        modelId.split(separator: "/").last.map(String.init) ?? "model"
    }

    public init(modelId: String, revision: String, files: [ModelFile]) {
        self.modelId = modelId
        self.revision = revision
        self.files = files
        self.totalBytes = files.reduce(into: Int64(0)) { $0 += $1.size }
    }

    enum CodingKeys: String, CodingKey {
        case modelId = "model_id"
        case revision
        case files
        case totalBytes = "total_bytes"
    }

    /// Required for `Decodable` + custom `init(...)` co-existence. Validates
    /// that the on-disk `total_bytes` matches the sum of the file sizes —
    /// a tampered or hand-edited manifest with a stale total throws
    /// `DecodingError.dataCorrupted` rather than decoding into an
    /// inconsistent value.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.modelId = try container.decode(String.self, forKey: .modelId)
        self.revision = try container.decode(String.self, forKey: .revision)
        self.files = try container.decode([ModelFile].self, forKey: .files)
        let declared = try container.decode(Int64.self, forKey: .totalBytes)
        let computed = self.files.reduce(into: Int64(0)) { $0 += $1.size }
        guard declared == computed else {
            throw DecodingError.dataCorrupted(
                .init(
                    codingPath: container.codingPath + [CodingKeys.totalBytes],
                    debugDescription: "ModelManifest.total_bytes (\(declared)) does not match sum(files.size) (\(computed))"
                )
            )
        }
        self.totalBytes = declared
    }
}

/// Single-file entry inside a `ModelManifest`.
public struct ModelFile: Codable, Sendable, Equatable {
    /// Path relative to the model directory (and to the HF repo root).
    /// Forward-slash separated on disk too — the downloader maps `/` → the
    /// platform separator at write time.
    public let path: String

    /// Expected on-disk size in bytes. The downloader compares this against
    /// the live `Content-Length` and against the actual bytes-written count.
    public let size: Int64

    /// Hex sha256 of the file contents. `nil` is allowed for small config
    /// files whose integrity is bounded by the manifest's `revision` pin —
    /// LFS-tracked files (`*.safetensors`, `tokenizer.json`, `tokenizer.model`)
    /// MUST carry a hash. The downloader's `verify(file:)` treats `nil` as
    /// "size-only check"; populate via `scripts/build-model-manifest.sh` if
    /// you want stronger guarantees.
    public let sha256: String?

    public init(path: String, size: Int64, sha256: String?) {
        self.path = path
        self.size = size
        self.sha256 = sha256
    }

    /// Decode-time validation: rejects path-traversal segments,
    /// negative sizes, and absolute paths so a malicious or
    /// hand-typed manifest can't reach outside the model directory
    /// when `ModelDownloader.appendingPathComponent(file.path)` runs.
    /// `sha256` is allowed `nil` (manifest revision pin covers
    /// integrity for small config files) but rejected if present
    /// as an empty string — that's neither a hash nor a "skip".
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let path = try container.decode(String.self, forKey: .path)
        let size = try container.decode(Int64.self, forKey: .size)
        let sha256 = try container.decodeIfPresent(String.self, forKey: .sha256)

        guard !path.isEmpty,
              !path.hasPrefix("/"),
              !path.split(separator: "/").contains(".."),
              !path.contains("\\") else {
            throw DecodingError.dataCorrupted(
                .init(
                    codingPath: container.codingPath + [CodingKeys.path],
                    debugDescription: "ModelFile.path '\(path)' is empty, absolute, or contains traversal segments"
                )
            )
        }
        guard size >= 0 else {
            throw DecodingError.dataCorrupted(
                .init(
                    codingPath: container.codingPath + [CodingKeys.size],
                    debugDescription: "ModelFile.size must be non-negative; got \(size)"
                )
            )
        }
        if let sha256, sha256.isEmpty {
            throw DecodingError.dataCorrupted(
                .init(
                    codingPath: container.codingPath + [CodingKeys.sha256],
                    debugDescription: "ModelFile.sha256 must be nil or non-empty"
                )
            )
        }

        self.path = path
        self.size = size
        self.sha256 = sha256
    }

    enum CodingKeys: String, CodingKey {
        case path
        case size
        case sha256
    }
}
