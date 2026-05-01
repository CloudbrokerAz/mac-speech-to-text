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

        // Fixture has 3 rows. None are cancelled / archived / DNA — all
        // should reach the picker. Service applies a defensive descending
        // sort by startsAt on top of Cliniko's server-side sort, so the
        // 2026-04-25 slot lands at index 0.
        XCTAssertEqual(appointments.count, 3)
        XCTAssertEqual(appointments[0].id, "5001")
        XCTAssertEqual(appointments[1].id, "5002")
        XCTAssertEqual(appointments[2].id, "5003")
        let firstStart = ISO8601DateFormatter().date(from: "2026-04-25T09:00:00Z")
        XCTAssertEqual(appointments.first?.startsAt, firstStart)
        XCTAssertNotNil(appointments.first?.endsAt)
        // Nested ref extraction (DTO LinkRef.trailingID) — pin that the
        // appointment-type / practitioner IDs flow through from the
        // wire's `links.self` URL on the rows that carry them.
        XCTAssertEqual(appointments[0].appointmentTypeID, "4321")
        XCTAssertEqual(appointments[0].practitionerID, "9001")
        // Row 5003 omits the nested objects entirely → both nil.
        XCTAssertNil(appointments[2].appointmentTypeID)
        XCTAssertNil(appointments[2].practitionerID)
        // No cancelled / archived / DNA in this fixture.
        XCTAssertFalse(appointments.contains { $0.isCancelled })
    }

    /// Regression pin for #129. Cliniko's `q[]=cancelled_at:!?`
    /// server-side filter is what *should* drop cancelled rows, but the
    /// service layer re-applies the wider `!isCancelled` filter
    /// (`cancelled_at` OR `archived_at` OR `did_not_arrive == true`) so
    /// a Cliniko regression in either filter or sort semantics doesn't
    /// cascade into the picker.
    func test_appointments_filtersCancelledArchivedAndDidNotArriveRows() async throws {
        let service = try makeService { request in
            let body = try HTTPStubFixture.load(
                "cliniko/responses/patient_appointments_with_cancelled.json"
            )
            let response = HTTPURLResponse(
                url: request.url ?? URL(string: "https://example.test")!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, body)
        }

        let appointments = try await service.recentAndTodayAppointments(
            forPatientID: "1001",
            reference: Date()
        )

        // Fixture has 4 rows: 6001 active, 6002 cancelled, 6003 archived,
        // 6004 did-not-arrive. Only 6001 should reach the picker.
        XCTAssertEqual(appointments.count, 1)
        XCTAssertEqual(appointments.first?.id, "6001")
        XCTAssertFalse(appointments.first?.isCancelled ?? true)
    }

    /// Regression pin for #129. Defensive client-side sort (descending
    /// by `startsAt`) is applied on top of Cliniko's server-side
    /// `sort=starts_at&order=desc`. A future Cliniko sort regression
    /// must not surface as out-of-order appointments in the picker.
    func test_appointments_resultsAreSortedDescendingByStartsAt() async throws {
        let service = try makeService { request in
            let body = try HTTPStubFixture.load("cliniko/responses/patient_appointments.json")
            let response = HTTPURLResponse(
                url: request.url ?? URL(string: "https://example.test")!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: nil
            )!
            return (response, body)
        }

        let appointments = try await service.recentAndTodayAppointments(
            forPatientID: "1001",
            reference: Date()
        )

        let starts = appointments.map(\.startsAt)
        XCTAssertEqual(starts, starts.sorted(by: >))
    }

    /// Regression pin for #129. Cliniko AU shards return ISO8601 in
    /// three distinct shapes: `+10:00` (RFC3339 with colon), `+1000`
    /// (ISO8601 basic offset, NO colon — `ISO8601DateFormatter`
    /// rejects this regardless of options), and either with optional
    /// fractional seconds. `ClinikoDateParser` cascades through four
    /// formatters to handle all of them; the previous global
    /// `.iso8601` decoder strategy did not.
    func test_appointments_decodesAUShardOffsetVariants() async throws {
        let service = try makeService { request in
            let body = try HTTPStubFixture.load(
                "cliniko/responses/patient_appointments_au_with_offset.json"
            )
            let response = HTTPURLResponse(
                url: request.url ?? URL(string: "https://example.test")!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: nil
            )!
            return (response, body)
        }

        let appointments = try await service.recentAndTodayAppointments(
            forPatientID: "1001",
            reference: Date()
        )

        // 4 rows, all decode. Each represents the same instant
        // (2026-04-25 09:00:00 UTC, AEST = UTC+10) modulo fractional
        // seconds.
        // 7001: +10:00 form (with colon) at 19:00 AEST = 09:00 UTC.
        // 7002: +1000 form (no colon) at 19:00 AEST = 09:00 UTC.
        // 7003: Z form with fractional seconds 09:00:00.123Z.
        // 7004: +10:00 form with fractional seconds 19:00:00.123+10:00.
        XCTAssertEqual(appointments.count, 4)
        let utcInstant = try XCTUnwrap(
            ISO8601DateFormatter().date(from: "2026-04-25T09:00:00Z")
        )
        let utcFractionalReference = utcInstant.timeIntervalSinceReferenceDate + 0.123

        XCTAssertEqual(appointments.first { $0.id == "7001" }?.startsAt, utcInstant)
        XCTAssertEqual(appointments.first { $0.id == "7002" }?.startsAt, utcInstant)
        // Fractional-second equality compares with a tolerance because
        // `addingTimeInterval(0.123)` and direct ISO8601 fractional
        // parse return values that differ by sub-microsecond
        // floating-point representation drift. The tolerance is
        // 1ms — well below the sub-second precision we care about
        // semantically (it's a clinical note, not a financial trade).
        let fractional7003 = try XCTUnwrap(appointments.first { $0.id == "7003" }?.startsAt)
        let fractional7004 = try XCTUnwrap(appointments.first { $0.id == "7004" }?.startsAt)
        XCTAssertEqual(fractional7003.timeIntervalSinceReferenceDate, utcFractionalReference, accuracy: 0.001)
        XCTAssertEqual(fractional7004.timeIntervalSinceReferenceDate, utcFractionalReference, accuracy: 0.001)
    }

    // MARK: - Window definition + URL filters

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
        let qValues = (components.queryItems ?? [])
            .filter { $0.name == "q[]" }
            .compactMap(\.value)
        // Window is [reference - 7d, reference + 1d). The service
        // emits `q[]=starts_at:>=...` and `q[]=starts_at:<=...` rather
        // than the bare `from=` / `to=` of the pre-#129 endpoint.
        XCTAssertTrue(qValues.contains("starts_at:>=2026-04-18T12:00:00Z"),
                      "expected >= window edge in q[] values, got \(qValues)")
        XCTAssertTrue(qValues.contains("starts_at:<=2026-04-26T12:00:00Z"),
                      "expected <= window edge in q[] values, got \(qValues)")
    }

    /// Patient id moved into a q[] query value in #129; this test
    /// previously asserted on percent-encoded path segments. Now it
    /// verifies the encoding lands inside the q[]=patient_id:=...
    /// value-half so a tampered id can't introduce a sibling query
    /// parameter or otherwise smuggle filter syntax.
    func test_appointments_percentEncodesPatientIDInQueryValue() async throws {
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

        // Adversarial id with characters that would otherwise split
        // the URL — not realistic for Cliniko (numeric IDs) but
        // defence-in-depth.
        _ = try await service.recentAndTodayAppointments(
            forPatientID: "weird id/with/slashes",
            reference: Date()
        )

        let url = try XCTUnwrap(captured.value?.url)
        // Path is the static template; the id is in the query string.
        XCTAssertEqual(URLComponents(url: url, resolvingAgainstBaseURL: false)?.path,
                       "/v1/individual_appointments")
        // URL absoluteString is percent-encoded; the literal id must
        // appear as the value half of a single q[]=patient_id:=... item.
        // Per RFC 3986, `/` is permitted unencoded in query values
        // (only `?` and `#` terminate the query component), so
        // URLComponents leaves it as-is on every macOS version. The
        // safety property is that `=` and `&` ARE encoded, which is
        // what stops a tampered id from smuggling a sibling filter.
        let absolute = url.absoluteString
        XCTAssertTrue(absolute.contains("q%5B%5D=patient_id:%3Dweird%20id/with/slashes"),
                      "expected encoded id (space → %20, `/` left as-is per RFC 3986) in q[]=patient_id value, got: \(absolute)")
        // Critical: `=` and `&` from the input must be encoded so a
        // tampered id can't introduce a sibling query parameter.
        let captured2 = CapturedRequestBox()
        let service2 = try makeService { request in
            captured2.set(request)
            let body = try HTTPStubFixture.load("cliniko/responses/patient_appointments.json")
            let response = HTTPURLResponse(
                url: request.url ?? URL(string: "https://example.test")!,
                statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil
            )!
            return (response, body)
        }
        _ = try await service2.recentAndTodayAppointments(
            forPatientID: "id&extra=evil", reference: Date()
        )
        let evilURL = try XCTUnwrap(captured2.value?.url)
        XCTAssertTrue(evilURL.absoluteString.contains("id%26extra%3Devil"),
                      "expected `&` and `=` percent-encoded so a tampered id can't smuggle a sibling filter, got: \(evilURL.absoluteString)")
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

    func test_appointments_malformedJSON_mapsToDecoding() async throws {
        // 200 with a body that doesn't decode into ClinikoAppointmentListDTO.
        // Mirrors the patient-side test (`ClinikoPatientServiceTests.test_searchPatients_malformedJSON_mapsToDecoding`).
        // Synthetic body, no PHI.
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
            _ = try await service.recentAndTodayAppointments(
                forPatientID: "1001",
                reference: Date()
            )
            XCTFail("expected ClinikoError.decoding")
        } catch ClinikoError.decoding(let typeName) {
            XCTAssertTrue(
                typeName.contains("ClinikoAppointmentListDTO"),
                "typeName should identify the decoding target; got \(typeName)"
            )
        } catch {
            XCTFail("expected .decoding, got \(error)")
        }
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
