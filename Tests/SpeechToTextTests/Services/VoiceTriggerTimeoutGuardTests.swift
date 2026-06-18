import Foundation
import Testing

@Suite("Voice trigger timeout guard", .tags(.fast))
struct VoiceTriggerTimeoutGuardTests {

    @Test("silence and max-duration paths set isHandlingTimeout before await")
    func voiceTrigger_hasTimeoutHandlingGuard() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("Sources/Services/VoiceTriggerMonitoringService.swift"),
            encoding: .utf8
        )
        #expect(source.contains("private var isHandlingTimeout"))
        #expect(source.contains("guard !isHandlingTimeout"))
        #expect(source.contains("isHandlingTimeout = true"))
        #expect(source.contains("defer { self?.isHandlingTimeout = false }"))
        #expect(source.contains("defer { self.isHandlingTimeout = false }"))
    }
}
