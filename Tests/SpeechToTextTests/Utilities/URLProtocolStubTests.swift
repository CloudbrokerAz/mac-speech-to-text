import XCTest

/// Exemplar tests for the `URLProtocolStub` + `HTTPStubFixture` helpers.
/// Patterns shown here are the reference implementation for future
/// network-client tests.
final class URLProtocolStubTests: XCTestCase {
    override func tearDown() {
        URLProtocolStub.reset()
        super.tearDown()
    }

    // MARK: - Happy path

    func test_installedStub_returnsFixtureResponse() async throws {
        let config = URLProtocolStub.install { request in
            guard let url = request.url else { throw URLError(.badURL) }
            let response = HTTPURLResponse(
                url: url,
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

    // MARK: - Error surfacing

    func test_responderError_surfacesToCaller_asNetworkLayerFailure() async {
        // URLProtocol wraps a thrown non-URLError as an NSError whose domain
        // is the Swift type name of the error. URLSession re-throws that.
        // Assert the error originated at the URLSession boundary — i.e. we
        // did NOT slip past with successful data that then fails to decode
        // downstream.
        struct BoomError: Error {}

        let config = URLProtocolStub.install { _ in throw BoomError() }
        let session = URLSession(configuration: config)

        do {
            _ = try await session.data(from: URL(string: "https://example.test/")!)
            XCTFail("expected the responder's error to surface")
        } catch {
            // A regression that lets data past silently would throw a
            // DecodingError later — assert we didn't get there.
            XCTAssertFalse(error is DecodingError, "URLSession should fail, not succeed with junk data")

            // NSError-bridged form carries the thrown type's name in the
            // domain. That's implementation detail but gives us a signal
            // that the failure carried info from the responder rather than
            // being a spurious cancellation / timeout.
            let nsError = error as NSError
            XCTAssertTrue(
                nsError.domain.contains("BoomError") || (error is URLError),
                "expected failure to reference the responder's error; got domain=\(nsError.domain) err=\(error)"
            )
        }
    }

    func test_reset_clearsInterception() {
        _ = URLProtocolStub.install { request in
            guard let url = request.url else { throw URLError(.badURL) }
            let response = HTTPURLResponse(
                url: url,
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

    // MARK: - Fixture loading (not-found + edge cases)

    func test_fixtureNotFound_throwsNotFoundError() {
        XCTAssertThrowsError(try HTTPStubFixture.load("cliniko/responses/does_not_exist.json")) { error in
            guard let fixtureError = error as? HTTPStubFixture.FixtureError,
                  case .notFound = fixtureError else {
                XCTFail("expected .notFound error, got \(error)")
                return
            }
        }
    }

    func test_fixtureEmptyPath_throwsNotFoundError() {
        XCTAssertThrowsError(try HTTPStubFixture.load("")) { error in
            guard let fixtureError = error as? HTTPStubFixture.FixtureError,
                  case .notFound = fixtureError else {
                XCTFail("expected .notFound for empty path, got \(error)")
                return
            }
        }
    }

    func test_fixtureTrailingSlashPath_throwsNotFoundError() {
        // A path that resolves to no filename component should fail loudly
        // rather than silently look for an empty filename.
        XCTAssertThrowsError(try HTTPStubFixture.load("cliniko/responses/")) { error in
            guard let fixtureError = error as? HTTPStubFixture.FixtureError,
                  case .notFound = fixtureError else {
                XCTFail("expected .notFound for trailing-slash path, got \(error)")
                return
            }
        }
    }

    // MARK: - Typed JSON decode

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

    func test_loadJSON_wrongCodableShape_throwsDecodingError() {
        // Mismatch between fixture shape and the decoded type should surface
        // as DecodingError, not a silent zero-value or crash.
        struct WrongShape: Decodable {
            let not_a_real_field: [String]
        }

        XCTAssertThrowsError(
            try HTTPStubFixture.loadJSON(WrongShape.self, "cliniko/responses/users_me.json")
        ) { error in
            XCTAssertTrue(error is DecodingError,
                          "expected DecodingError, got \(type(of: error)): \(error)")
        }
    }

    // MARK: - FixtureError Equatable (quick sanity)

    func test_fixtureError_equatable_onPath() {
        let a = HTTPStubFixture.FixtureError.notFound(path: "x")
        let b = HTTPStubFixture.FixtureError.notFound(path: "x")
        let c = HTTPStubFixture.FixtureError.notFound(path: "y")
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
    }
}
