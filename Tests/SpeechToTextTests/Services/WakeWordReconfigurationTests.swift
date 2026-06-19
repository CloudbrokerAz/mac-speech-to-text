import Foundation
import Testing

@Suite("WakeWord reconfiguration guard", .tags(.fast))
struct WakeWordReconfigurationTests {

    @Test("updateKeywords sets single-flight isReconfiguring guard")
    func wakeWordService_hasReconfigurationGuard() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("Sources/Services/WakeWordService.swift"),
            encoding: .utf8
        )
        #expect(source.contains("private var isReconfiguring"))
        #expect(source.contains("guard !isReconfiguring"))
        #expect(source.contains("isReconfiguring = true"))
        #expect(source.contains("defer { isReconfiguring = false }"))
    }
}
