import Foundation
import Testing

@Suite("Voice trigger timer lifecycle", .tags(.fast))
struct VoiceTriggerTimerLifecycleTests {

    @Test("deinit does not invalidate timers — stopMonitoring owns teardown")
    func voiceTrigger_deinitDoesNotInvalidateTimers() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("Sources/Services/VoiceTriggerMonitoringService.swift"),
            encoding: .utf8
        )
        let deinitBlock = source.components(separatedBy: "deinit {")
            .dropFirst().first?
            .components(separatedBy: "}")
            .first ?? ""
        #expect(!deinitBlock.contains("deinitSilenceTimer?.invalidate()"))
        #expect(!deinitBlock.contains("deinitMaxDurationTimer?.invalidate()"))
        #expect(deinitBlock.contains("deinitSilenceTimer = nil"))
        #expect(deinitBlock.contains("deinitMaxDurationTimer = nil"))
        #expect(source.contains("func stopMonitoring() async"))
    }
}
