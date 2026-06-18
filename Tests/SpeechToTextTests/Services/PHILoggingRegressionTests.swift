import Foundation
import Testing
@testable import SpeechToText

@Suite("PHI logging regression", .tags(.fast))
struct PHILoggingRegressionTests {

    @Test("FluidAudioService transcribe log uses char count not transcript text")
    func fluidAudioService_logUsesCharCount() throws {
        let source = try loadSource("Sources/Services/FluidAudioService.swift")
        #expect(source.contains("chars=\\(result.text.count)"))
        #expect(!source.contains("text=\\\"\\(result.text.prefix"))
    }

    @Test("AppDelegate has no DEBUG transcript print lines")
    func appDelegate_noTranscriptPrints() throws {
        let source = try loadSource("Sources/SpeechToTextApp/AppDelegate.swift")
        #expect(!source.contains("Transcribed text:"))
        #expect(!source.contains("print(\"[DEBUG]"))
    }

    @Test("TextInsertionService has no transcript print lines")
    func textInsertion_noTranscriptPrints() throws {
        let source = try loadSource("Sources/Services/TextInsertionService.swift")
        #expect(!source.contains("print(\"[DEBUG-INSERT]"))
        #expect(!source.contains("print(\"[DEBUG-PASTE]"))
    }

    @Test("HotkeyManager has no stale #109-probe instrumentation")
    func hotkeyManager_noProbeInstrumentation() throws {
        let source = try loadSource("Sources/Services/HotkeyManager.swift")
        #expect(!source.contains("[#109-probe]"))
    }

    private func loadSource(_ relativePath: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let url = root.appendingPathComponent(relativePath)
        return try String(contentsOf: url, encoding: .utf8)
    }
}
