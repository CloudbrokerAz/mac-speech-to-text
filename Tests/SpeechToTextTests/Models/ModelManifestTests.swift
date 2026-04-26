import Foundation
import Testing
@testable import SpeechToText

@Suite("ModelManifest", .tags(.fast))
struct ModelManifestTests {
    @Test("modelDirectoryName takes the segment after the final slash",
          arguments: [
              ("mlx-community/gemma-4-e4b-it-4bit", "gemma-4-e4b-it-4bit"),
              ("ns/repo", "repo"),
              ("a/b/c", "c")
          ])
    func modelDirectoryNameDerivation(modelId: String, expected: String) {
        let manifest = ModelManifest(
            modelId: modelId,
            revision: "abc",
            files: []
        )
        #expect(manifest.modelDirectoryName == expected)
    }

    @Test("init computes total_bytes from files")
    func totalBytesFromFiles() {
        let manifest = ModelManifest(
            modelId: "ns/repo",
            revision: "deadbeef",
            files: [
                ModelFile(path: "a.bin", size: 100, sha256: nil),
                ModelFile(path: "b.bin", size: 250, sha256: "abc")
            ]
        )
        #expect(manifest.totalBytes == 350)
    }

    @Test("decode rejects total_bytes that disagrees with sum(files.size)")
    func decodeRejectsStaleTotal() throws {
        let json = """
        {
          "model_id": "ns/repo",
          "revision": "deadbeef",
          "files": [
            { "path": "a.bin", "size": 100, "sha256": null }
          ],
          "total_bytes": 999
        }
        """.data(using: .utf8)!
        // Tampered or hand-edited manifest with a stale total surfaces
        // as `DecodingError.dataCorrupted` rather than decoding into an
        // inconsistent value that bites later.
        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(ModelManifest.self, from: json)
        }
    }

    @Test("decode passes when total_bytes matches sum(files.size)")
    func decodePassesOnConsistentTotal() throws {
        let json = """
        {
          "model_id": "ns/repo",
          "revision": "deadbeef",
          "files": [
            { "path": "a.bin", "size": 100, "sha256": null },
            { "path": "b.bin", "size": 200, "sha256": null }
          ],
          "total_bytes": 300
        }
        """.data(using: .utf8)!
        let manifest = try JSONDecoder().decode(ModelManifest.self, from: json)
        #expect(manifest.totalBytes == 300)
        #expect(manifest.files.count == 2)
    }

    @Test("decode rejects ModelFile with malformed path or negative size",
          arguments: [
              // (path, size, expectThrow)
              ("../etc/passwd", Int64(10), true),
              ("/abs/path", Int64(10), true),
              ("a/../b", Int64(10), true),
              ("", Int64(10), true),
              ("ok/path", Int64(-1), true),
              ("ok/path", Int64(0), false),     // zero-size files are valid (empty config)
              ("nested/dir/file.bin", Int64(123), false)
          ])
    func decodeValidatesModelFile(path: String, size: Int64, expectThrow: Bool) throws {
        // Paths embedded with care; this test exists because
        // `ModelDownloader.appendingPathComponent(file.path)` would
        // otherwise be a path-traversal vector.
        let json = """
        { "path": \(jsonEncode(path)), "size": \(size), "sha256": null }
        """.data(using: .utf8)!
        if expectThrow {
            #expect(throws: DecodingError.self) {
                _ = try JSONDecoder().decode(ModelFile.self, from: json)
            }
        } else {
            let file = try JSONDecoder().decode(ModelFile.self, from: json)
            #expect(file.path == path)
            #expect(file.size == size)
        }
    }

    @Test("decode rejects empty-string sha256")
    func decodeRejectsEmptyHash() throws {
        let json = #"{ "path": "ok", "size": 1, "sha256": "" }"#.data(using: .utf8)!
        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(ModelFile.self, from: json)
        }
    }

    /// Minimal JSON-string encoder for the parameterised test above.
    /// Tests use known-safe path inputs, so escaping just `"` is enough;
    /// no general-purpose escaping needed.
    private func jsonEncode(_ s: String) -> String {
        return "\"\(s.replacingOccurrences(of: "\"", with: "\\\""))\""
    }

    @Test("encode round-trips through Decoder")
    func encodeDecodeRoundTrip() throws {
        let original = ModelManifest(
            modelId: "mlx-community/gemma-4-e4b-it-4bit",
            revision: "cc3b666c01c20395e0dcebd53854504c7d9821f9",
            files: [
                ModelFile(path: "config.json", size: 6229, sha256: nil),
                ModelFile(path: "model.safetensors", size: 5_217_361_182, sha256: "ABC")
            ]
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let data = try encoder.encode(original)
        let decoded = try JSONDecoder().decode(ModelManifest.self, from: data)
        #expect(decoded == original)
    }

    @Test("snake_case JSON keys decode")
    func snakeCaseKeys() throws {
        let json = #"""
        {
          "model_id": "x/y",
          "revision": "abc",
          "files": [],
          "total_bytes": 0
        }
        """#.data(using: .utf8)!
        let manifest = try JSONDecoder().decode(ModelManifest.self, from: json)
        #expect(manifest.modelId == "x/y")
        #expect(manifest.totalBytes == 0)
        #expect(manifest.files.isEmpty)
    }

    @Test("bundled gemma-4-e4b-it-4bit manifest is structurally sound (off-disk)")
    func bundledManifestDecodes() throws {
        // The manifest resource lives in the main `SpeechToText` target's
        // Resources/, NOT in the test bundle's resources, so `Bundle.module`
        // here doesn't see it. Read the file directly off the workspace
        // path (test runs from the project root) so this test exercises
        // the actual checked-in manifest rather than a duplicate fixture.
        let manifestPath = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Resources/Models/gemma-4-e4b-it-4bit/manifest.json")
        guard FileManager.default.fileExists(atPath: manifestPath.path) else {
            // CI / Xcode test schemes may run from a different cwd. Skip
            // cleanly — production wiring (`AppState.makeLLMPipeline`)
            // is the canonical correctness check.
            return
        }
        let data = try Data(contentsOf: manifestPath)
        let manifest = try JSONDecoder().decode(ModelManifest.self, from: data)
        #expect(manifest.modelId == "mlx-community/gemma-4-e4b-it-4bit")
        #expect(manifest.revision.count == 40) // git SHA
        #expect(manifest.files.count == 8)
        let computedTotal = manifest.files.reduce(into: Int64(0)) { $0 += $1.size }
        #expect(computedTotal == manifest.totalBytes)
        // The big binary file MUST have a sha256 — it's where tampering
        // would matter. Smaller config files may rely on revision pinning.
        // Threshold raised vs the v1 Gemma 3 manifest: Gemma 4 E4B is
        // ~5.2 GB on disk (vs 2.6 GB), so a regression that pointed at
        // the wrong artifact would be caught earlier.
        let bigFile = manifest.files.first(where: { $0.path == "model.safetensors" })
        #expect(bigFile?.sha256?.isEmpty == false)
        #expect(bigFile?.size ?? 0 > 5_000_000_000)
    }
}
