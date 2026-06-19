import Foundation
import Testing

@Suite("Voice trigger performance seams", .tags(.fast))
struct VoiceTriggerPerformanceTests {

    @Test("VoiceTriggerMonitoringService pushes state via onStateChange")
    func voiceTrigger_pushStateCallback() throws {
        let source = try loadSource("Sources/Services/VoiceTriggerMonitoringService.swift")
        #expect(source.contains("var onStateChange"))
        #expect(source.contains("onStateChange?(previous, newState)"))
        #expect(source.contains("normalizedEnergy(of:"))
        #expect(source.contains("scheduleFluidAudioIdleEviction()"))
        #expect(source.contains(".floatSamples("))
    }

    @Test("AppDelegate removed polling timers for overlay and voice trigger")
    func appDelegate_noPollingTimers() throws {
        let source = try loadSource("Sources/SpeechToTextApp/AppDelegate.swift")
        #expect(!source.contains("voiceTriggerStateTimer"))
        #expect(!source.contains("audioLevelTimer"))
        #expect(source.contains("onAudioLevelPublished"))
        #expect(source.contains("onStateChange"))
    }

    private func loadSource(_ relativePath: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
    }
}
