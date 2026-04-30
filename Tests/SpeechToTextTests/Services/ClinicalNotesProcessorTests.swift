import Foundation
import Testing
@testable import SpeechToText

// Covers issue #5 acceptance criteria:
//   - Happy path returns `.success`.
//   - Invalid-then-valid JSON triggers retry, returns `.success`.
//   - Invalid-twice triggers `.rawTranscriptFallback(reason: ...)`.
//   - LLM throws at either attempt → `.rawTranscriptFallback(reason: "llm_error")`.
//   - No retries if the first response is valid.
//   - No network, no on-disk writes.
//   - `RawLLMDraft → StructuredNotes` mapping: id match, displayName
//     match, case-insensitive, unmatchable dropped, duplicates removed,
//     order preserved.

@Suite("ClinicalNotesProcessor", .tags(.fast))
struct ClinicalNotesProcessorTests {

    // MARK: - Shared fixtures

    private static let simpleTemplate = """
    MANIPULATIONS:
    {{manipulations_list}}

    TRANSCRIPT:
    {{transcript}}
    """

    private static let sampleRepo = ManipulationsRepository(all: [
        Manipulation(id: "diversified_hvla", displayName: "Diversified HVLA", clinikoCode: nil),
        Manipulation(id: "activator", displayName: "Activator", clinikoCode: nil),
        Manipulation(id: "drop_table", displayName: "Drop Table", clinikoCode: nil)
    ])

    private static func promptBuilder(
        repo: ManipulationsRepository = sampleRepo
    ) -> ClinicalNotesPromptBuilder {
        ClinicalNotesPromptBuilder(template: simpleTemplate, manipulations: repo)
    }

    private static func processor(
        provider: any LLMProvider,
        repo: ManipulationsRepository = sampleRepo
    ) -> ClinicalNotesProcessor {
        ClinicalNotesProcessor(
            provider: provider,
            promptBuilder: promptBuilder(repo: repo),
            manipulations: repo
        )
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

    // A response that will fail validate(json:) — no JSON object at all.
    private static let invalidJSON = "sorry, I can't produce JSON right now."

    /// Schema-shape-correct JSON whose four SOAP sections are all
    /// empty strings. Pre-#100 this passed validation as `.success`;
    /// post-fix it's a `SchemaError.allSOAPSectionsEmpty` rejection.
    private static let allEmptySOAPJSON = #"""
    {
      "subjective": "",
      "objective": "",
      "assessment": "",
      "plan": "",
      "manipulations": [],
      "excluded_content": []
    }
    """#

    /// Schema-shape-correct JSON whose SOAP sections are whitespace-
    /// only (mix of spaces, tabs, newlines). Verifies the trim guard
    /// in `allSOAPSectionsEmpty(in:)` rejects filler whitespace too.
    private static let whitespaceOnlySOAPJSON = #"""
    {
      "subjective": "   ",
      "objective": "\t\t",
      "assessment": "\n\n",
      "plan": " \t\n ",
      "manipulations": [],
      "excluded_content": []
    }
    """#

    /// Schema-shape-correct JSON with only Subjective populated. A
    /// partially-populated draft is a valid generation result — the
    /// guard only fires when *all four* sections are empty.
    private static let subjectiveOnlySOAPJSON = #"""
    {
      "subjective": "neck pain",
      "objective": "",
      "assessment": "",
      "plan": "",
      "manipulations": [],
      "excluded_content": []
    }
    """#

    // MARK: - Happy path

    @Test("Valid JSON on first attempt returns .success with mapped fields")
    func happyPath_returnsSuccess() async {
        let provider = MockLLMProvider(response: Self.validJSON)
        let proc = Self.processor(provider: provider)

        let outcome = await proc.process(transcript: "t")

        let expected = StructuredNotes(
            subjective: "neck pain for 3 days",
            objective: "reduced cervical rotation R",
            assessment: "cervical facet restriction",
            plan: "follow up in 1 week",
            selectedManipulationIDs: ["diversified_hvla"],
            excluded: ["chatter about weekend"]
        )
        #expect(outcome == .success(expected))
    }

    @Test("No retry when the first response is valid")
    func happyPath_noRetry() async {
        let provider = MockLLMProvider(response: Self.validJSON)
        let proc = Self.processor(provider: provider)

        _ = await proc.process(transcript: "t")

        #expect(await provider.callCount() == 1)
    }

    // MARK: - Retry flow

    @Test("Invalid-then-valid JSON retries once and returns .success")
    func retry_invalidThenValid_returnsSuccess() async {
        let provider = MockLLMProvider(
            responses: [Self.invalidJSON, Self.validJSON]
        )
        let proc = Self.processor(provider: provider)

        let outcome = await proc.process(transcript: "t")

        guard case .success = outcome else {
            Issue.record("Expected .success, got \(outcome)")
            return
        }
        #expect(await provider.callCount() == 2)
    }

    @Test("Retry prompt quotes the invalid first response so the model can correct it")
    func retry_promptQuotesBadOutput() async {
        let provider = MockLLMProvider(
            responses: [Self.invalidJSON, Self.validJSON]
        )
        let proc = Self.processor(provider: provider)

        _ = await proc.process(transcript: "t")

        let calls = await provider.calls()
        #expect(calls.count == 2)
        let retryPrompt = calls.last?.prompt ?? ""
        #expect(retryPrompt.contains(Self.invalidJSON))
        // The retry prompt must also include the schema/instruction so
        // the model has something structural to anchor against.
        #expect(retryPrompt.contains("JSON"))
    }

    @Test("Invalid JSON on both attempts returns .rawTranscriptFallback(invalid_json_after_retry)")
    func retry_invalidTwice_fallback() async {
        let provider = MockLLMProvider(
            responses: [Self.invalidJSON, Self.invalidJSON]
        )
        let proc = Self.processor(provider: provider)

        let outcome = await proc.process(transcript: "t")

        #expect(outcome == .rawTranscriptFallback(
            reason: ClinicalNotesProcessor.reasonInvalidJSONAfterRetry
        ))
        #expect(await provider.callCount() == 2)
    }

    // MARK: - Empty-SOAP-fields retry (#100)

    /// Bug #100. The model emitted JSON whose four SOAP sections were
    /// all empty strings. Previously this validated as `.success` and
    /// the Review screen rendered four blank `TextEditor`s with no
    /// failure signal. After the fix, the all-empty shape is a schema
    /// rejection that triggers the existing retry-once path.
    @Test("All-empty SOAP fields on first attempt triggers retry; valid response on retry returns .success")
    func emptySOAP_allFields_retriesAndReturnsSuccess() async {
        let provider = MockLLMProvider(
            responses: [Self.allEmptySOAPJSON, Self.validJSON]
        )
        let proc = Self.processor(provider: provider)

        let outcome = await proc.process(transcript: "t")

        guard case .success = outcome else {
            Issue.record("Expected .success after empty-then-valid retry, got \(outcome)")
            return
        }
        // Retry must have fired — provider observed exactly two calls.
        #expect(await provider.callCount() == 2)
    }

    /// Whitespace-only SOAP sections count as empty. A model that
    /// emits filler whitespace ("   ", "\n\t", …) must not slip past
    /// the guard.
    @Test("Whitespace-only SOAP fields are treated as empty and trigger retry")
    func emptySOAP_whitespaceOnly_retriesAndReturnsSuccess() async {
        let provider = MockLLMProvider(
            responses: [Self.whitespaceOnlySOAPJSON, Self.validJSON]
        )
        let proc = Self.processor(provider: provider)

        let outcome = await proc.process(transcript: "t")

        guard case .success = outcome else {
            Issue.record("Expected .success after whitespace-then-valid retry, got \(outcome)")
            return
        }
        #expect(await provider.callCount() == 2)
    }

    /// All-empty SOAP on both attempts emits the
    /// `reasonAllSOAPEmptyAfterRetry` sentinel — distinct from
    /// `reasonInvalidJSONAfterRetry` so audit logs can attribute "model
    /// produced empty content twice" separately from "model produced
    /// unparseable JSON twice." The user-visible UX is the same
    /// fallback banner either way.
    @Test("All-empty SOAP on both attempts returns .rawTranscriptFallback(all_soap_empty_after_retry)")
    func emptySOAP_bothAttempts_fallbackWithSpecificReason() async {
        let provider = MockLLMProvider(
            responses: [Self.allEmptySOAPJSON, Self.allEmptySOAPJSON]
        )
        let proc = Self.processor(provider: provider)

        let outcome = await proc.process(transcript: "t")

        #expect(outcome == .rawTranscriptFallback(
            reason: ClinicalNotesProcessor.reasonAllSOAPEmptyAfterRetry
        ))
        #expect(await provider.callCount() == 2)
    }

    /// One populated SOAP section is enough — the guard only fires on
    /// "all four empty," not on "any one empty." A transcript that
    /// only carries subjective complaints legitimately leaves
    /// objective / assessment / plan empty.
    @Test("A single populated SOAP section is accepted as .success without retry")
    func emptySOAP_oneSectionPopulated_returnsSuccess() async {
        let provider = MockLLMProvider(response: Self.subjectiveOnlySOAPJSON)
        let proc = Self.processor(provider: provider)

        let outcome = await proc.process(transcript: "t")

        guard case .success(let notes) = outcome else {
            Issue.record("Expected .success for subjective-only draft, got \(outcome)")
            return
        }
        #expect(notes.subjective == "neck pain")
        #expect(notes.objective.isEmpty)
        #expect(notes.assessment.isEmpty)
        #expect(notes.plan.isEmpty)
        // No retry — a partially-populated draft is a valid result.
        #expect(await provider.callCount() == 1)
    }

    // MARK: - LLM failure

    @Test("LLM throws on first attempt → .rawTranscriptFallback(llm_error), no retry")
    func llmThrows_firstAttempt_fallbackWithoutRetry() async {
        let provider = MockLLMProvider(error: SampleError.boom)
        let proc = Self.processor(provider: provider)

        let outcome = await proc.process(transcript: "t")

        #expect(outcome == .rawTranscriptFallback(
            reason: ClinicalNotesProcessor.reasonLLMError
        ))
        // One call: the throw aborts the pipeline; no retry on LLM
        // throws per the acceptance criteria.
        #expect(await provider.callCount() == 1)
    }

    @Test("LLM throws on retry → .rawTranscriptFallback(llm_error)")
    func llmThrows_secondAttempt_fallback() async {
        // Single-element queue: first call pops invalidJSON (forces
        // retry); second call exhausts the queue, mock throws
        // responseQueueExhausted. That throw is indistinguishable from
        // a real provider error from the processor's perspective.
        let provider = MockLLMProvider(responses: [Self.invalidJSON])
        let proc = Self.processor(provider: provider)

        let outcome = await proc.process(transcript: "t")

        #expect(outcome == .rawTranscriptFallback(
            reason: ClinicalNotesProcessor.reasonLLMError
        ))
        #expect(await provider.callCount() == 2)
    }

    /// **#121 — `CancellationError` from the provider maps to
    /// `reasonModelRemovedMidFlight`, not `reasonLLMError`.**
    /// When `removeClinicalNotesModel()` cancels the wrapping pipeline
    /// Task mid-stream, `Task.checkCancellation()` inside
    /// `MLXGemmaProvider.runGeneration` throws `CancellationError`. The
    /// processor's `catch is CancellationError` arm must distinguish
    /// "user removed the model" from the broader "LLM error" bucket so
    /// the Review banner can be honest about why generation didn't
    /// finish. The retry catch is symmetric — when both arms see
    /// `CancellationError`, the same sentinel surfaces.
    @Test("CancellationError on first attempt → .rawTranscriptFallback(model_removed_mid_flight)")
    func llmCancellation_firstAttempt_modelRemovedSentinel() async {
        let provider = MockLLMProvider(error: CancellationError())
        let proc = Self.processor(provider: provider)

        let outcome = await proc.process(transcript: "t")

        #expect(outcome == .rawTranscriptFallback(
            reason: ClinicalNotesProcessor.reasonModelRemovedMidFlight
        ))
        #expect(await provider.callCount() == 1)
    }

    // MARK: - Manipulation mapping

    @Test("Mapping matches by Manipulation.id")
    func mapping_matchesByID() async {
        let json = Self.soapJSON(manipulations: [("activator", 0.5)])
        let provider = MockLLMProvider(response: json)
        let proc = Self.processor(provider: provider)

        let outcome = await proc.process(transcript: "t")

        guard case .success(let notes) = outcome else {
            Issue.record("Expected .success, got \(outcome)")
            return
        }
        #expect(notes.selectedManipulationIDs == ["activator"])
    }

    @Test("Mapping matches by displayName, case-insensitively")
    func mapping_matchesByDisplayName_caseInsensitive() async {
        let json = Self.soapJSON(manipulations: [("dIvErSiFiEd HvLa", 0.4)])
        let provider = MockLLMProvider(response: json)
        let proc = Self.processor(provider: provider)

        let outcome = await proc.process(transcript: "t")

        guard case .success(let notes) = outcome else {
            Issue.record("Expected .success, got \(outcome)")
            return
        }
        #expect(notes.selectedManipulationIDs == ["diversified_hvla"])
    }

    @Test("Unmatchable manipulation name is silently dropped")
    func mapping_unmatchableDropped() async {
        let json = Self.soapJSON(manipulations: [
            ("Diversified HVLA", 0.8),
            ("totally made up technique", 0.4)
        ])
        let provider = MockLLMProvider(response: json)
        let proc = Self.processor(provider: provider)

        let outcome = await proc.process(transcript: "t")

        guard case .success(let notes) = outcome else {
            Issue.record("Expected .success, got \(outcome)")
            return
        }
        #expect(notes.selectedManipulationIDs == ["diversified_hvla"])
    }

    @Test("Duplicate manipulation matches are de-duped; first occurrence wins order")
    func mapping_deDupesPreservingOrder() async {
        let json = Self.soapJSON(manipulations: [
            ("Activator", 0.7),
            ("Diversified HVLA", 0.9),
            ("activator", 0.3),    // same as first after lowercasing
            ("Drop Table", 0.5)
        ])
        let provider = MockLLMProvider(response: json)
        let proc = Self.processor(provider: provider)

        let outcome = await proc.process(transcript: "t")

        guard case .success(let notes) = outcome else {
            Issue.record("Expected .success, got \(outcome)")
            return
        }
        #expect(notes.selectedManipulationIDs == [
            "activator", "diversified_hvla", "drop_table"
        ])
    }

    @Test("Empty manipulations list round-trips to empty selectedManipulationIDs")
    func mapping_empty() async {
        let json = Self.soapJSON(manipulations: [])
        let provider = MockLLMProvider(response: json)
        let proc = Self.processor(provider: provider)

        let outcome = await proc.process(transcript: "t")

        guard case .success(let notes) = outcome else {
            Issue.record("Expected .success, got \(outcome)")
            return
        }
        #expect(notes.selectedManipulationIDs.isEmpty)
    }

    @Test("excluded_content passes through verbatim")
    func mapping_excludedPassthrough() async {
        let json = Self.soapJSON(
            manipulations: [("Activator", 0.5)],
            excluded: ["weekend small talk", "coffee banter"]
        )
        let provider = MockLLMProvider(response: json)
        let proc = Self.processor(provider: provider)

        let outcome = await proc.process(transcript: "t")

        guard case .success(let notes) = outcome else {
            Issue.record("Expected .success, got \(outcome)")
            return
        }
        #expect(notes.excluded == ["weekend small talk", "coffee banter"])
    }

    // MARK: - Sendable / concurrency contract (#15 polish)

    /// Documents the public-surface contract that `ClinicalNotesProcessor`
    /// (an `actor`) and its `Outcome` payload satisfy `Sendable`. The
    /// processor is shipped across actor boundaries by the recording
    /// modal — its `Task` hops the outcome back to the `@MainActor`
    /// review view model — so both types must round-trip across
    /// isolation cleanly.
    ///
    /// Caveat: this project is on Swift 5.9 language mode (per
    /// `Package.swift`), so a hypothetical future demotion to `class`
    /// without an explicit `Sendable` conformance would emit a
    /// *warning* at the call site rather than a hard compile error.
    /// SwiftLint's strict mode escalates the warning to an error in CI.
    /// Consider this test executable documentation rather than a
    /// load-bearing barrier.
    @Test("ClinicalNotesProcessor and Outcome conform to Sendable")
    func sendableConformancePin() {
        func requireSendable<T: Sendable>(_: T.Type) {}
        requireSendable(ClinicalNotesProcessor.self)
        requireSendable(ClinicalNotesProcessor.Outcome.self)
    }

    /// Smoke test that N concurrent `process(transcript:)` calls all
    /// reach `.success` and the provider observed every call. Pins
    /// the high-level "actor handles concurrent traffic without
    /// dropping or duplicating work" invariant; the actor's
    /// per-call serialization is enforced by the type system, not
    /// by this test.
    ///
    /// Failure surface is per-task: the `failures` array reports
    /// each non-`.success` outcome with its index and the structural
    /// fallback reason, so a regression that fails 1 of N tasks
    /// doesn't read as a generic "expected true, got false".
    @Test("Concurrent process(transcript:) calls each reach .success and are accounted for")
    func concurrentProcessCalls_eachReachSuccess() async {
        let provider = MockLLMProvider(response: Self.validJSON)
        let proc = Self.processor(provider: provider)
        let parallelism = 16

        let outcomes: [ClinicalNotesProcessor.Outcome] = await withTaskGroup(
            of: ClinicalNotesProcessor.Outcome.self,
            returning: [ClinicalNotesProcessor.Outcome].self
        ) { group in
            for _ in 0..<parallelism {
                group.addTask { await proc.process(transcript: "t") }
            }
            var collected: [ClinicalNotesProcessor.Outcome] = []
            for await outcome in group {
                collected.append(outcome)
            }
            return collected
        }

        #expect(outcomes.count == parallelism)

        let failures = outcomes.enumerated().compactMap { index, outcome -> String? in
            if case .success = outcome { return nil }
            return "task[\(index)] = \(outcome)"
        }
        #expect(
            failures.isEmpty,
            "Concurrent process calls produced non-success outcomes: \(failures)"
        )

        #expect(await provider.callCount() == parallelism)
    }

    // MARK: - Helpers

    /// Render a minimal SOAP JSON response with the given manipulations
    /// and excluded-content list. Uses static SOAP strings so mapping
    /// tests can focus on the manipulations array.
    private static func soapJSON(
        manipulations: [(name: String, confidence: Double)],
        excluded: [String] = []
    ) -> String {
        let manipulationsJSON = manipulations.map { entry in
            #"{ "name": "\#(entry.name)", "confidence": \#(entry.confidence) }"#
        }.joined(separator: ",\n    ")
        let excludedJSON = excluded.map { #""\#($0)""# }.joined(separator: ", ")
        return #"""
        {
          "subjective": "s",
          "objective": "o",
          "assessment": "a",
          "plan": "p",
          "manipulations": [
            \#(manipulationsJSON)
          ],
          "excluded_content": [\#(excludedJSON)]
        }
        """#
    }
}

// MARK: - Test fixtures

private enum SampleError: Error, Equatable, Sendable {
    case boom
}
