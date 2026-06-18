import Foundation
import Testing

@Suite("Voice trigger frame ordering", .tags(.fast))
struct VoiceTriggerFrameOrderingTests {

    @Test("monitoring path uses ordered AsyncStream consumer")
    func voiceTrigger_usesOrderedFrameStream() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("Sources/Services/VoiceTriggerMonitoringService.swift"),
            encoding: .utf8
        )
        #expect(source.contains("frameStreamContinuation"))
        #expect(source.contains("startFrameConsumer"))
        #expect(source.contains("for await floatSamples in stream"))
        #expect(!source.contains("Task { [weak self] in\n                guard let self else { return }\n                if let result = await self.wakeWordService.processFrame"))
    }
}
