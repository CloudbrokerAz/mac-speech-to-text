// ClinikoDateParserTests.swift
// macOS Local Speech-to-Text Application
//
// Table-driven coverage for `ClinikoDateParser` (#253 / TST-5). Pins
// every offset / fractional shape Cliniko has been observed to emit and
// the PHI-safe `.dateMalformed` failure surface.

import Foundation
import Testing
@testable import SpeechToText

@Suite("ClinikoDateParser", .tags(.fast))
struct ClinikoDateParserTests {

    struct ValidParseCase: Sendable {
        let input: String
        let expectedUTC: String
        let fractionalSeconds: Double?
    }

    private static let validCases: [ValidParseCase] = [
        ValidParseCase(input: "2026-04-25T09:00:00Z", expectedUTC: "2026-04-25T09:00:00Z", fractionalSeconds: nil),
        ValidParseCase(input: "2026-04-25T09:00:00.123Z", expectedUTC: "2026-04-25T09:00:00Z", fractionalSeconds: 0.123),
        ValidParseCase(input: "2026-04-25T19:00:00+10:00", expectedUTC: "2026-04-25T09:00:00Z", fractionalSeconds: nil),
        ValidParseCase(input: "2026-04-25T19:00:00.123+10:00", expectedUTC: "2026-04-25T09:00:00Z", fractionalSeconds: 0.123),
        ValidParseCase(input: "2026-04-25T19:00:00+1000", expectedUTC: "2026-04-25T09:00:00Z", fractionalSeconds: nil),
        ValidParseCase(input: "2026-04-25T19:00:00.123+1000", expectedUTC: "2026-04-25T09:00:00Z", fractionalSeconds: 0.123)
    ]

    private static let malformedInputs: [String] = [
        "definitely not a date",
        "2026-04-25T19:00:00.SHOULD-NOT-LEAK",
        "",
        "   "
    ]

    @Test(
        "parse accepts every documented Cliniko datetime shape",
        .tags(.fast),
        arguments: validCases
    )
    func parse_validInputs(parseCase: ValidParseCase) throws {
        let date = try ClinikoDateParser().parse(parseCase.input)
        let baseline = try #require(ISO8601DateFormatter().date(from: parseCase.expectedUTC))
        if let fractional = parseCase.fractionalSeconds {
            let expected = baseline.timeIntervalSinceReferenceDate + fractional
            let diff = expected - date.timeIntervalSinceReferenceDate
            #expect(abs(diff) < 0.001)
        } else {
            #expect(date == baseline)
        }
    }

    @Test(
        "parse throws ClinikoError.dateMalformed for unparseable input",
        .tags(.fast),
        arguments: malformedInputs
    )
    func parse_malformedInputs(input: String) {
        do {
            _ = try ClinikoDateParser().parse(input)
            Issue.record("expected ClinikoError.dateMalformed for input length \(input.count)")
        } catch ClinikoError.dateMalformed {
            // expected
        } catch {
            Issue.record("expected ClinikoError.dateMalformed, got \(type(of: error))")
        }
    }

    @Test("error surface never echoes the input string (PHI guard)")
    func errorDescription_doesNotEchoInput() {
        let leakyInput = "2026-04-25T19:00:00.SHOULD-NOT-LEAK"
        do {
            _ = try ClinikoDateParser().parse(leakyInput)
            Issue.record("expected throw")
        } catch let error {
            let surface = (error as? ClinikoError)?.description ?? error.localizedDescription
            #expect(!surface.contains("SHOULD-NOT-LEAK"))
            #expect(!surface.contains("2026"))
        }
    }
}
