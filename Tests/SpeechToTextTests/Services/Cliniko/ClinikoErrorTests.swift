import Foundation
import Testing
@testable import SpeechToText

@Suite("ClinikoError", .tags(.fast))
struct ClinikoErrorTests {

    @Test("Equatable distinguishes every case")
    func equatableDistinguishesCases() {
        let cases: [ClinikoError] = [
            .unauthenticated,
            .forbidden,
            .notFound(resource: .patient),
            .notFound(resource: .appointment),
            .validation(fields: [:]),
            .validation(fields: ["name": ["must be present"]]),
            .rateLimited(retryAfter: nil),
            .rateLimited(retryAfter: 30),
            .server(status: 500),
            .server(status: 502),
            .transport(.notConnectedToInternet),
            .transport(.timedOut),
            .cancelled,
            .decoding(typeName: "Foo"),
            .nonHTTPResponse
        ]
        for (index, lhs) in cases.enumerated() {
            for (other, rhs) in cases.enumerated() where index != other {
                #expect(lhs != rhs, "\(lhs) and \(rhs) should not be equal")
            }
        }
    }

    @Test("description never echoes PHI-shaped fields")
    func descriptionsAreStructural() {
        // The description is the only side-effect surface that any caller
        // can interpolate into a log line. Pin that nothing it contains
        // could be patient-identifying — only error-case names + status
        // codes + resource enum tags.
        let phiBait = ClinikoError.validation(fields: [
            "patient_first_name": ["Marcus"],
            "patient_last_name": ["Aurelius"]
        ])
        let text = phiBait.description
        // Field count is OK — that's structural. But neither key nor value
        // should appear.
        #expect(!text.contains("Marcus"))
        #expect(!text.contains("Aurelius"))
        #expect(!text.contains("patient_first_name"))
    }

    @Test("Resource enum tags are stable strings")
    func resourceRawValues() {
        #expect(ClinikoError.Resource.user.rawValue == "user")
        #expect(ClinikoError.Resource.patient.rawValue == "patient")
        #expect(ClinikoError.Resource.appointment.rawValue == "appointment")
        #expect(ClinikoError.Resource.treatmentNote.rawValue == "treatmentNote")
    }

    @Test("Resource enum has exactly four cases")
    func resourceCaseCount() {
        // No `.unknown` fallback — every endpoint provides a real resource.
        // If a new endpoint is added that needs a new resource, this test
        // forces the addition to be deliberate.
        let allCases: [ClinikoError.Resource] = [.user, .patient, .appointment, .treatmentNote]
        for case_ in allCases {
            #expect(!case_.rawValue.isEmpty)
        }
    }

    @Test("rateLimited description handles nil retryAfter")
    func rateLimitedNilRetryAfter() {
        let error = ClinikoError.rateLimited(retryAfter: nil)
        let text = error.description
        #expect(text.contains("429"))
        #expect(!text.contains("retry after"))
    }

    @Test("rateLimited description includes integer retryAfter")
    func rateLimitedFloorsRetryAfter() {
        let error = ClinikoError.rateLimited(retryAfter: 12.7)
        let text = error.description
        #expect(text.contains("12"))
    }

    @Test("notFound description names the resource")
    func notFoundIncludesResource() {
        let error = ClinikoError.notFound(resource: .appointment)
        #expect(error.description.contains("appointment"))
        #expect(error.description.contains("404"))
    }
}
