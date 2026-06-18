// SoapFixturesTests.swift
// macOS Local Speech-to-Text Application
//
// Pins the reviewable `Fixtures/soap/` corpus (#267 / TST-12). Each
// fixture is PHI-free synthetic content loaded via `HTTPStubFixture`
// and exercised through `ClinicalNotesPromptBuilder.validate(json:)`.

import Foundation
import Testing
@testable import SpeechToText

@Suite("SoapFixtures", .tags(.fast))
struct SoapFixturesTests {

    private static let sampleRepo = ManipulationsRepository(all: [
        Manipulation(id: "diversified_hvla", displayName: "Diversified HVLA", clinikoCode: nil),
        Manipulation(id: "activator", displayName: "Activator", clinikoCode: nil)
    ])

    private static let builder = ClinicalNotesPromptBuilder(
        template: "TRANSCRIPT:\n{{transcript}}\nMANIPULATIONS:\n{{manipulations_list}}",
        manipulations: sampleRepo
    )

    enum ExpectedOutcome: Sendable, Equatable {
        case success
        case failure(SchemaError)
    }

    struct FixtureCase: Sendable {
        let path: String
        let expected: ExpectedOutcome
    }

    private static let validCases: [FixtureCase] = [
        FixtureCase(path: "soap/valid/typical.json", expected: .success),
        FixtureCase(path: "soap/valid/code_fence_wrapped.txt", expected: .success)
    ]

    private static let invalidCases: [FixtureCase] = [
        FixtureCase(
            path: "soap/invalid/missing_plan.json",
            expected: .failure(.decodingFailed(.missingKey(keyPath: "plan")))
        ),
        FixtureCase(
            path: "soap/invalid/wrong_confidence_type.json",
            expected: .failure(.decodingFailed(.typeMismatch(keyPath: "manipulations.0.confidence")))
        ),
        FixtureCase(
            path: "soap/invalid/all_soap_empty.json",
            expected: .failure(.allSOAPSectionsEmpty)
        ),
        FixtureCase(
            path: "soap/invalid/confidence_out_of_range.json",
            expected: .failure(.confidenceOutOfRange(keyPath: "manipulations.0.confidence", value: 1.25))
        ),
        FixtureCase(path: "soap/invalid/not_json.txt", expected: .failure(.noJSONFound)),
        FixtureCase(path: "soap/invalid/empty_input.txt", expected: .failure(.emptyInput))
    ]

    private static func loadText(_ path: String) throws -> String {
        let data = try HTTPStubFixture.load(path)
        guard let text = String(data: data, encoding: .utf8) else {
            Issue.record("fixture not UTF-8: \(path)")
            return ""
        }
        return text
    }

    private static func assertOutcome(
        _ actual: Result<RawLLMDraft, SchemaError>,
        matches expected: ExpectedOutcome,
        fixturePath: String
    ) {
        switch (actual, expected) {
        case (.success, .success):
            return
        case let (.failure(actualError), .failure(expectedError)):
            #expect(actualError == expectedError, "fixture \(fixturePath)")
        default:
            Issue.record("fixture \(fixturePath): expected \(expected), got \(actual)")
        }
    }

    @Test(
        "valid soap fixtures decode through the schema guard",
        .tags(.fast),
        arguments: validCases
    )
    func validFixtures(fixture: FixtureCase) throws {
        let json = try Self.loadText(fixture.path)
        let result = Self.builder.validate(json: json)
        Self.assertOutcome(result, matches: fixture.expected, fixturePath: fixture.path)
    }

    @Test(
        "invalid soap fixtures are rejected with the expected SchemaError",
        .tags(.fast),
        arguments: invalidCases
    )
    func invalidFixtures(fixture: FixtureCase) throws {
        let json = try Self.loadText(fixture.path)
        let result = Self.builder.validate(json: json)
        Self.assertOutcome(result, matches: fixture.expected, fixturePath: fixture.path)
    }

    @Test("valid typical fixture carries synthetic SOAP content only")
    func typicalFixture_isPHIFreeSynthetic() throws {
        let json = try Self.loadText("soap/valid/typical.json")
        let result = Self.builder.validate(json: json)
        guard case let .success(draft) = result else {
            Issue.record("expected success for typical.json")
            return
        }
        #expect(draft.subjective.contains("Synthetic"))
        #expect(draft.manipulations.count == 1)
        #expect(draft.excludedContent.count == 1)
    }
}
