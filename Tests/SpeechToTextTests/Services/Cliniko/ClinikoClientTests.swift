import Foundation
import XCTest
@testable import SpeechToText

/// End-to-end tests for `ClinikoClient` against `URLProtocolStub`. Exercises
/// header construction, retry policy, status mapping, body redaction, and
/// the createTreatmentNote no-retry contract from `.claude/references/cliniko-api.md`.
final class ClinikoClientTests: XCTestCase {

    override func tearDown() {
        URLProtocolStub.reset()
        super.tearDown()
    }

    // MARK: - Helpers

    private var credentials: ClinikoCredentials {
        // swiftlint:disable:next force_try
        try! ClinikoCredentials(apiKey: "MS-test-au1", shard: .au1)
    }

    private func makeSession(responder: @escaping URLProtocolStub.Responder) -> URLSession {
        let config = URLProtocolStub.install(responder)
        return URLSession(configuration: config)
    }

    private func makeClient(
        session: URLSession,
        retryPolicy: ClinikoClient.RetryPolicy = .immediate
    ) -> ClinikoClient {
        ClinikoClient(
            credentials: credentials,
            session: session,
            userAgent: "client-tests/1.0",
            retryPolicy: retryPolicy
        )
    }

    private struct UsersMeResponse: Decodable, Sendable, Equatable {
        let id: Int
        let firstName: String
        let lastName: String
        let email: String
    }

    // MARK: - Headers + happy path

    func test_send_usersMe_sendsAuthUserAgentAcceptHeaders_andDecodesBody() async throws {
        let captured = CapturedRequest()
        let session = makeSession { request in
            captured.set(request)
            let body = try HTTPStubFixture.load("cliniko/responses/users_me.json")
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, body)
        }
        let client = makeClient(session: session)

        let user: UsersMeResponse = try await client.send(.usersMe)

        XCTAssertEqual(user, UsersMeResponse(
            id: 12345,
            firstName: "Sample",
            lastName: "User",
            email: "sample.user@example.test"
        ))
        let request = try XCTUnwrap(captured.value)
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.url?.absoluteString, "https://api.au1.cliniko.com/v1/users/me")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
        XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), "client-tests/1.0")
        let auth = try XCTUnwrap(request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertTrue(auth.hasPrefix("Basic "))
        let decoded = try XCTUnwrap(Data(base64Encoded: String(auth.dropFirst("Basic ".count)))
            .flatMap { String(data: $0, encoding: .utf8) })
        XCTAssertEqual(decoded, "MS-test-au1:")
    }

    func test_send_emptyResponseMarker_succeedsOn204() async throws {
        let session = makeSession { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 204,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, Data())
        }
        let client = makeClient(session: session)
        let _: EmptyResponse = try await client.send(.usersMe)
    }

    // MARK: - sendWithStatus surfaces the actual 2xx code

    /// Issue #58 — pin that `sendWithStatus(_:)` returns the observed HTTP
    /// status alongside the decoded body. Today the audit ledger row is the
    /// only consumer, but the contract belongs on the client itself: any
    /// 2xx is success, and the *specific* 2xx code must reach the caller
    /// rather than being smashed to a documented constant.
    func test_sendWithStatus_returnsActualStatusFromResponse() async throws {
        let session = makeSession { request in
            let body = try HTTPStubFixture.load("cliniko/responses/users_me.json")
            // 200 (not 201/202) — the documented status for /users/me.
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, body)
        }
        let client = makeClient(session: session)

        let (user, status): (UsersMeResponse, Int) = try await client.sendWithStatus(.usersMe)

        XCTAssertEqual(status, 200)
        XCTAssertEqual(user.id, 12345)
    }

    /// Pin the 201 path too so the exporter's audit row always reflects the
    /// real status — would catch a regression that hardcoded `200` somewhere
    /// in the success path.
    func test_sendWithStatus_returns201WhenServerReturns201() async throws {
        let session = makeSession { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 201,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, Data("{\"id\":42}".utf8))
        }
        let client = makeClient(session: session)

        struct CreatedID: Decodable, Sendable, Equatable { let id: Int }
        let (created, status): (CreatedID, Int) = try await client.sendWithStatus(
            .createTreatmentNote(body: Data("{}".utf8))
        )

        XCTAssertEqual(status, 201)
        XCTAssertEqual(created.id, 42)
    }

    /// `send(_:)` is now a thin forwarder over `sendWithStatus(_:)`. Pin
    /// that it still drops the status cleanly — call sites that opt out of
    /// the tuple shouldn't get a different value than they did before.
    func test_send_stillDecodesBody_whenCallerIgnoresStatus() async throws {
        let session = makeSession { request in
            let body = try HTTPStubFixture.load("cliniko/responses/users_me.json")
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, body)
        }
        let client = makeClient(session: session)
        let user: UsersMeResponse = try await client.send(.usersMe)
        XCTAssertEqual(user.id, 12345)
    }

    // MARK: - Status mapping

    func test_send_401_mapsToUnauthenticated() async {
        await assertSend(returnsStatus: 401, throws: .unauthenticated)
    }

    func test_send_403_mapsToForbidden() async {
        await assertSend(returnsStatus: 403, throws: .forbidden)
    }

    func test_send_404_mapsToNotFound_withEndpointResource() async {
        await assertSend(
            endpoint: .patientSearch(query: "x"),
            returnsStatus: 404,
            throws: .notFound(resource: .patient)
        )
    }

    func test_send_422_parsesValidationFields_dictShape() async throws {
        let body = Data(#"{"errors":{"name":["must be present"],"age":["must be a number"]}}"#.utf8)
        let session = makeSession { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 422, httpVersion: nil, headerFields: nil)!
            return (response, body)
        }
        let client = makeClient(session: session)
        do {
            let _: UsersMeResponse = try await client.send(.usersMe)
            XCTFail("expected validation error")
        } catch let ClinikoError.validation(fields) {
            XCTAssertEqual(fields["name"], ["must be present"])
            XCTAssertEqual(fields["age"], ["must be a number"])
        } catch {
            XCTFail("expected .validation; got \(error)")
        }
    }

    func test_send_422_parsesValidationFields_listShape() async throws {
        let body = Data(#"""
{"errors":[{"field":"email","message":"is invalid"},{"field":"email","message":"is too short"}]}
"""#.utf8)
        let session = makeSession { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 422, httpVersion: nil, headerFields: nil)!
            return (response, body)
        }
        let client = makeClient(session: session)
        do {
            let _: UsersMeResponse = try await client.send(.usersMe)
            XCTFail("expected validation error")
        } catch let ClinikoError.validation(fields) {
            XCTAssertEqual(fields["email"]?.sorted(), ["is invalid", "is too short"])
        } catch {
            XCTFail("expected .validation; got \(error)")
        }
    }

    func test_send_500_mapsToServer_afterRetries() async {
        await assertSend(returnsStatus: 500, throws: .server(status: 500))
    }

    func test_send_unclassified_3xx_mapsToServer() async {
        // 301 / 302 / etc. are unclassified — surface as `.server(status:)`
        // rather than swallowing.
        await assertSend(returnsStatus: 301, throws: .server(status: 301))
    }

    private func assertSend(
        endpoint: ClinikoEndpoint = .usersMe,
        returnsStatus statusCode: Int,
        throws expected: ClinikoError,
        file: StaticString = #file,
        line: UInt = #line
    ) async {
        let session = makeSession { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: statusCode,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, Data("{}".utf8))
        }
        let client = makeClient(session: session)
        do {
            let _: UsersMeResponse = try await client.send(endpoint)
            XCTFail("expected \(expected) for status \(statusCode)", file: file, line: line)
        } catch let error as ClinikoError {
            XCTAssertEqual(error, expected, file: file, line: line)
        } catch {
            XCTFail("unexpected error type \(type(of: error)): \(error)", file: file, line: line)
        }
    }

    // MARK: - Retry policy

    func test_send_5xx_retries_onIdempotentEndpoint_thenRecovers() async throws {
        let counter = CallCounter()
        let session = makeSession { request in
            let attempt = counter.increment()
            if attempt < 3 {
                let response = HTTPURLResponse(url: request.url!, statusCode: 503, httpVersion: nil, headerFields: nil)!
                return (response, Data())
            }
            let body = try HTTPStubFixture.load("cliniko/responses/users_me.json")
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, body)
        }
        let client = makeClient(session: session)
        let _: UsersMeResponse = try await client.send(.usersMe)
        XCTAssertEqual(counter.value, 3, "expected initial attempt + 2 retries before success")
    }

    func test_send_5xx_exhausts_retryBudget() async {
        let counter = CallCounter()
        let session = makeSession { request in
            _ = counter.increment()
            let response = HTTPURLResponse(url: request.url!, statusCode: 502, httpVersion: nil, headerFields: nil)!
            return (response, Data())
        }
        let client = makeClient(session: session)
        do {
            let _: UsersMeResponse = try await client.send(.usersMe)
            XCTFail("expected .server")
        } catch ClinikoError.server(let status) {
            XCTAssertEqual(status, 502)
            XCTAssertEqual(counter.value, 3, "expected initial attempt + 2 retries (max budget)")
        } catch {
            XCTFail("expected .server, got \(error)")
        }
    }

    func test_send_5xx_doesNotRetry_onCreateTreatmentNote() async {
        let counter = CallCounter()
        let session = makeSession { request in
            _ = counter.increment()
            let response = HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!
            return (response, Data())
        }
        let client = makeClient(session: session)
        do {
            let _: EmptyResponse = try await client.send(.createTreatmentNote(body: Data("{}".utf8)))
            XCTFail("expected .server")
        } catch ClinikoError.server(let status) {
            XCTAssertEqual(status, 500)
            XCTAssertEqual(counter.value, 1,
                           "POST treatment_notes must not retry on 5xx — duplicate-write guard")
        } catch {
            XCTFail("expected .server, got \(error)")
        }
    }

    func test_send_429_honoursRetryAfter_aboveFloor_thenSucceeds() async throws {
        // Retry-After (5s) is *above* the policy floor (0.1s), so it wins —
        // the server is asking us to wait longer than we'd planned to and
        // we honour that. (The reverse — server asking for *less* time than
        // policy floor — is covered by `test_send_429_zeroRetryAfter_isClampedToPolicyFloor`.)
        let counter = CallCounter()
        let captured = CapturedRetryAfter()
        let session = makeSession { request in
            let attempt = counter.increment()
            if attempt == 1 {
                let response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 429,
                    httpVersion: nil,
                    headerFields: ["Retry-After": "5"]
                )!
                return (response, Data())
            }
            let body = try HTTPStubFixture.load("cliniko/responses/users_me.json")
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, body)
        }
        let client = ClinikoClient(
            credentials: credentials,
            session: session,
            userAgent: "client-tests/1.0",
            retryPolicy: ClinikoClient.RetryPolicy(
                delays: [0.1, 0.1],
                sleep: { interval in captured.record(interval) }
            )
        )
        let _: UsersMeResponse = try await client.send(.usersMe)
        XCTAssertEqual(counter.value, 2, "1 retry on 429")
        XCTAssertEqual(captured.values, [5.0],
                       "Retry-After header value (above policy floor) must override the policy delay")
    }

    func test_send_429_retriesEvenWhenAllowsRetryOn5xxIsFalse() async throws {
        // POST treatment_notes does not auto-retry on 5xx but DOES retry on
        // 429 per cliniko-api.md ("UI shows a countdown").
        let counter = CallCounter()
        let session = makeSession { request in
            let attempt = counter.increment()
            if attempt == 1 {
                let response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 429,
                    httpVersion: nil,
                    headerFields: ["Retry-After": "1"]
                )!
                return (response, Data())
            }
            let response = HTTPURLResponse(url: request.url!, statusCode: 201, httpVersion: nil, headerFields: nil)!
            return (response, Data())
        }
        let client = makeClient(session: session)
        let _: EmptyResponse = try await client.send(.createTreatmentNote(body: Data("{}".utf8)))
        XCTAssertEqual(counter.value, 2)
    }

    func test_send_429_exhaustsBudget_throwsRateLimited() async {
        let counter = CallCounter()
        let session = makeSession { request in
            _ = counter.increment()
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 429,
                httpVersion: nil,
                headerFields: ["Retry-After": "0"]
            )!
            return (response, Data())
        }
        let client = makeClient(session: session)
        do {
            let _: UsersMeResponse = try await client.send(.usersMe)
            XCTFail("expected .rateLimited")
        } catch ClinikoError.rateLimited(let retryAfter) {
            XCTAssertEqual(retryAfter, 0)
            XCTAssertEqual(counter.value, 3, "1 + 2 retries = 3 total attempts")
        } catch {
            XCTFail("expected .rateLimited, got \(error)")
        }
    }

    // MARK: - Transport + cancellation

    func test_send_transportError_retriesOnIdempotent_thenSurfacesAfterBudget() async {
        let counter = CallCounter()
        let session = makeSession { _ in
            _ = counter.increment()
            throw URLError(.notConnectedToInternet)
        }
        let client = makeClient(session: session)
        do {
            let _: UsersMeResponse = try await client.send(.usersMe)
            XCTFail("expected .transport")
        } catch ClinikoError.transport(let code) {
            XCTAssertEqual(code, .notConnectedToInternet)
            XCTAssertEqual(counter.value, 3)
        } catch {
            XCTFail("got \(error)")
        }
    }

    func test_send_transportError_doesNotRetryOnCreateTreatmentNote() async {
        let counter = CallCounter()
        let session = makeSession { _ in
            _ = counter.increment()
            throw URLError(.notConnectedToInternet)
        }
        let client = makeClient(session: session)
        do {
            let _: EmptyResponse = try await client.send(.createTreatmentNote(body: Data("{}".utf8)))
            XCTFail("expected .transport")
        } catch ClinikoError.transport {
            XCTAssertEqual(counter.value, 1, "POST treatment_notes must not retry on transport errors")
        } catch {
            XCTFail("got \(error)")
        }
    }

    func test_send_urlErrorCancelled_mapsToCancelled() async {
        let session = makeSession { _ in
            throw URLError(.cancelled)
        }
        let client = makeClient(session: session)
        do {
            let _: UsersMeResponse = try await client.send(.usersMe)
            XCTFail("expected .cancelled")
        } catch ClinikoError.cancelled {
            // expected
        } catch {
            XCTFail("got \(error)")
        }
    }

    // MARK: - Retry-After (HTTP-date form)

    func test_send_429_honoursHTTPDateRetryAfter_thenSucceeds() async throws {
        let counter = CallCounter()
        let captured = CapturedRetryAfter()
        let session = makeSession { request in
            let attempt = counter.increment()
            if attempt == 1 {
                // 30 seconds in the future from "now".
                let future = Date().addingTimeInterval(30)
                let formatter = DateFormatter()
                formatter.locale = Locale(identifier: "en_US_POSIX")
                formatter.timeZone = TimeZone(identifier: "GMT")
                formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
                let dateString = formatter.string(from: future)
                let response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 429,
                    httpVersion: nil,
                    headerFields: ["Retry-After": dateString]
                )!
                return (response, Data())
            }
            let body = try HTTPStubFixture.load("cliniko/responses/users_me.json")
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, body)
        }
        let client = ClinikoClient(
            credentials: credentials,
            session: session,
            userAgent: "client-tests/1.0",
            retryPolicy: ClinikoClient.RetryPolicy(
                delays: [0.1, 0.1],
                sleep: { interval in captured.record(interval) }
            )
        )
        let _: UsersMeResponse = try await client.send(.usersMe)
        XCTAssertEqual(counter.value, 2)
        let firstDelay = try XCTUnwrap(captured.values.first)
        // Date-form parses; the floor is the policy delay (0.1) so the
        // honoured value is whichever is larger. Should be ~30s, not 0.1.
        XCTAssertGreaterThan(firstDelay, 5.0,
                             "HTTP-date Retry-After must produce a forward-looking interval")
    }

    func test_send_429_zeroRetryAfter_isClampedToPolicyFloor() async throws {
        // `Retry-After: 0` from a misbehaving server must NOT cause
        // back-to-back hammering — clamp to the policy delay.
        let counter = CallCounter()
        let captured = CapturedRetryAfter()
        let session = makeSession { request in
            let attempt = counter.increment()
            if attempt == 1 {
                let response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 429,
                    httpVersion: nil,
                    headerFields: ["Retry-After": "0"]
                )!
                return (response, Data())
            }
            let body = try HTTPStubFixture.load("cliniko/responses/users_me.json")
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, body)
        }
        let client = ClinikoClient(
            credentials: credentials,
            session: session,
            userAgent: "client-tests/1.0",
            retryPolicy: ClinikoClient.RetryPolicy(
                delays: [2.0, 2.0],
                sleep: { interval in captured.record(interval) }
            )
        )
        let _: UsersMeResponse = try await client.send(.usersMe)
        XCTAssertEqual(captured.values, [2.0],
                       "Retry-After: 0 must be clamped up to the policy floor (2.0)")
    }

    // MARK: - Empty retry policy

    func test_send_emptyRetryDelays_terminatesOnFirstFailure() async {
        let counter = CallCounter()
        let session = makeSession { request in
            _ = counter.increment()
            let response = HTTPURLResponse(url: request.url!, statusCode: 503, httpVersion: nil, headerFields: nil)!
            return (response, Data())
        }
        let client = ClinikoClient(
            credentials: credentials,
            session: session,
            userAgent: "client-tests/1.0",
            retryPolicy: ClinikoClient.RetryPolicy(delays: [], sleep: { _ in })
        )
        do {
            let _: EmptyResponse = try await client.send(.usersMe)
            XCTFail("expected .server")
        } catch ClinikoError.server(let status) {
            XCTAssertEqual(status, 503)
            XCTAssertEqual(counter.value, 1, "empty delays → no retries")
        } catch {
            XCTFail("got \(error)")
        }
    }

    func test_send_unparseable422Body_returnsEmptyValidationFields() async {
        // Pin the documented behaviour: when both response shapes fail to
        // decode, surface an empty validation dict rather than crashing.
        // (The implementation also logs a structural marker so we'd notice
        // a third undocumented shape in production.)
        let session = makeSession { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 422, httpVersion: nil, headerFields: nil)!
            return (response, Data("plain text".utf8))
        }
        let client = makeClient(session: session)
        do {
            let _: UsersMeResponse = try await client.send(.usersMe)
            XCTFail("expected .validation")
        } catch ClinikoError.validation(let fields) {
            XCTAssertTrue(fields.isEmpty)
        } catch {
            XCTFail("got \(error)")
        }
    }

    // MARK: - Decoding

    func test_send_2xxButMalformedBody_throwsDecoding() async {
        let session = makeSession { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Data("not json".utf8))
        }
        let client = makeClient(session: session)
        do {
            let _: UsersMeResponse = try await client.send(.usersMe)
            XCTFail("expected .decoding")
        } catch ClinikoError.decoding(let typeName) {
            XCTAssertTrue(typeName.contains("UsersMeResponse"), "got \(typeName)")
        } catch {
            XCTFail("got \(error)")
        }
    }

    // MARK: - Body wiring (POST)

    func test_send_createTreatmentNote_setsBodyAndContentType() async throws {
        let captured = CapturedRequest()
        let session = makeSession { request in
            captured.set(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: 201, httpVersion: nil, headerFields: nil)!
            return (response, Data())
        }
        let client = makeClient(session: session)
        let payload = Data(#"{"notes":"hello"}"#.utf8)
        let _: EmptyResponse = try await client.send(.createTreatmentNote(body: payload))

        let request = try XCTUnwrap(captured.value)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.absoluteString, "https://api.au1.cliniko.com/v1/treatment_notes")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        // URLProtocolStub strips httpBody (URLSession buffers it into
        // httpBodyStream); read either path.
        let bodyData: Data?
        if let direct = request.httpBody {
            bodyData = direct
        } else if let stream = request.httpBodyStream {
            bodyData = ClinikoClientTests.readAll(from: stream)
        } else {
            bodyData = nil
        }
        XCTAssertEqual(bodyData, payload)
    }

    private static func readAll(from stream: InputStream) -> Data {
        var data = Data()
        stream.open()
        defer { stream.close() }
        let bufferSize = 1024
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: bufferSize)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }
}

// MARK: - Test helpers

/// Counts how many times a URLProtocolStub responder is invoked.
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
private final class CapturedRequest: @unchecked Sendable {
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

/// Captures the sequence of `TimeInterval` values passed to a `RetryPolicy`'s
/// sleep closure — pins that we honour `Retry-After` instead of the policy
/// default.
private final class CapturedRetryAfter: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [TimeInterval] = []

    func record(_ value: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        stored.append(value)
    }

    var values: [TimeInterval] {
        lock.lock(); defer { lock.unlock() }
        return stored
    }
}
