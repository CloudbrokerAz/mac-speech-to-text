import Foundation
import XCTest
@testable import SpeechToText

/// End-to-end behaviour tests for `ClinikoPatientService` against
/// `URLProtocolStub`. Scoped to what the picker UI cares about:
/// query-item shape, decoded payload, error pass-through, cancellation.
///
/// Why XCTest (and not Swift Testing): `URLProtocolStub` keeps a single
/// process-wide responder. XCTest serialises test methods within a class
/// by default; Swift Testing parallelises them, so two `@Test`s would
/// race the responder. Refactor tracked in #30.
final class ClinikoPatientServiceTests: XCTestCase {

    override func tearDown() {
        URLProtocolStub.reset()
        super.tearDown()
    }

    // MARK: - Helpers

    private func credentials() throws -> ClinikoCredentials {
        try ClinikoCredentials(apiKey: "MS-test-au1", shard: .au1)
    }

    private func makeService(
        responder: @escaping URLProtocolStub.Responder
    ) throws -> ClinikoPatientService {
        let config = URLProtocolStub.install(responder)
        let session = URLSession(configuration: config)
        let client = ClinikoClient(
            credentials: try credentials(),
            session: session,
            userAgent: "patient-service-tests/1.0",
            retryPolicy: .immediate
        )
        return ClinikoPatientService(client: client)
    }

    // MARK: - Happy path

    func test_searchPatients_decodesPayload() async throws {
        let service = try makeService { request in
            let body = try HTTPStubFixture.load("cliniko/responses/patients_search.json")
            let response = HTTPURLResponse(
                url: request.url ?? URL(string: "https://example.test")!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, body)
        }

        let patients = try await service.searchPatients(query: "sample")

        XCTAssertEqual(patients.count, 3)
        XCTAssertEqual(patients.first?.id, "1001")
        XCTAssertEqual(patients.first?.firstName, "Sample")
        XCTAssertEqual(patients.first?.lastName, "Patient")
        XCTAssertEqual(patients.first?.dateOfBirth, "1980-01-15")
        XCTAssertEqual(patients.first?.email, "sample.patient@example.test")
        XCTAssertNil(patients.last?.dateOfBirth)
        XCTAssertNil(patients.last?.email)
    }

    /// Regression pin for #127. Cliniko returns `null` for `first_name`
    /// and/or `last_name` on archived / contact-only / incomplete-record
    /// rows. Earlier `Patient` declared both non-optional, so any
    /// populated response containing one of these rows surfaced as
    /// `ClinikoError.decoding` and the picker landed on
    /// "unexpected response shape". Both the single-token URL path
    /// (`q[]=last_name:~Doe`) and the multi-token path
    /// (`q[]=first_name:~Jane&q[]=last_name:~Doe`) route through the
    /// same `[Patient]` decode, so this test exercises the single-
    /// token URL and the sibling below covers the multi-token URL.
    func test_searchPatients_partialNames_singleTokenURL_decodesCleanly() async throws {
        let captured = CapturedRequestBox()
        let service = try makeService { request in
            captured.set(request)
            let body = try HTTPStubFixture.load(
                "cliniko/responses/patients_search_partial_names.json"
            )
            let response = HTTPURLResponse(
                url: request.url ?? URL(string: "https://example.test")!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, body)
        }

        let patients = try await service.searchPatients(query: "doe")

        // Single-token URL — pin the wire shape for the regression.
        let url = try XCTUnwrap(captured.value?.url)
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.queryItems?.first?.value, "last_name:~doe")

        // Archived row (id=2004) is filtered server-shape-side; the
        // first three rows survive. Each row exercises a different
        // null-name shape: only first_name, only last_name, both null.
        XCTAssertEqual(patients.count, 3)
        XCTAssertEqual(patients[0].id, "2001")
        XCTAssertEqual(patients[0].firstName, "Sample")
        XCTAssertNil(patients[0].lastName)
        XCTAssertEqual(patients[1].id, "2002")
        XCTAssertNil(patients[1].firstName)
        XCTAssertEqual(patients[1].lastName, "Subject")
        XCTAssertEqual(patients[2].id, "2003")
        XCTAssertNil(patients[2].firstName)
        XCTAssertNil(patients[2].lastName)
        // Display-name fallback — the both-null row must render
        // something the picker UI can display.
        XCTAssertEqual(patients[2].displayName, "Unnamed patient")
    }

    /// Regression pin for #127 — same fixture, multi-token URL path.
    /// `Jane Doe` → `q[]=first_name:~Jane&q[]=last_name:~Doe`.
    func test_searchPatients_partialNames_multiTokenURL_decodesCleanly() async throws {
        let captured = CapturedRequestBox()
        let service = try makeService { request in
            captured.set(request)
            let body = try HTTPStubFixture.load(
                "cliniko/responses/patients_search_partial_names.json"
            )
            let response = HTTPURLResponse(
                url: request.url ?? URL(string: "https://example.test")!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, body)
        }

        let patients = try await service.searchPatients(query: "Jane Doe")

        let url = try XCTUnwrap(captured.value?.url)
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let items = components.queryItems ?? []
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items[0].value, "first_name:~Jane")
        XCTAssertEqual(items[1].value, "last_name:~Doe")
        // Same three surviving rows as the single-token path — both
        // routes share the `[Patient]` decode.
        XCTAssertEqual(patients.count, 3)
    }

    /// Archived rows are filtered out at the service layer (#127).
    /// Cliniko's `q[]=last_name:~` filter does not exclude archived
    /// patients server-side; surfacing them in the picker confuses
    /// selection because their name fields are typically stripped.
    /// This test pins the filter so a future "show archived" toggle
    /// becomes an explicit choice rather than an accidental regression.
    func test_searchPatients_filtersArchivedRows() async throws {
        let service = try makeService { request in
            let body = try HTTPStubFixture.load(
                "cliniko/responses/patients_search_partial_names.json"
            )
            let response = HTTPURLResponse(
                url: request.url ?? URL(string: "https://example.test")!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, body)
        }

        let patients = try await service.searchPatients(query: "row")

        // Fixture has 4 rows — id=2004 is archived (`archived_at` is
        // set). The service should drop it so only 3 reach the UI.
        XCTAssertEqual(patients.count, 3)
        XCTAssertFalse(patients.contains { $0.id == "2004" })
    }

    /// PHI guard for the partial-names path (#127). The fixture
    /// deliberately does NOT round-trip through `.decoding` — that
    /// covers the non-PHI structural log already pinned by
    /// `test_searchPatients_malformedJSON_mapsToDecoding`. This test
    /// instead asserts the surfaced `Patient` array's display strings
    /// can be rendered by the picker without leaking the row IDs as
    /// PHI-shaped tokens into Swift's reflection-based interpolation.
    /// Specifically: the both-null row's `displayName` must be the
    /// fallback string, never a Swift-reflection echo of `nil`.
    func test_searchPatients_partialNames_displayNameNeverLeaksOptionalReflection() async throws {
        let service = try makeService { request in
            let body = try HTTPStubFixture.load(
                "cliniko/responses/patients_search_partial_names.json"
            )
            let response = HTTPURLResponse(
                url: request.url ?? URL(string: "https://example.test")!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, body)
        }

        let patients = try await service.searchPatients(query: "guard")

        for patient in patients {
            // Reflection-based interpolation of an Optional renders as
            // `Optional("...")` or `nil`. The picker view-model used to
            // build a display name with raw `\(patient.firstName)`,
            // which would surface `Optional(...)` after the field
            // turned nullable. `displayName` is the fix. Pin that the
            // render string never carries that form.
            XCTAssertFalse(patient.displayName.contains("Optional("),
                           "displayName should never echo Swift's Optional reflection")
            XCTAssertFalse(patient.displayName.contains("nil"),
                           "displayName should never echo a literal nil")
            XCTAssertFalse(patient.displayName.isEmpty,
                           "displayName should always be non-empty (fallback covers all-nil rows)")
        }
    }

    /// End-to-end pin (#101): a single-word query produces Cliniko's
    /// array-shaped `q[]=last_name:~term` filter on the wire. The
    /// duplication with `ClinikoEndpointTests.patientSearchURL_…` is
    /// intentional — this asserts the *whole* call path from
    /// `searchPatients(query:)` through `ClinikoClient.send(_:)` lands
    /// the right bytes in the URL, not just the endpoint enum in isolation.
    func test_searchPatients_singleToken_emitsLastNameFilter() async throws {
        let captured = CapturedRequestBox()
        let service = try makeService { request in
            captured.set(request)
            let body = try HTTPStubFixture.load("cliniko/responses/patients_search_empty.json")
            let response = HTTPURLResponse(
                url: request.url ?? URL(string: "https://example.test")!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, body)
        }

        _ = try await service.searchPatients(query: "smith")

        let url = try XCTUnwrap(captured.value?.url)
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let items = components.queryItems ?? []
        XCTAssertEqual(items.count, 1, "got \(items)")
        XCTAssertEqual(items.first?.name, "q[]")
        XCTAssertEqual(items.first?.value, "last_name:~smith")
        XCTAssertEqual(components.path, "/v1/patients")
    }

    /// Multi-token queries split on whitespace: first token → first_name
    /// filter, remainder joined back together → last_name filter. Mirrors
    /// the reference impl in `epc-letter-generation`.
    func test_searchPatients_multiToken_emitsFirstAndLastNameFilters() async throws {
        let captured = CapturedRequestBox()
        let service = try makeService { request in
            captured.set(request)
            let body = try HTTPStubFixture.load("cliniko/responses/patients_search_empty.json")
            let response = HTTPURLResponse(
                url: request.url ?? URL(string: "https://example.test")!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, body)
        }

        // Compound surname: "Mary Jane Smith" → first_name=Mary, last_name="Jane Smith".
        _ = try await service.searchPatients(query: "Mary Jane Smith")

        let url = try XCTUnwrap(captured.value?.url)
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let items = components.queryItems ?? []
        XCTAssertEqual(items.count, 2, "got \(items)")
        XCTAssertEqual(items[0].name, "q[]")
        XCTAssertEqual(items[0].value, "first_name:~Mary")
        XCTAssertEqual(items[1].name, "q[]")
        XCTAssertEqual(items[1].value, "last_name:~Jane Smith")
        XCTAssertEqual(components.path, "/v1/patients")
    }

    func test_searchPatients_emptyResponse_returnsEmptyArray() async throws {
        let service = try makeService { request in
            let body = try HTTPStubFixture.load("cliniko/responses/patients_search_empty.json")
            let response = HTTPURLResponse(
                url: request.url ?? URL(string: "https://example.test")!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, body)
        }

        let patients = try await service.searchPatients(query: "zzznomatchzzz")
        XCTAssertTrue(patients.isEmpty)
    }

    // MARK: - Error mapping (pass-through from ClinikoClient)

    func test_searchPatients_401_mapsToUnauthenticated() async throws {
        try await assertSearchError(status: 401, expected: .unauthenticated)
    }

    func test_searchPatients_403_mapsToForbidden() async throws {
        try await assertSearchError(status: 403, expected: .forbidden)
    }

    func test_searchPatients_404_mapsToNotFoundPatient() async throws {
        try await assertSearchError(
            status: 404,
            expected: .notFound(resource: .patient)
        )
    }

    func test_searchPatients_503_afterRetriesExhausted_mapsToServer() async throws {
        try await assertSearchError(status: 503, expected: .server(status: 503))
    }

    // MARK: - Empty / whitespace queries (PHI list-all guard)

    /// Without the service-layer empty-query guard, a bare `searchPatients(query: "")`
    /// would issue `GET /v1/patients` with no filter and Cliniko would
    /// return EVERY patient in the tenant — a silent PHI exfiltration if
    /// any future caller bypasses the picker VM's empty-check. The guard
    /// short-circuits to `[]` and never touches the network.
    func test_searchPatients_emptyQuery_returnsEmptyArray_withoutNetworkCall() async throws {
        let invocationCount = CallCounter()
        let service = try makeService { _ in
            _ = invocationCount.increment()
            // Still return a well-formed response so a regression in the
            // guard fails the count assertion below rather than crashing
            // somewhere downstream — the test is about whether the request
            // happens, not what comes back.
            let body = try HTTPStubFixture.load("cliniko/responses/patients_search_empty.json")
            let response = HTTPURLResponse(
                url: URL(string: "https://example.test")!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, body)
        }

        let empty = try await service.searchPatients(query: "")
        let whitespace = try await service.searchPatients(query: "   \t\n  ")

        XCTAssertTrue(empty.isEmpty)
        XCTAssertTrue(whitespace.isEmpty)
        XCTAssertEqual(invocationCount.value, 0,
                       "empty / whitespace queries must not hit the network")
    }

    /// 429 with `Retry-After: 0` exhausts the immediate-retry policy budget
    /// and surfaces as `.rateLimited(retryAfter: 0)`. The picker UI maps
    /// this to "Cliniko is throttling requests. Try again shortly." — a
    /// distinct error path from the generic `.server` we used to fall into.
    func test_searchPatients_429_exhaustsBudget_mapsToRateLimited() async throws {
        let service = try makeService { request in
            let response = HTTPURLResponse(
                url: request.url ?? URL(string: "https://example.test")!,
                statusCode: 429,
                httpVersion: "HTTP/1.1",
                headerFields: ["Retry-After": "0"]
            )!
            return (response, Data())
        }
        do {
            _ = try await service.searchPatients(query: "anything")
            XCTFail("expected ClinikoError.rateLimited")
        } catch ClinikoError.rateLimited(let retryAfter) {
            XCTAssertEqual(retryAfter, 0)
        } catch {
            XCTFail("expected .rateLimited, got \(error)")
        }
    }

    /// 200 with a body that does not decode into `PatientSearchResponse`
    /// surfaces as `.decoding(typeName:)`. Cliniko has occasionally shipped
    /// envelope changes (e.g. renaming `total_entries`) and we want the
    /// picker to render an unambiguous "report this" path rather than a
    /// generic "server error" fallthrough.
    func test_searchPatients_malformedJSON_mapsToDecoding() async throws {
        // Body parses as JSON but lacks the required `patients` array, so
        // PatientSearchResponse cannot decode. PHI: synthetic, no patient data.
        let body = Data(#"{"unexpected_envelope": true}"#.utf8)
        let service = try makeService { request in
            let response = HTTPURLResponse(
                url: request.url ?? URL(string: "https://example.test")!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, body)
        }
        do {
            _ = try await service.searchPatients(query: "anything")
            XCTFail("expected ClinikoError.decoding")
        } catch ClinikoError.decoding(let typeName) {
            XCTAssertTrue(
                typeName.contains("PatientSearchResponse"),
                "typeName should identify the decoding target; got \(typeName)"
            )
        } catch {
            XCTFail("expected .decoding, got \(error)")
        }
    }

    // MARK: - Cancellation

    func test_searchPatients_urlSessionCancelled_mapsToClinikoCancelled() async throws {
        let service = try makeService { _ in
            throw URLError(.cancelled)
        }
        do {
            _ = try await service.searchPatients(query: "anything")
            XCTFail("expected ClinikoError.cancelled")
        } catch let error as ClinikoError {
            XCTAssertEqual(error, .cancelled)
        } catch {
            XCTFail("expected ClinikoError, got \(error)")
        }
    }

    // MARK: - Helpers

    private func assertSearchError(
        status: Int,
        expected: ClinikoError,
        file: StaticString = #file,
        line: UInt = #line
    ) async throws {
        let service = try makeService { request in
            let response = HTTPURLResponse(
                url: request.url ?? URL(string: "https://example.test")!,
                statusCode: status,
                httpVersion: "HTTP/1.1",
                headerFields: nil
            )!
            return (response, Data())
        }
        do {
            _ = try await service.searchPatients(query: "anything")
            XCTFail("expected \(expected), got success", file: file, line: line)
        } catch let error as ClinikoError {
            XCTAssertEqual(error, expected, file: file, line: line)
        } catch {
            XCTFail("expected ClinikoError, got \(error)", file: file, line: line)
        }
    }
}

/// Counts how many times a URLProtocolStub responder is invoked. Mirrors
/// the helper of the same name in `ClinikoClientTests` (kept private per
/// file to dodge `URLProtocolStub` cross-suite races — see #30).
private final class CallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    @discardableResult
    func increment() -> Int {
        lock.lock(); defer { lock.unlock() }
        count += 1
        return count
    }

    var value: Int {
        lock.lock(); defer { lock.unlock() }
        return count
    }
}

/// Captures the most recent request seen by the URLProtocolStub responder.
/// Lockless `@unchecked Sendable` because the lock guards every access.
final class CapturedRequestBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: URLRequest?

    func set(_ request: URLRequest) {
        lock.lock(); defer { lock.unlock() }
        stored = request
    }

    var value: URLRequest? {
        lock.lock(); defer { lock.unlock() }
        return stored
    }
}
