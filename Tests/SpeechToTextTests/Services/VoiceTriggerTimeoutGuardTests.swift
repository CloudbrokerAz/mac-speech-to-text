import Foundation
import Testing

@Suite("Voice trigger timeout guard", .tags(.fast))
struct VoiceTriggerTimeoutGuardTests {

    @Test("silence and max-duration paths set internalGuard before await")
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
        #expect(source.contains("private var internalGuard: VoiceTriggerInternalGuard"))
        #expect(source.contains("guard internalGuard != .handlingTimeout"))
        #expect(source.contains("internalGuard = .handlingTimeout"))
        #expect(source.contains("if self?.internalGuard == .handlingTimeout"))
        #expect(source.contains("self?.internalGuard = .none"))
    }
}
