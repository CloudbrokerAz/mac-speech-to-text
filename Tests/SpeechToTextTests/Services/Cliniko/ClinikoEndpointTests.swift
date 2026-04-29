import Foundation
import Testing
@testable import SpeechToText

@Suite("ClinikoEndpoint", .tags(.fast))
struct ClinikoEndpointTests {

    private let baseURL = URL(string: "https://api.au1.cliniko.com/v1/")!

    // MARK: - Method + path template

    @Test("usersMe is a GET with the right template")
    func usersMeShape() {
        // Cliniko's authenticated-user endpoint is `/v1/user` (singular, no
        // id). The earlier `/users/me` wiring 404'd because Cliniko routes
        // `/users/{id}` numerically — see #88.
        let endpoint = ClinikoEndpoint.usersMe
        #expect(endpoint.method == .get)
        #expect(endpoint.pathTemplate == "/user")
        #expect(endpoint.body == nil)
        #expect(endpoint.contentType == nil)
        #expect(endpoint.isIdempotent)
        #expect(endpoint.resource == .user)
    }

    @Test("patientSearch is a GET with structural template")
    func patientSearchShape() {
        let endpoint = ClinikoEndpoint.patientSearch(query: "smith")
        #expect(endpoint.method == .get)
        // Template now reflects Cliniko's array-shaped filter syntax (#101).
        // Bound query value still excluded — `{filter}` is the placeholder.
        #expect(endpoint.pathTemplate == "/patients?q[]={filter}")
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

    @Test("usersMe URL is /v1/user")
    func usersMeURL() {
        let url = ClinikoEndpoint.usersMe.buildURL(against: baseURL)
        #expect(url?.absoluteString == "https://api.au1.cliniko.com/v1/user")
    }

    @Test("patientSearch URL emits Cliniko's q[]=field:~term filter syntax (single token)")
    func patientSearchURL_singleToken_emitsLastNameFilter() {
        let url = ClinikoEndpoint.patientSearch(query: "smith").buildURL(against: baseURL)
        #expect(url != nil)
        let components = url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }
        let queryItems = components?.queryItems ?? []
        // Single token → q[]=last_name:~smith. Reference: epc-letter-generation
        // ClinikoPatientService.searchPatients(query:) — last_name is the most
        // common surname-only search pattern in the picker UI.
        #expect(queryItems.count == 1, "got \(queryItems)")
        #expect(queryItems.first?.name == "q[]")
        #expect(queryItems.first?.value == "last_name:~smith")
        #expect(components?.path == "/v1/patients")
    }

    @Test("patientSearch URL splits on embedded newlines as well as spaces")
    func patientSearchURL_multiToken_splitsOnEmbeddedNewlines() {
        // A pasted multi-line clipboard ("John\nDoe") used to tokenise as a
        // single value (because `.whitespaces` excludes line terminators),
        // landing on the wire as `last_name:~John%0ADoe`. The split now uses
        // `.whitespacesAndNewlines` so it splits on `\n` / `\r` too — Gemini
        // Code Assist review on PR #112.
        let url = ClinikoEndpoint.patientSearch(query: "John\nDoe")
            .buildURL(against: baseURL)
        let components = url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }
        let items = components?.queryItems ?? []
        #expect(items.count == 2, "got \(items)")
        #expect(items[0].value == "first_name:~John")
        #expect(items[1].value == "last_name:~Doe")
    }

    @Test("patientSearch URL emits q[]=first_name + q[]=last_name for multi-token query")
    func patientSearchURL_multiToken_emitsFirstAndLastNameFilters() {
        let url = ClinikoEndpoint.patientSearch(query: "Mary Jane Smith")
            .buildURL(against: baseURL)
        let components = url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }
        let queryItems = components?.queryItems ?? []
        #expect(queryItems.count == 2, "got \(queryItems)")
        #expect(queryItems[0].name == "q[]")
        #expect(queryItems[0].value == "first_name:~Mary")
        #expect(queryItems[1].name == "q[]")
        // Trailing tokens are joined back together so "Jane Smith" stays a
        // single last-name filter value (handles compound surnames).
        #expect(queryItems[1].value == "last_name:~Jane Smith")
    }

    @Test("patientSearch URL percent-escapes user-supplied special chars in the value")
    func patientSearchURL_percentEscapesSpecialChars() {
        // `&` and `=` would break the query string if unescaped; URLComponents
        // must encode them inside the value half of the URLQueryItem so they
        // can't terminate the filter or introduce a sibling query parameter.
        let url = ClinikoEndpoint.patientSearch(query: "O&Brien=test")
            .buildURL(against: baseURL)
        let absolute = url?.absoluteString ?? ""
        #expect(absolute.contains("/v1/patients"))
        // Single-token branch (no whitespace) → last_name filter. The user
        // input portion is encoded; `:` and `~` in the structural prefix
        // pass through as URL-safe.
        #expect(absolute.contains("q%5B%5D=last_name:~O%26Brien%3Dtest"),
                "expected encoded `&` and `=`, got: \(absolute)")
    }

    @Test("patientSearch with empty / whitespace-only query emits a clean URL with no trailing `?`")
    func patientSearchURL_emptyQuery_hasNoTrailingQuestionMark() {
        // URL hygiene only — `URLComponents.queryItems = []` would still
        // emit `…/patients?` (trailing `?`). Returning `nil` from the
        // endpoint's `queryItems` accessor keeps the URL clean. Note this
        // is NOT the PHI guard against an unfiltered list-all of every
        // patient — that lives in `ClinikoPatientService.searchPatients`.
        for input in ["", "   \t\n  "] {
            let url = ClinikoEndpoint.patientSearch(query: input).buildURL(against: baseURL)
            let absolute = url?.absoluteString ?? ""
            #expect(absolute == "https://api.au1.cliniko.com/v1/patients",
                    "expected clean URL for query \"\(input)\", got: \(absolute)")
            #expect(!absolute.hasSuffix("?"), "trailing `?` for query \"\(input)\"")
            let components = url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }
            #expect(components?.queryItems == nil)
        }
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
