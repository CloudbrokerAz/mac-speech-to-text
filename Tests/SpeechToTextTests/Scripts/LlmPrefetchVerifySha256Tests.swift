import Foundation
import Testing

@Suite("LlmPrefetchVerifySha256", .tags(.fast))
struct LlmPrefetchVerifySha256Tests {
    @Test("llm-prefetch.sh exits 3 when manifest sha256 is empty")
    func rejectsEmptyManifestSha256() throws {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let script = projectRoot.appendingPathComponent("scripts/llm-prefetch.sh")
        guard FileManager.default.fileExists(atPath: script.path) else {
            return
        }

        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("llm-prefetch-empty-sha-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let destDir = tempRoot.appendingPathComponent("model", isDirectory: true)
        try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)
        let payload = Data("x".utf8)
        try payload.write(to: destDir.appendingPathComponent("config.json"))

        let manifest = """
        {
          "model_id": "test/empty-sha",
          "revision": "0000000000000000000000000000000000000000",
          "files": [
            { "path": "config.json", "size": 1, "sha256": "" }
          ],
          "total_bytes": 1
        }
        """
        let manifestURL = tempRoot.appendingPathComponent("manifest.json")
        try manifest.write(to: manifestURL, atomically: true, encoding: .utf8)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [
            script.path,
            "--manifest", manifestURL.path,
            "--dest", destDir.path,
            "--quiet"
        ]
        let stderrPipe = Pipe()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = stderrPipe
        try process.run()
        process.waitUntilExit()

        #expect(process.terminationStatus == 3)
        let stderr = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        #expect(stderr.contains("missing sha256"))
    }
}
