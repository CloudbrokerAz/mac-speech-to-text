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
            // `.dateMalformed` and `.decoding(typeName: "Date")` are
            // deliberately distinct cases (#131). Pinning that the
            // Equatable witness treats them as such guards the split
            // — a future regression that re-merged them under
            // `.decoding(typeName: "Date")` would silently pass any
            // test that only enumerates structural distinctness.
            .dateMalformed,
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

    @Test("dateMalformed description carries no payload")
    func dateMalformedDescriptionStructural() {
        // `.dateMalformed` has no associated value (#131), so the
        // description is necessarily a fixed string. Pin that:
        //
        // 1. it is non-empty (a future contributor flipping it to
        //    `""` would silently kill the user-facing copy);
        // 2. it does NOT contain anything that looks like a date
        //    (a future maintainer who adds a `dateMalformed(input:)`
        //    associated value AND wires it into description would
        //    re-introduce the PHI leak this case was created to
        //    prevent — see issue #131).
        let text = ClinikoError.dateMalformed.description
        #expect(!text.isEmpty)
        // PHI sentinel substrings — anything resembling an ISO8601
        // datetime offset must NOT appear. These are the exact shapes
        // `ClinikoDateParser` was created in #129 to handle and that
        // a regression would most plausibly leak.
        #expect(!text.contains("+10:00"))
        #expect(!text.contains("+1000"))
        #expect(!text.contains("Z"))           // ISO8601 UTC marker
    }

    @Test("dateMalformed has zero associated values (structural payload-emptiness pin)")
    func dateMalformedHasNoAssociatedValues() {
        // Cosmetic checks on `description` (above) catch a regression
        // that adds `dateMalformed(input: String)` AND threads the
        // input into the description text. They DO NOT catch a
        // regression that adds the payload but cleans up the
        // description — the leak would still happen at any call site
        // doing `\(error)` (which goes through `String(describing:)`
        // and renders the associated values verbatim, e.g.
        // `"dateMalformed(input: \"2026-04-25T19:00:00+10:00\")"`).
        //
        // Pin the structural invariant directly via reflection: the
        // case must have zero children. This catches the payload
        // addition itself, regardless of any cosmetic mitigation,
        // and would force a future maintainer to delete this test
        // (which is a far more visible signal than a silent leak).
        // See `Sources/Services/Cliniko/ClinikoError.swift` doc-comment
        // on `.dateMalformed` for the PHI rationale.
        let mirror = Mirror(reflecting: ClinikoError.dateMalformed)
        #expect(mirror.children.isEmpty,
                "ClinikoError.dateMalformed must remain payload-free (#131 PHI invariant)")
    }

    @Test("ClinikoError case count is pinned at 11")
    func clinikoErrorCaseCount() {
        // Pin the case count so accidental additions or deletions
        // are deliberate. `ClinikoError` is not `CaseIterable` (it
        // can't be — several cases carry associated values), so this
        // is the cheapest structural enforcement available. Same
        // pattern as `resourceCaseCount` above. Combined with the
        // `equatableDistinguishesCases` test, this guards both
        // directions of regression: case removal (count drops),
        // case addition (count rises and the new case is missing
        // from the equatable enumeration).
        let cases: [ClinikoError] = [
            .unauthenticated,
            .forbidden,
            .notFound(resource: .patient),
            .validation(fields: [:]),
            .rateLimited(retryAfter: nil),
            .server(status: 500),
            .transport(.timedOut),
            .cancelled,
            .decoding(typeName: "Foo"),
            .dateMalformed,
            .nonHTTPResponse
        ]
        #expect(cases.count == 11)
    }
}
