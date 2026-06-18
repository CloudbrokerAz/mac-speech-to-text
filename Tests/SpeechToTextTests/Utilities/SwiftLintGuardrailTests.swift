import Foundation
import Testing

@Suite("SwiftLint concurrency guardrails", .tags(.fast))
struct SwiftLintGuardrailTests {

    @Test("nonisolated_unsafe_warning rule is defined")
    func swiftlint_definesNonisolatedUnsafeRule() throws {
        let yml = try loadSwiftLintConfig()
        #expect(yml.contains("nonisolated_unsafe_warning:"))
        #expect(yml.contains("nonisolated\\(unsafe\\)"))
    }

    @Test("observable_actor_existential_warning matches source not comments only")
    func swiftlint_observableRuleMatchesSource() throws {
        let yml = try loadSwiftLintConfig()
        #expect(yml.contains("observable_actor_existential_warning:"))
        #expect(!yml.contains("excluded: true  # Only match in source code, not comments"))
    }

    private func loadSwiftLintConfig() throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(".swiftlint.yml"), encoding: .utf8)
    }
}
