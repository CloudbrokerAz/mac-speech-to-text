import XCTest

/// Exemplar tests for the `URLProtocolStub` + `HTTPStubFixture` helpers. Patterns shown
/// here are the reference implementation for the upcoming Cliniko client (#8) and any
/// other network-client tests.
final class URLProtocolStubTests: XCTestCase {
    override func tearDown() {
        URLProtocolStub.reset()
        super.tearDown()
    }

    func test_installedStub_returnsFixtureResponse() async throws {
        let config = URLProtocolStub.install { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            let body = try HTTPStubFixture.load("cliniko/responses/users_me.json")
            return (response, body)
        }
        let session = URLSession(configuration: config)

        let url = URL(string: "https://api.au1.cliniko.com/v1/users/me")!
        let (data, response) = try await session.data(from: url)

        let http = try XCTUnwrap(response as? HTTPURLResponse)
        XCTAssertEqual(http.statusCode, 200)
        XCTAssertEqual(http.value(forHTTPHeaderField: "Content-Type"), "application/json")

        struct UserMe: Decodable {
            let id: Int
            let email: String
        }
        let decoded = try JSONDecoder().decode(UserMe.self, from: data)
        XCTAssertEqual(decoded.id, 12345)
        XCTAssertEqual(decoded.email, "sample.user@example.test")
    }

    func test_responderError_surfacesToCaller() async {
        // URLProtocol wraps a thrown non-URLError as an NSError whose domain is the
        // Swift type name of the error. URLSession re-throws that NSError. We only
        // need to assert that the call failed, not pin down the wrapper shape.
        struct BoomError: Error {}

        let config = URLProtocolStub.install { _ in throw BoomError() }
        let session = URLSession(configuration: config)

        do {
            _ = try await session.data(from: URL(string: "https://example.test/")!)
            XCTFail("expected the responder's error to surface")
        } catch {
            // Any error is acceptable — the critical behaviour is that URLSession
            // did not silently succeed when the responder refused to respond.
            XCTAssertNotNil(error)
        }
    }

    func test_reset_clearsInterception() {
        _ = URLProtocolStub.install { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, Data())
        }
        URLProtocolStub.reset()

        let request = URLRequest(url: URL(string: "https://example.test/")!)
        XCTAssertFalse(URLProtocolStub.canInit(with: request),
                       "canInit must return false after reset()")
    }

    func test_fixtureNotFound_throwsNotFoundError() {
        XCTAssertThrowsError(try HTTPStubFixture.load("cliniko/responses/does_not_exist.json")) { error in
            guard let fixtureError = error as? HTTPStubFixture.FixtureError,
                  case .notFound = fixtureError else {
                XCTFail("expected .notFound error, got \(error)")
                return
            }
        }
    }

    func test_loadJSON_decodesTypedModel() throws {
        struct UserMe: Decodable, Equatable {
            let id: Int
            let firstName: String
            let lastName: String
            let email: String

            enum CodingKeys: String, CodingKey {
                case id
                case firstName = "first_name"
                case lastName = "last_name"
                case email
            }
        }

        let decoded = try HTTPStubFixture.loadJSON(UserMe.self, "cliniko/responses/users_me.json")
        XCTAssertEqual(decoded, UserMe(
            id: 12345,
            firstName: "Sample",
            lastName: "User",
            email: "sample.user@example.test"
        ))
    }
}
