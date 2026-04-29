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
        XCTAssertEqual(patients.first?.id, 1001)
        XCTAssertEqual(patients.first?.firstName, "Sample")
        XCTAssertEqual(patients.first?.lastName, "Patient")
        XCTAssertEqual(patients.first?.dateOfBirth, "1980-01-15")
        XCTAssertEqual(patients.first?.email, "sample.patient@example.test")
        XCTAssertNil(patients.last?.dateOfBirth)
        XCTAssertNil(patients.last?.email)
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
