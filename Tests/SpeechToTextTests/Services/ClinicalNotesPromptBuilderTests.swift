import Foundation
import Testing
@testable import SpeechToText

// Covers issue #4 acceptance criteria:
//   - Prompt loadable from a Resources text file (checks `loadFromBundle`
//     + safety line from soap_v1.txt).
//   - `validate(json:)` returns `Result<..., SchemaError>`; we return
//     `RawLLMDraft` not `StructuredNotes` — see the design
//     reconciliation note on #4. The downstream `RawLLMDraft →
//     StructuredNotes` mapping is tested in #5.
//   - Handles extra whitespace, code-fence-wrapped JSON, and trailing
//     commentary gracefully.
//   - Unit coverage: valid JSON, missing key, wrong type, empty
//     manipulations, confidence outside [0, 1].
//
// Style: Swift Testing only, `.fast` via the suite. See
// `.claude/references/testing-conventions.md`.

@Suite("ClinicalNotesPromptBuilder", .tags(.fast))
struct ClinicalNotesPromptBuilderTests {

    // MARK: - Shared fixtures

    private static let simpleTemplate = """
    MANIPULATIONS:
    {{manipulations_list}}

    TRANSCRIPT:
    {{transcript}}
    """

    private static let sampleRepo = ManipulationsRepository(all: [
        Manipulation(id: "diversified_hvla", displayName: "Diversified HVLA", clinikoCode: nil),
        Manipulation(id: "activator", displayName: "Activator", clinikoCode: nil)
    ])

    private static func builder(
        template: String = simpleTemplate,
        repo: ManipulationsRepository = sampleRepo
    ) -> ClinicalNotesPromptBuilder {
        ClinicalNotesPromptBuilder(template: template, manipulations: repo)
    }

    private static let validJSON = #"""
    {
      "subjective": "neck pain for 3 days",
      "objective": "reduced cervical rotation R",
      "assessment": "cervical facet restriction",
      "plan": "follow up in 1 week",
      "manipulations": [
        { "name": "Diversified HVLA", "confidence": 0.91 }
      ],
      "excluded_content": ["chatter about weekend"]
    }
    """#

    // MARK: - Prompt assembly

    @Test("buildPrompt renders every manipulation id + display_name and embeds the transcript")
    func buildPrompt_rendersTaxonomyAndTranscript() {
        let prompt = Self.builder().buildPrompt(transcript: "Patient says hello.")

        #expect(prompt.contains("- id: diversified_hvla, name: Diversified HVLA"))
        #expect(prompt.contains("- id: activator, name: Activator"))
        #expect(prompt.contains("Patient says hello."))
        #expect(!prompt.contains("{{manipulations_list}}"))
        #expect(!prompt.contains("{{transcript}}"))
    }

    @Test("buildPrompt with empty taxonomy renders an empty manipulations block")
    func buildPrompt_emptyTaxonomy() {
        let emptyRepo = ManipulationsRepository(all: [])
        let prompt = Self.builder(repo: emptyRepo).buildPrompt(transcript: "x")
        #expect(prompt.contains("MANIPULATIONS:\n\n"))
    }

    @Test("bundled soap_v1 template includes the locked safety line")
    func bundledTemplate_includesSafetyLine() throws {
        let builder = try ClinicalNotesPromptBuilder.loadFromBundle(
            manipulations: Self.sampleRepo
        )
        let prompt = builder.buildPrompt(transcript: "x")
        #expect(prompt.contains("drafting assistant"))
        #expect(prompt.contains("not a diagnostic tool"))
    }

    @Test("loadFromBundle surfaces typed templateNotFound for a missing resource")
    func loadFromBundle_missingResource_throws() {
        #expect(throws: ClinicalNotesPromptBuilderError.self) {
            _ = try ClinicalNotesPromptBuilder.loadFromBundle(
                templateResource: "does-not-exist",
                manipulations: Self.sampleRepo
            )
        }
    }

    // MARK: - validate() happy path

    @Test("validate returns RawLLMDraft for well-formed JSON")
    func validate_happyPath() {
        let result = Self.builder().validate(json: Self.validJSON)
        guard case let .success(draft) = result else {
            Issue.record("expected success, got \(result)")
            return
        }
        #expect(draft.subjective == "neck pain for 3 days")
        #expect(draft.objective == "reduced cervical rotation R")
        #expect(draft.assessment == "cervical facet restriction")
        #expect(draft.plan == "follow up in 1 week")
        #expect(draft.manipulations.count == 1)
        #expect(draft.manipulations[0].name == "Diversified HVLA")
        #expect(draft.manipulations[0].confidence == 0.91)
        #expect(draft.excludedContent == ["chatter about weekend"])
    }

    @Test("validate accepts an empty manipulations array")
    func validate_emptyManipulations() {
        let json = #"""
        {
          "subjective": "",
          "objective": "",
          "assessment": "",
          "plan": "",
          "manipulations": [],
          "excluded_content": []
        }
        """#
        guard case let .success(draft) = Self.builder().validate(json: json) else {
            Issue.record("expected success")
            return
        }
        #expect(draft.manipulations.isEmpty)
        #expect(draft.excludedContent.isEmpty)
    }

    // MARK: - Tolerant parsing

    @Test("validate strips a ```json ... ``` code fence")
    func validate_stripsJsonCodeFence() {
        let wrapped = "```json\n" + Self.validJSON + "\n```"
        guard case .success = Self.builder().validate(json: wrapped) else {
            Issue.record("expected success for fenced JSON")
            return
        }
    }

    @Test("validate strips a bare ``` ... ``` code fence")
    func validate_stripsBareCodeFence() {
        let wrapped = "```\n" + Self.validJSON + "\n```"
        guard case .success = Self.builder().validate(json: wrapped) else {
            Issue.record("expected success for bare-fenced JSON")
            return
        }
    }

    @Test("validate tolerates trailing commentary after the JSON object")
    func validate_toleratesTrailingCommentary() {
        let noisy = Self.validJSON + "\n\nLet me know if you'd like me to adjust this!"
        guard case .success = Self.builder().validate(json: noisy) else {
            Issue.record("expected success when trailing commentary follows the JSON")
            return
        }
    }

    @Test("validate tolerates leading whitespace + a leading newline")
    func validate_toleratesLeadingWhitespace() {
        let padded = "   \n\n\t" + Self.validJSON
        guard case .success = Self.builder().validate(json: padded) else {
            Issue.record("expected success with leading whitespace")
            return
        }
    }

    @Test("validate is not fooled by braces inside string literals")
    func validate_bracesInStringsDoNotBreakExtraction() {
        let withBraceInString = #"""
        {
          "subjective": "patient quoted: \"{not json}\" earlier",
          "objective": "",
          "assessment": "",
          "plan": "",
          "manipulations": [],
          "excluded_content": []
        }
        """#
        guard case let .success(draft) = Self.builder().validate(json: withBraceInString) else {
            Issue.record("expected success — inner braces are in a string literal")
            return
        }
        #expect(draft.subjective.contains("{not json}"))
    }

    // MARK: - Error cases

    @Test("validate returns emptyInput for whitespace-only input")
    func validate_emptyInput() {
        #expect(Self.builder().validate(json: "   \n\t") == .failure(.emptyInput))
        #expect(Self.builder().validate(json: "") == .failure(.emptyInput))
    }

    @Test("validate returns noJSONFound when the input has no JSON object")
    func validate_noJSONFound() {
        let notJSON = "I don't know what to say about this consultation."
        #expect(Self.builder().validate(json: notJSON) == .failure(.noJSONFound))
    }

    @Test("validate returns decodingFailed(.missingKey) for a missing required key — with a PHI-safe keyPath")
    func validate_decodingFailed_missingKey() {
        let missingPlan = #"""
        {
          "subjective": "x",
          "objective": "x",
          "assessment": "x",
          "manipulations": [],
          "excluded_content": []
        }
        """#
        let result = Self.builder().validate(json: missingPlan)
        #expect(result == .failure(.decodingFailed(.missingKey(keyPath: "plan"))))
    }

    @Test("validate returns decodingFailed(.typeMismatch) when confidence is the wrong type, without leaking the offending value")
    func validate_decodingFailed_wrongType() {
        // The word "suspicious" is used as the bogus confidence value so
        // that we can assert it does *not* appear anywhere in the typed
        // error — proving the PHI-safe redaction path.
        let wrongType = #"""
        {
          "subjective": "x",
          "objective": "x",
          "assessment": "x",
          "plan": "x",
          "manipulations": [{ "name": "Activator", "confidence": "suspicious" }],
          "excluded_content": []
        }
        """#
        let result = Self.builder().validate(json: wrongType)
        guard case let .failure(.decodingFailed(kind)) = result else {
            Issue.record("expected decodingFailed")
            return
        }
        guard case let .typeMismatch(keyPath) = kind else {
            Issue.record("expected .typeMismatch, got \(kind)")
            return
        }
        #expect(keyPath.hasPrefix("manipulations"))
        #expect(keyPath.contains("confidence"))
        // B1 PHI-safety invariant: the offending value must not surface
        // in the rendered error description.
        let rendered = String(describing: result)
        #expect(!rendered.contains("suspicious"), "PHI-safe error must not quote the offending value")
    }

    @Test("validate returns decodingFailed(.typeMismatch) when a SOAP section is the wrong type, without leaking the offending value")
    func validate_decodingFailed_soapSectionTypeMismatch_redacted() {
        // Integer in a String field — same PHI-safety invariant as above.
        let wrongType = #"""
        {
          "subjective": 424242,
          "objective": "x",
          "assessment": "x",
          "plan": "x",
          "manipulations": [],
          "excluded_content": []
        }
        """#
        let result = Self.builder().validate(json: wrongType)
        guard case let .failure(.decodingFailed(kind)) = result else {
            Issue.record("expected decodingFailed")
            return
        }
        guard case .typeMismatch(keyPath: "subjective") = kind else {
            Issue.record("expected .typeMismatch(keyPath: \"subjective\"), got \(kind)")
            return
        }
        let rendered = String(describing: result)
        #expect(!rendered.contains("424242"), "PHI-safe error must not quote the offending value")
    }

    @Test("validate returns confidenceOutOfRange with a structural keyPath when confidence > 1")
    func validate_confidenceAboveOne() {
        let json = #"""
        {
          "subjective": "",
          "objective": "",
          "assessment": "",
          "plan": "",
          "manipulations": [{ "name": "Activator", "confidence": 1.25 }],
          "excluded_content": []
        }
        """#
        #expect(
            Self.builder().validate(json: json)
            == .failure(.confidenceOutOfRange(keyPath: "manipulations.0.confidence", value: 1.25))
        )
    }

    @Test("validate returns confidenceOutOfRange with a structural keyPath when confidence < 0")
    func validate_confidenceBelowZero() {
        let json = #"""
        {
          "subjective": "",
          "objective": "",
          "assessment": "",
          "plan": "",
          "manipulations": [{ "name": "Gonstead", "confidence": -0.1 }],
          "excluded_content": []
        }
        """#
        #expect(
            Self.builder().validate(json: json)
            == .failure(.confidenceOutOfRange(keyPath: "manipulations.0.confidence", value: -0.1))
        )
    }

    @Test("confidenceOutOfRange does not carry the LLM-returned name (prompt-injection / hallucination PHI guard)")
    func validate_confidenceOutOfRange_doesNotCarryName() {
        // If the LLM hallucinates a "name" that contains transcript-
        // derived text (patient name, DOB, quoted symptom, …), the
        // resulting error must not carry it. This test embeds a
        // PHI-looking token in the manipulation name and asserts it
        // never appears in the rendered error.
        let phiLooking = "Alice Smith DOB 1983-04-12"
        let json = """
        {
          "subjective": "",
          "objective": "",
          "assessment": "",
          "plan": "",
          "manipulations": [{ "name": "\(phiLooking)", "confidence": 1.9 }],
          "excluded_content": []
        }
        """
        let result = Self.builder().validate(json: json)
        #expect(
            result == .failure(.confidenceOutOfRange(keyPath: "manipulations.0.confidence", value: 1.9))
        )
        let rendered = String(describing: result)
        #expect(!rendered.contains("Alice"), "PHI-safe error must not quote the LLM-returned name")
        #expect(!rendered.contains("1983"), "PHI-safe error must not quote the LLM-returned name")
    }

    @Test("confidenceOutOfRange keyPath reports the first offender index for a later manipulation entry")
    func validate_confidenceOutOfRange_reportsCorrectIndex() {
        // Pins that `offender.offset` is the array index of the first
        // offending entry, so downstream diagnostics can map back to
        // exactly which manipulation misbehaved.
        let json = #"""
        {
          "subjective": "",
          "objective": "",
          "assessment": "",
          "plan": "",
          "manipulations": [
            { "name": "Activator", "confidence": 0.5 },
            { "name": "Gonstead",  "confidence": 0.9 },
            { "name": "Toggle Recoil", "confidence": 42.0 }
          ],
          "excluded_content": []
        }
        """#
        #expect(
            Self.builder().validate(json: json)
            == .failure(.confidenceOutOfRange(keyPath: "manipulations.2.confidence", value: 42.0))
        )
    }

    @Test("validate accepts confidence at the inclusive bounds 0.0 and 1.0")
    func validate_confidenceBounds_inclusive() {
        let json = #"""
        {
          "subjective": "",
          "objective": "",
          "assessment": "",
          "plan": "",
          "manipulations": [
            { "name": "Activator", "confidence": 0.0 },
            { "name": "Gonstead",  "confidence": 1.0 }
          ],
          "excluded_content": []
        }
        """#
        guard case .success = Self.builder().validate(json: json) else {
            Issue.record("expected success for bounds 0.0 and 1.0")
            return
        }
    }

    // MARK: - Edge cases pinned by pre-PR review

    @Test("validate returns noJSONFound for an unbalanced JSON object (open brace, no close)")
    func validate_unbalancedJSON_returnsNoJSONFound() {
        // Pins N1: the brace walker returns nil for an unbalanced input,
        // which surfaces as `.noJSONFound` rather than `.decodingFailed`.
        // Behaviour is load-bearing for the retry-once orchestration in
        // #5 — swapping this to a different failure kind would change
        // which retries fire.
        let unbalanced = #"{ "subjective": "x", "objective": "y""#
        #expect(Self.builder().validate(json: unbalanced) == .failure(.noJSONFound))
    }

    @Test("validate accepts an uppercase ```JSON fence (dual-path via firstJSONObject fallback)")
    func validate_stripsUppercaseJsonFence() {
        // Pins N2: `stripCodeFence` only strips lowercase `json`, but the
        // overall validate path recovers via `firstJSONObject` on any
        // leftover preamble.
        let wrapped = "```JSON\n" + Self.validJSON + "\n```"
        guard case .success = Self.builder().validate(json: wrapped) else {
            Issue.record("expected success for uppercase JSON fence")
            return
        }
    }

    @Test("buildPrompt embeds a transcript containing triple-backticks verbatim without breaking template substitution")
    func buildPrompt_tripleBackticksInTranscript_roundTrip() {
        // Pins N3: a transcript that contains ``` must flow straight
        // through `{{transcript}}` substitution. Nothing in the builder
        // should try to re-interpret or strip fences on the input side.
        let transcript = "Patient said: ```hello``` and went home."
        let prompt = Self.builder().buildPrompt(transcript: transcript)
        #expect(prompt.contains(transcript))
        #expect(!prompt.contains("{{transcript}}"))
    }

    @Test("buildPrompt inserts a transcript containing {{manipulations_list}} literally, without re-substitution")
    func buildPrompt_placeholderInTranscript_notResubstituted() {
        // Pins the substitution-order invariant documented on
        // `buildPrompt`: manipulations_list is substituted before
        // transcript, so a transcript that literally contains
        // `{{manipulations_list}}` stays verbatim.
        let transcript = "Literal placeholder: {{manipulations_list}} — should stay."
        let prompt = Self.builder().buildPrompt(transcript: transcript)
        #expect(prompt.contains("Literal placeholder: {{manipulations_list}} — should stay."))
    }
}
