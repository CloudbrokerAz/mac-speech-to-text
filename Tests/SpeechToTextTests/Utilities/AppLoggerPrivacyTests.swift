import Foundation
import Testing
@testable import SpeechToText

@Suite("AppLogger privacy defaults", .tags(.fast))
struct AppLoggerPrivacyTests {

    @Test("Logger wrappers default dynamic message to privacy private")
    func logger_defaultsMessageToPrivate() throws {
        let source = try loadLoggerSource()
        let publicMessageCount = source.components(separatedBy: "message, privacy: .public").count - 1
        #expect(publicMessageCount == 0)
        #expect(source.contains("message(), privacy: .private)"))
    }

    @Test("Release builds default currentLevel to info")
    func logger_releaseDefaultIsInfo() throws {
        let source = try loadLoggerSource()
        #expect(source.contains("#else"))
        #expect(source.contains("return .info"))
    }

    @Test("Log helpers use autoclosure for lazy message evaluation")
    func logger_usesAutoclosure() throws {
        let source = try loadLoggerSource()
        #expect(source.contains("_ message: @autoclosure () -> String"))
    }

    private func loadLoggerSource() throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let url = root.appendingPathComponent("Sources/Utilities/Logger.swift")
        return try String(contentsOf: url, encoding: .utf8)
    }
}
