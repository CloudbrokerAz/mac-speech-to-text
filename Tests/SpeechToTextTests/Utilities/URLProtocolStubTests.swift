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

    // MARK: - Routed install (multi-endpoint)

    /// `HTTPURLResponse(url:statusCode:httpVersion:headerFields:)` returns nil
    /// only for malformed URLs; the URLs in this file are all hardcoded
    /// `https://...`. `try XCTUnwrap` keeps the styleguide's no-force-unwrap
    /// rule honoured and produces a descriptive failure if a future test
    /// passes a degenerate URL.
    private func makeHTTPResponse(
        url: URL,
        statusCode: Int = 200,
        httpVersion: String? = "HTTP/1.1",
        headerFields: [String: String]? = nil
    ) throws -> HTTPURLResponse {
        try XCTUnwrap(
            HTTPURLResponse(
                url: url,
                statusCode: statusCode,
                httpVersion: httpVersion,
                headerFields: headerFields
            ),
            "HTTPURLResponse init returned nil for url=\(url)"
        )
    }

    /// Exemplar for `URLProtocolStub.install(routes:)`. Two endpoints stubbed
    /// in one install call; each request is routed to the first matching
    /// `Route`. New tests that exercise more than one Cliniko endpoint at
    /// once should follow this shape rather than building a `switch
    /// request.url?.path { … }` inside a single closure. Uses the
    /// `Route.path(_:method:respond:)` convenience builder.
    func test_routes_dispatchToFirstMatchingEndpoint() async throws {
        let usersMeURL = try XCTUnwrap(URL(string: "https://api.au1.cliniko.com/v1/users/me"))
        let patientsURL = try XCTUnwrap(URL(string: "https://api.au1.cliniko.com/v1/patients?q=sample"))

        let config = URLProtocolStub.install(routes: [
            .path("/v1/users/me", respond: { request in
                let response = try XCTUnwrap(HTTPURLResponse(
                    url: request.url ?? usersMeURL,
                    statusCode: 200,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Type": "application/json"]
                ))
                let body = try HTTPStubFixture.load("cliniko/responses/users_me.json")
                return (response, body)
            }),
            .path("/v1/patients", respond: { request in
                let response = try XCTUnwrap(HTTPURLResponse(
                    url: request.url ?? patientsURL,
                    statusCode: 200,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Type": "application/json"]
                ))
                let body = try HTTPStubFixture.load("cliniko/responses/patients_search.json")
                return (response, body)
            })
        ])
        let session = URLSession(configuration: config)

        let (usersData, _) = try await session.data(from: usersMeURL)
        struct UserMe: Decodable { let id: Int }
        let user = try JSONDecoder().decode(UserMe.self, from: usersData)
        XCTAssertEqual(user.id, 12345)

        let (patientsData, _) = try await session.data(from: patientsURL)
        // Just verify the body matches the patients fixture; full decoding
        // belongs in the patient-service tests, not the stub exemplar.
        let expected = try HTTPStubFixture.load("cliniko/responses/patients_search.json")
        XCTAssertEqual(patientsData, expected)
    }

    func test_routes_methodMismatch_doesNotMatch() async throws {
        // `Route.path` defaults to GET — a POST to the same path must miss.
        let fallback = try XCTUnwrap(URL(string: "https://example.test"))
        let config = URLProtocolStub.install(routes: [
            .path("/v1/users/me", respond: { request in
                let response = try XCTUnwrap(HTTPURLResponse(
                    url: request.url ?? fallback,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                ))
                return (response, Data())
            })
        ])
        let session = URLSession(configuration: config)

        let postURL = try XCTUnwrap(URL(string: "https://example.test/v1/users/me"))
        var post = URLRequest(url: postURL)
        post.httpMethod = "POST"

        do {
            _ = try await session.data(for: post)
            XCTFail("POST should not match a GET-only route")
        } catch {
            let nsError = error as NSError
            XCTAssertTrue(
                nsError.localizedDescription.contains("no Route matched"),
                "expected 'no Route matched' for method mismatch; got \(nsError.localizedDescription)"
            )
        }
    }

    func test_routes_unmatchedRequest_throwsDescriptiveURLError() async throws {
        let fallback = try XCTUnwrap(URL(string: "https://example.test"))
        let config = URLProtocolStub.install(routes: [
            .path("/v1/users/me", respond: { request in
                let response = try XCTUnwrap(HTTPURLResponse(
                    url: request.url ?? fallback,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                ))
                return (response, Data())
            })
        ])
        let session = URLSession(configuration: config)

        let unmatched = try XCTUnwrap(URL(string: "https://api.au1.cliniko.com/v1/patients"))

        do {
            _ = try await session.data(from: unmatched)
            XCTFail("expected unmatched route to throw")
        } catch {
            // The thrown URLError is bridged to NSError before reaching the
            // session boundary; the descriptive message lives on
            // localizedDescription. Asserting both substrings (structural
            // marker AND the URL path) so a regression that drops either
            // piece is caught. Note: only the path is interpolated into the
            // error — full URLs can carry PHI in real Cliniko traffic, so
            // the no-match message is path-only by design (#30 review).
            let nsError = error as NSError
            let message = nsError.localizedDescription
            XCTAssertTrue(
                message.contains("no Route matched") && message.contains("/v1/patients"),
                "expected descriptive message containing 'no Route matched' and '/v1/patients'; got \(message)"
            )
        }
    }

    // MARK: - RAII (`installScoped`)

    /// Exemplar for `URLProtocolStub.installScoped(_:)`. The returned handle's
    /// `deinit` calls `reset()` (token-gated) when the handle goes out of
    /// scope. We delegate to a separate async helper so the handle's lifetime
    /// ends deterministically at the helper's return — `do { let x = … }`
    /// blocks do NOT guarantee ARC release at the closing brace, so the
    /// helper-function form is the reliable shape.
    func test_installScoped_resetsOnHandleDeinit() async throws {
        let probeURL = try XCTUnwrap(URL(string: "https://example.test/"))
        let request = URLRequest(url: probeURL)

        try await runWithScopedInstallation(probeRequest: request)

        // The helper has returned, its `installation` local has been released,
        // deinit ran, the token-gated reset cleared the responder.
        XCTAssertFalse(
            URLProtocolStub.canInit(with: request),
            "Installation deinit must call URLProtocolStub.reset()"
        )
    }

    private func runWithScopedInstallation(probeRequest: URLRequest) async throws {
        let fallback = try XCTUnwrap(URL(string: "https://example.test"))
        let installation = URLProtocolStub.installScoped { request in
            let response = try XCTUnwrap(HTTPURLResponse(
                url: request.url ?? fallback,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            ))
            return (response, Data())
        }

        // Stub is live while the handle is in scope.
        XCTAssertTrue(URLProtocolStub.canInit(with: probeRequest))

        let dataURL = try XCTUnwrap(URL(string: "https://example.test/"))
        let session = URLSession(configuration: installation.configuration)
        let (_, response) = try await session.data(from: dataURL)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
    }

    /// Stale `Installation` deinit must NOT clobber a newer installation that
    /// has already taken over the responder. The token-gating in
    /// `Installation.deinit` is what makes `installScoped` safe even if a
    /// caller accidentally keeps an old handle alive past the install of the
    /// next one (e.g. captured in a Task).
    func test_installScoped_staleHandleDeinit_doesNotClobberNewerInstall() throws {
        let probeURL = try XCTUnwrap(URL(string: "https://example.test/"))
        let probe = URLRequest(url: probeURL)
        let responseURL = try XCTUnwrap(URL(string: "https://example.test"))

        let firstResponse = try makeHTTPResponse(url: responseURL, statusCode: 200, httpVersion: nil)
        let secondResponse = try makeHTTPResponse(url: responseURL, statusCode: 201, httpVersion: nil)

        var firstHandle: URLProtocolStub.Installation? = URLProtocolStub.installScoped { _ in
            (firstResponse, Data())
        }
        XCTAssertNotNil(firstHandle)

        // A second `installScoped` takes over (different token).
        let secondHandle = URLProtocolStub.installScoped { _ in
            (secondResponse, Data())
        }

        // Drop the first handle — its deinit's reset is token-gated, so it
        // should observe a token mismatch and no-op rather than clearing
        // the second handle's responder.
        firstHandle = nil

        XCTAssertTrue(
            URLProtocolStub.canInit(with: probe),
            "Stale Installation.deinit must not reset a newer installation's responder"
        )

        // Touch the second handle so the optimizer cannot pre-deinit it.
        _ = secondHandle.configuration
    }
}
