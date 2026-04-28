import Foundation
import XCTest
@testable import SpeechToText

/// Tests `ClinikoAuthProbe` against a stubbed `URLSession` so no real network
/// call ever fires. Header assertions verify AC item 2 of issue #7
/// ("Test connection request includes User-Agent: mac-speech-to-text/<version>
/// and Basic auth per Cliniko docs").
final class ClinikoAuthProbeTests: XCTestCase {

    override func tearDown() {
        URLProtocolStub.reset()
        super.tearDown()
    }

    // MARK: - Helpers

    private func makeSession(
        responder: @escaping URLProtocolStub.Responder
    ) -> URLSession {
        let config = URLProtocolStub.install(responder)
        return URLSession(configuration: config)
    }

    private var credentials: ClinikoCredentials {
        // swiftlint:disable:next force_try
        try! ClinikoCredentials(apiKey: "MS-test-au1", shard: .au1)
    }

    // MARK: - Happy path + headers

    func test_ping_sends_basicAuth_userAgent_and_acceptHeaders() async throws {
        let captured = CapturedRequest()
        let session = makeSession { request in
            captured.set(request)
            let response = HTTPURLResponse(
                url: request.url ?? URL(string: "https://example.test")!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            let body = try HTTPStubFixture.load("cliniko/responses/user.json")
            return (response, body)
        }
        let probe = ClinikoAuthProbe(session: session, userAgent: "mac-speech-to-text/9.9.9 (test)")

        try await probe.ping(credentials: credentials)

        let unwrapped = try XCTUnwrap(captured.value)
        XCTAssertEqual(unwrapped.httpMethod, "GET")
        XCTAssertEqual(unwrapped.url?.absoluteString, "https://api.au1.cliniko.com/v1/user")
        XCTAssertEqual(unwrapped.value(forHTTPHeaderField: "Accept"), "application/json")
        XCTAssertEqual(unwrapped.value(forHTTPHeaderField: "User-Agent"), "mac-speech-to-text/9.9.9 (test)")

        let auth = try XCTUnwrap(unwrapped.value(forHTTPHeaderField: "Authorization"))
        XCTAssertTrue(auth.hasPrefix("Basic "), "expected HTTP Basic auth header, got \(auth)")
        let encoded = String(auth.dropFirst("Basic ".count))
        let decoded = try XCTUnwrap(Data(base64Encoded: encoded).flatMap { String(data: $0, encoding: .utf8) })
        XCTAssertEqual(decoded, "MS-test-au1:", "Cliniko Basic auth: API key as username + empty password")
    }

    func test_defaultUserAgent_includesAppNameAndContactReference() {
        // Pins the User-Agent shape required by `.claude/references/cliniko-api.md`:
        // app name + version + a contact reference (we use the public repo URL).
        let ua = ClinikoAuthProbe.defaultUserAgent
        XCTAssertTrue(ua.hasPrefix("mac-speech-to-text/"), "got \(ua)")
        XCTAssertTrue(ua.contains("github.com/CloudbrokerAz/mac-speech-to-text"),
                      "User-Agent must embed a contact reference; got \(ua)")
    }

    func test_ping_succeedsOn200() async throws {
        let session = makeSession { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, Data())
        }
        let probe = ClinikoAuthProbe(session: session)
        try await probe.ping(credentials: credentials)
    }

    // MARK: - Status mapping

    func test_ping_throwsUnauthorized_on401() async {
        await assertProbe(returnsStatus: 401, throws: .unauthorized)
    }

    func test_ping_throwsUnauthorized_on403() async {
        await assertProbe(returnsStatus: 403, throws: .unauthorized)
    }

    func test_ping_throwsHTTPStatus_on500() async {
        await assertProbe(returnsStatus: 500, throws: .http(status: 500))
    }

    func test_ping_throwsHTTPStatus_on404() async {
        await assertProbe(returnsStatus: 404, throws: .http(status: 404))
    }

    func test_ping_succeedsOnEdgeOfSuccessRange() async throws {
        // 204 (No Content) is the boundary case the `200..<300` arm must
        // accept; pin it explicitly so a future refactor doesn't narrow
        // the range to 200..<201 by accident.
        let session = makeSession { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 204,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, Data())
        }
        let probe = ClinikoAuthProbe(session: session)
        try await probe.ping(credentials: credentials)
    }

    private func assertProbe(
        returnsStatus statusCode: Int,
        throws expected: ClinikoAuthProbeError,
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
        let probe = ClinikoAuthProbe(session: session)
        do {
            try await probe.ping(credentials: credentials)
            XCTFail("expected \(expected) for HTTP \(statusCode)", file: file, line: line)
        } catch let error as ClinikoAuthProbeError {
            XCTAssertEqual(error, expected, file: file, line: line)
        } catch {
            XCTFail("unexpected error type \(type(of: error)): \(error)", file: file, line: line)
        }
    }

    // MARK: - Transport errors

    func test_ping_throwsTransport_onURLError() async {
        let session = makeSession { _ in
            throw URLError(.notConnectedToInternet)
        }
        let probe = ClinikoAuthProbe(session: session)
        do {
            try await probe.ping(credentials: credentials)
            XCTFail("expected transport error")
        } catch let error as ClinikoAuthProbeError {
            switch error {
            case .transport:
                break
            default:
                XCTFail("expected .transport, got \(error)")
            }
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    func test_ping_throwsCancelled_onURLErrorCancelled() async {
        let session = makeSession { _ in
            throw URLError(.cancelled)
        }
        let probe = ClinikoAuthProbe(session: session)
        do {
            try await probe.ping(credentials: credentials)
            XCTFail("expected cancelled error")
        } catch ClinikoAuthProbeError.cancelled {
            // Expected — URLSession-level cancellation must surface as
            // `.cancelled`, never as `.transport(.cancelled)`, so the VM
            // can render it as a no-op rather than a network failure.
        } catch {
            XCTFail("expected .cancelled, got \(error)")
        }
    }
}

// MARK: - Test helpers

/// Captures the request seen by the URLProtocolStub responder. The responder
/// is synchronous, so we use an `NSLock`-protected class — same pattern as
/// `URLProtocolStub` itself.
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
