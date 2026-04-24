import Foundation
import Testing
@testable import SpeechToText

/// Covers the `LLMOptions` defaults contract. These defaults are
/// load-bearing: EPIC #1 locks "deterministic generation (temperature
/// 0, fixed seed)" for clinical notes, so a silent drift would allow
/// nondeterministic output to slip through.
@Suite("LLMOptions", .tags(.fast))
struct LLMOptionsTests {
    @Test("Default-initialised options are deterministic")
    func defaults_areDeterministic() {
        let options = LLMOptions()

        // Temperature 0 + non-nil seed == reproducible output for the
        // same prompt under the same model weights.
        #expect(options.temperature == 0)
        #expect(options.seed != nil)
    }

    @Test("Default options match the EPIC #1 contract")
    func defaults_matchContract() {
        let options = LLMOptions()

        #expect(options.temperature == 0)
        #expect(options.topP == 1.0)
        #expect(options.maxTokens == 1024)
        #expect(options.seed == 42)
        #expect(options.stop.isEmpty)
    }

    @Test("Explicit parameters override the defaults")
    func explicitParameters_override() {
        let options = LLMOptions(
            temperature: 0.5,
            topP: 0.9,
            maxTokens: 256,
            seed: nil,
            stop: ["</end>"]
        )

        #expect(options.temperature == 0.5)
        #expect(options.topP == 0.9)
        #expect(options.maxTokens == 256)
        #expect(options.seed == nil)
        #expect(options.stop == ["</end>"])
    }

    @Test("Equatable conformance ignores nothing — all fields compared")
    func equatable_comparesAllFields() {
        let a = LLMOptions()
        let b = LLMOptions()
        #expect(a == b)

        var c = LLMOptions()
        c.temperature = 0.1
        #expect(a != c)

        var d = LLMOptions()
        d.seed = nil
        #expect(a != d)
    }
}
