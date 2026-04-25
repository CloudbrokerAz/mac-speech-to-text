import Foundation
import XCTest
@testable import SpeechToText

/// End-to-end behaviour tests for `ClinikoAppointmentService`. Exercises
/// payload decoding, the 7-day-back / 1-day-forward window definition, and
/// error pass-through from `ClinikoClient`.
///
/// Why XCTest (not Swift Testing): see `ClinikoPatientServiceTests` —
/// `URLProtocolStub` is a process-wide singleton; XCTest serialises within
/// a class while Swift Testing parallelises. Refactor tracked in #30.
final class ClinikoAppointmentServiceTests: XCTestCase {

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
    ) throws -> ClinikoAppointmentService {
        let config = URLProtocolStub.install(responder)
        let session = URLSession(configuration: config)
        let client = ClinikoClient(
            credentials: try credentials(),
            session: session,
            userAgent: "appointment-service-tests/1.0",
            retryPolicy: .immediate
        )
        return ClinikoAppointmentService(client: client)
    }

    // MARK: - Happy path + decoding

    func test_appointments_decodesPayload() async throws {
        let service = try makeService { request in
            let body = try HTTPStubFixture.load("cliniko/responses/patient_appointments.json")
            let response = HTTPURLResponse(
                url: request.url ?? URL(string: "https://example.test")!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, body)
        }

        let reference = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-04-25T12:00:00Z"))
        let appointments = try await service.recentAndTodayAppointments(
            forPatientID: "1001",
            reference: reference
        )

        XCTAssertEqual(appointments.count, 3)
        XCTAssertEqual(appointments.first?.id, 5001)
        let firstStart = ISO8601DateFormatter().date(from: "2026-04-25T09:00:00Z")
        XCTAssertEqual(appointments.first?.startsAt, firstStart)
        XCTAssertNotNil(appointments.first?.endsAt)
    }

    // MARK: - Window definition

    func test_appointments_emitsCorrectFromAndToWindowEdges() async throws {
        let captured = CapturedRequestBox()
        let service = try makeService { request in
            captured.set(request)
            let body = try HTTPStubFixture.load("cliniko/responses/patient_appointments.json")
            let response = HTTPURLResponse(
                url: request.url ?? URL(string: "https://example.test")!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, body)
        }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(identifier: "UTC")
        let reference = try XCTUnwrap(formatter.date(from: "2026-04-25T12:00:00Z"))

        _ = try await service.recentAndTodayAppointments(
            forPatientID: "1001",
            reference: reference
        )

        let url = try XCTUnwrap(captured.value?.url)
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let queryItems = components.queryItems ?? []
        let from = queryItems.first { $0.name == "from" }?.value
        let to = queryItems.first { $0.name == "to" }?.value
        XCTAssertEqual(from, "2026-04-18T12:00:00Z")
        XCTAssertEqual(to, "2026-04-26T12:00:00Z")
    }

    func test_appointments_pathPercentEncodesPatientID() async throws {
        let captured = CapturedRequestBox()
        let service = try makeService { request in
            captured.set(request)
            let body = try HTTPStubFixture.load("cliniko/responses/patient_appointments.json")
            let response = HTTPURLResponse(
                url: request.url ?? URL(string: "https://example.test")!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: nil
            )!
            return (response, body)
        }

        // ID containing characters that would otherwise split the path —
        // not realistic for Cliniko (numeric IDs) but defence-in-depth.
        _ = try await service.recentAndTodayAppointments(
            forPatientID: "weird id/with/slashes",
            reference: Date()
        )

        let url = try XCTUnwrap(captured.value?.url)
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let template = "/v1/patients/weird%20id%2Fwith%2Fslashes/appointments"
        XCTAssertEqual(components.percentEncodedPath, template)
    }

    // MARK: - Error mapping

    func test_appointments_401_mapsToUnauthenticated() async throws {
        try await assertAppointmentsError(status: 401, expected: .unauthenticated)
    }

    func test_appointments_404_mapsToNotFoundPatient() async throws {
        try await assertAppointmentsError(
            status: 404,
            expected: .notFound(resource: .patient)
        )
    }

    private func assertAppointmentsError(
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
            _ = try await service.recentAndTodayAppointments(
                forPatientID: "1001",
                reference: Date()
            )
            XCTFail("expected \(expected), got success", file: file, line: line)
        } catch let error as ClinikoError {
            XCTAssertEqual(error, expected, file: file, line: line)
        } catch {
            XCTFail("expected ClinikoError, got \(error)", file: file, line: line)
        }
    }
}
