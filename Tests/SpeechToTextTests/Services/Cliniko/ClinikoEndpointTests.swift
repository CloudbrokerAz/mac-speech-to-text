import Foundation
import Testing
@testable import SpeechToText

@Suite("ClinikoEndpoint", .tags(.fast))
struct ClinikoEndpointTests {

    private let baseURL = URL(string: "https://api.au1.cliniko.com/v1/")!

    // MARK: - Method + path template

    @Test("usersMe is a GET with the right template")
    func usersMeShape() {
        let endpoint = ClinikoEndpoint.usersMe
        #expect(endpoint.method == .get)
        #expect(endpoint.pathTemplate == "/users/me")
        #expect(endpoint.body == nil)
        #expect(endpoint.contentType == nil)
        #expect(endpoint.isIdempotent)
        #expect(endpoint.resource == .user)
    }

    @Test("patientSearch is a GET with structural template")
    func patientSearchShape() {
        let endpoint = ClinikoEndpoint.patientSearch(query: "smith")
        #expect(endpoint.method == .get)
        #expect(endpoint.pathTemplate == "/patients?q={query}")
        #expect(endpoint.body == nil)
        #expect(endpoint.isIdempotent)
        #expect(endpoint.resource == .patient)
    }

    @Test("patientAppointments is a GET with id-template")
    func patientAppointmentsShape() {
        let endpoint = ClinikoEndpoint.patientAppointments(
            patientID: "12345",
            from: Date(timeIntervalSince1970: 0),
            to: Date(timeIntervalSince1970: 86_400)
        )
        #expect(endpoint.method == .get)
        #expect(endpoint.pathTemplate == "/patients/:id/appointments")
        // The bound id MUST NOT be in the template (PHI logging rule).
        #expect(!endpoint.pathTemplate.contains("12345"))
        #expect(endpoint.isIdempotent)
        #expect(endpoint.resource == .patient)
    }

    @Test("createTreatmentNote is a POST that is not idempotent")
    func createTreatmentNoteShape() {
        let body = Data("{}".utf8)
        let endpoint = ClinikoEndpoint.createTreatmentNote(body: body)
        #expect(endpoint.method == .post)
        #expect(endpoint.pathTemplate == "/treatment_notes")
        #expect(endpoint.body == body)
        #expect(endpoint.contentType == "application/json")
        #expect(!endpoint.isIdempotent,
                "POST treatment_notes must not auto-retry on 5xx OR transport (duplicate-write guard)")
        #expect(endpoint.resource == .treatmentNote)
    }

    // MARK: - URL building

    @Test("usersMe URL is /v1/users/me")
    func usersMeURL() {
        let url = ClinikoEndpoint.usersMe.buildURL(against: baseURL)
        #expect(url?.absoluteString == "https://api.au1.cliniko.com/v1/users/me")
    }

    @Test("patientSearch URL encodes the query")
    func patientSearchURL() {
        let url = ClinikoEndpoint.patientSearch(query: "John & Jane").buildURL(against: baseURL)
        // The query must be percent-encoded; `&` becomes `%26`, space becomes `%20`.
        #expect(url != nil)
        let absolute = url?.absoluteString ?? ""
        #expect(absolute.contains("/v1/patients"))
        #expect(absolute.contains("q="))
        // URLComponents standard encoding turns space into "%20"
        #expect(absolute.contains("John%20%26%20Jane") || absolute.contains("John+%26+Jane"))
    }

    @Test("patientAppointments URL embeds id + ISO8601 dates")
    func patientAppointmentsURL() {
        let from = Date(timeIntervalSince1970: 0)
        let to = Date(timeIntervalSince1970: 86_400)
        let url = ClinikoEndpoint.patientAppointments(patientID: "12345", from: from, to: to)
            .buildURL(against: baseURL)
        let absolute = url?.absoluteString ?? ""
        #expect(absolute.contains("/v1/patients/12345/appointments"))
        #expect(absolute.contains("from="))
        #expect(absolute.contains("to="))
        // ISO8601 1970-01-01 / 1970-01-02 — exact format may include a "Z".
        #expect(absolute.contains("1970-01-01T00%3A00%3A00Z") || absolute.contains("1970-01-01T00:00:00Z"))
    }

    @Test("patientAppointments percent-encodes weird patient IDs")
    func patientAppointmentsPercentEncodesID() {
        let url = ClinikoEndpoint.patientAppointments(
            patientID: "12 345/abc",
            from: Date(timeIntervalSince1970: 0),
            to: Date(timeIntervalSince1970: 1)
        ).buildURL(against: baseURL)
        let absolute = url?.absoluteString ?? ""
        // Space → %20 and slash → %2F, so the id stays a single path
        // segment between `/patients/` and `/appointments`.
        #expect(absolute.contains("/v1/patients/12%20345%2Fabc/appointments"),
                "got \(absolute)")
    }

    @Test("createTreatmentNote URL is /v1/treatment_notes")
    func createTreatmentNoteURL() {
        let url = ClinikoEndpoint.createTreatmentNote(body: Data())
            .buildURL(against: baseURL)
        #expect(url?.absoluteString == "https://api.au1.cliniko.com/v1/treatment_notes")
    }

    // MARK: - Cross-shard URL building

    @Test("buildURL returns non-nil for every shard × endpoint combo")
    func buildURLSucceedsForEveryShardAndEndpoint() throws {
        let endpoints: [ClinikoEndpoint] = [
            .usersMe,
            .patientSearch(query: "x"),
            .patientAppointments(patientID: "1", from: Date(), to: Date()),
            .createTreatmentNote(body: Data())
        ]
        for shard in ClinikoShard.allCases {
            let creds = try ClinikoCredentials(apiKey: "k", shard: shard)
            for endpoint in endpoints {
                let url = endpoint.buildURL(against: creds.baseURL)
                #expect(url != nil, "\(shard) × \(endpoint.pathTemplate) produced nil URL")
            }
        }
    }

    // MARK: - ISO8601 helper

    @Test("iso8601 formatter emits UTC")
    func iso8601IsUTC() {
        let formatted = ClinikoEndpoint.iso8601(Date(timeIntervalSince1970: 0))
        #expect(formatted == "1970-01-01T00:00:00Z")
    }

    // MARK: - Equatable

    @Test("Equatable separates same-case values")
    func equatableShape() {
        #expect(ClinikoEndpoint.usersMe == ClinikoEndpoint.usersMe)
        #expect(ClinikoEndpoint.patientSearch(query: "a") != .patientSearch(query: "b"))
        #expect(ClinikoEndpoint.patientAppointments(patientID: "1", from: Date(timeIntervalSince1970: 0), to: Date(timeIntervalSince1970: 1))
                != .patientAppointments(patientID: "2", from: Date(timeIntervalSince1970: 0), to: Date(timeIntervalSince1970: 1)))
    }
}
