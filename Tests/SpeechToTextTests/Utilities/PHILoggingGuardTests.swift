import Foundation
import Testing

@Suite("PHI logging guardrails", .tags(.fast))
struct PHILoggingGuardTests {
    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    @Test("AppLogger wraps dynamic messages with privacy: .private")
    func appLogger_defaultsDynamicMessagesToPrivate() throws {
        let source = try String(
            contentsOf: Self.repoRoot.appendingPathComponent("Sources/Utilities/Logger.swift"),
            encoding: .utf8
        )
        #expect(source.contains("(message, privacy: .private)"))
        #expect(!source.contains("(message, privacy: .public)"))
    }

    @Test("FluidAudioService transcribe completion log omits transcript text")
    func fluidAudioService_transcribeLog_usesCharCountOnly() throws {
        let source = try String(
            contentsOf: Self.repoRoot.appendingPathComponent("Sources/Services/FluidAudioService.swift"),
            encoding: .utf8
        )
        #expect(source.contains("chars=\\(result.text.count)"))
        #expect(!source.contains("text=\\\""))
        #expect(!source.contains("result.text.prefix"))
    }

    @Test("Production sources omit DEBUG print statements")
    func productionSources_haveNoDebugPrintStatements() throws {
        let paths = [
            "Sources/SpeechToTextApp/AppDelegate.swift",
            "Sources/Services/TextInsertionService.swift",
            "Sources/Services/HotkeyManager.swift",
            "Sources/Services/AudioCaptureService.swift",
            "Sources/Services/WakeWordService.swift",
            "Sources/Services/FluidAudioService.swift"
        ]

        for relativePath in paths {
            let source = try String(
                contentsOf: Self.repoRoot.appendingPathComponent(relativePath),
                encoding: .utf8
            )
            #expect(!source.contains("print(\"[DEBUG]"), "Found DEBUG print in \(relativePath)")
            #expect(!source.contains("print(\"[DEBUG-"), "Found DEBUG print in \(relativePath)")
            #expect(!source.contains("print(\"[DEBUG-PASTE]"), "Found DEBUG print in \(relativePath)")
        }
    }

    @Test("HotkeyManager has no stale #109-probe logging")
    func hotkeyManager_hasNoProbeLogging() throws {
        let source = try String(
            contentsOf: Self.repoRoot.appendingPathComponent("Sources/Services/HotkeyManager.swift"),
            encoding: .utf8
        )
        #expect(!source.contains("[#109-probe]"))
    }
}
