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

    func test_searchPatients_emitsQueryItem() async throws {
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

        _ = try await service.searchPatients(query: "doe smith")

        let url = try XCTUnwrap(captured.value?.url)
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let queryValue = components.queryItems?.first { $0.name == "q" }?.value
        XCTAssertEqual(queryValue, "doe smith")
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
