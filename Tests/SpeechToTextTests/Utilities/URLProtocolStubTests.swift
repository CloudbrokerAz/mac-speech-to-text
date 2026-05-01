import XCTest

/// Exemplar tests for the `URLProtocolStub` + `HTTPStubFixture` helpers.
/// Patterns shown here are the reference implementation for future
/// network-client tests.
final class URLProtocolStubTests: XCTestCase {
    override func tearDown() {
        // No-op since #87 — `URLProtocolStub.reset()` is a documented no-op
        // because each `install(_:)` registers under its own token. The call
        // is left here so anyone copying this teardown shape from older code
        // sees that it's harmless rather than missing.
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
            let body = try HTTPStubFixture.load("cliniko/responses/user.json")
            return (response, body)
        }
        let session = URLSession(configuration: config)

        let url = try XCTUnwrap(URL(string: "https://api.au1.cliniko.com/v1/user"))
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

    // MARK: - reset() is a no-op (#87)

    /// `URLProtocolStub.reset()` is a documented no-op since #87 — the
    /// per-installation registry makes "clear the global slot" both unnecessary
    /// and unsafe (a parallel suite's `defer { reset() }` would have nuked
    /// another suite's responder mid-flight). This test pins that behaviour so
    /// a regression that re-introduces a global clear surfaces here, not as a
    /// flaky cross-suite race in CI.
    func test_reset_isNoOp_liveInstallationStillIntercepts() async throws {
        let config = URLProtocolStub.install { request in
            let response = try XCTUnwrap(HTTPURLResponse(
                url: request.url ?? URL(string: "https://example.test")!,
                statusCode: 204,
                httpVersion: "HTTP/1.1",
                headerFields: nil
            ))
            return (response, Data())
        }
        let session = URLSession(configuration: config)

        // Reset BEFORE the request fires — under pre-#87 semantics this would
        // null the responder slot and the request would 500 / fail.
        URLProtocolStub.reset()

        let url = try XCTUnwrap(URL(string: "https://example.test/probe"))
        let (_, response) = try await session.data(from: url)
        XCTAssertEqual(
            (response as? HTTPURLResponse)?.statusCode,
            204,
            "reset() must not affect a live installation; the per-installation registry"
                + " keeps each install's responder under its own token"
        )
    }

    /// A bare `URLRequest` with no `X-URLProtocolStub-Token` header must not be
    /// claimed by `URLProtocolStub.canInit(with:)`, even when other
    /// installations are alive in the registry. This is the property that lets
    /// arbitrary `URLSession.shared` traffic in the test process pass through
    /// untouched (only sessions built from `install()`'s configuration carry
    /// the dispatch token).
    func test_canInit_returnsFalseForRequestsWithoutToken() {
        // A live registry entry — its token is not on `request` below. Use
        // `withExtendedLifetime` rather than `defer { _ = installation }` —
        // the latter is not honoured by Release-mode ARC, which is free to
        // release `installation` immediately after the property read.
        let installation = URLProtocolStub.installScoped { _ in
            (HTTPURLResponse(), Data())
        }
        withExtendedLifetime(installation) {
            let request = URLRequest(url: URL(string: "https://example.test/")!)
            XCTAssertFalse(
                URLProtocolStub.canInit(with: request),
                "URLProtocolStub must only claim requests carrying its dispatch header,"
                    + " so untagged URLSession traffic in the test process is unaffected"
            )
        }
    }

    // MARK: - Cross-suite isolation regression (#87)

    /// The dispatch property at the heart of #87: two installations alive at
    /// the same time each carry their own token, and each request lands on
    /// the responder registered for *its* token regardless of which
    /// installation came second.
    ///
    /// Pre-#87 this would have failed deterministically: both installations
    /// shared a single global `currentResponder` slot, the second `install`
    /// always clobbered the first, and both sessions' requests would have
    /// landed on the second responder. The `async let` interleaves the
    /// requests for stress (and to mimic the real race shape) but the
    /// per-token dispatch is what the assertions actually pin.
    func test_concurrentInstallations_dispatchToOwnResponderOnly() async throws {
        let firstURL = try XCTUnwrap(URL(string: "https://first.test/probe"))
        let secondURL = try XCTUnwrap(URL(string: "https://second.test/probe"))

        let firstStub = URLProtocolStub.installScoped { request in
            let response = try XCTUnwrap(HTTPURLResponse(
                url: request.url ?? firstURL,
                statusCode: 201,
                httpVersion: "HTTP/1.1",
                headerFields: nil
            ))
            return (response, Data("FIRST".utf8))
        }
        let secondStub = URLProtocolStub.installScoped { request in
            let response = try XCTUnwrap(HTTPURLResponse(
                url: request.url ?? secondURL,
                statusCode: 202,
                httpVersion: "HTTP/1.1",
                headerFields: nil
            ))
            return (response, Data("SECOND".utf8))
        }
        let firstSession = URLSession(configuration: firstStub.configuration)
        let secondSession = URLSession(configuration: secondStub.configuration)

        // Interleave requests through both sessions concurrently. If the
        // installations shared a global responder slot, results would be
        // non-deterministic (whichever install ran most recently wins).
        async let firstResult: (Data, URLResponse) = firstSession.data(from: firstURL)
        async let secondResult: (Data, URLResponse) = secondSession.data(from: secondURL)
        let (firstData, firstResponse) = try await firstResult
        let (secondData, secondResponse) = try await secondResult

        XCTAssertEqual((firstResponse as? HTTPURLResponse)?.statusCode, 201)
        XCTAssertEqual(firstData, Data("FIRST".utf8))
        XCTAssertEqual((secondResponse as? HTTPURLResponse)?.statusCode, 202)
        XCTAssertEqual(secondData, Data("SECOND".utf8))
    }

    /// Companion to the concurrent-installations test. ARC-driven cleanup of
    /// one installation (here: the inner installation's deinit at function
    /// return) must not unregister another installation's responder — each
    /// `Installation.deinit` knows only its own token, so it can only ever
    /// remove its own slot from the registry. Pre-#87 the inner install
    /// would have *replaced* the outer's `currentResponder` and the inner's
    /// teardown would have left the outer's session pointing at nothing —
    /// the exact `sizeMismatch(expected: 4, got: 0)` failure mode.
    func test_droppingOneInstallation_doesNotAffectOther() async throws {
        // Outer installation alive for the whole test.
        let outerStub = URLProtocolStub.installScoped { request in
            let response = try XCTUnwrap(HTTPURLResponse(
                url: request.url ?? URL(string: "https://outer.test")!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: nil
            ))
            return (response, Data("outer-ok".utf8))
        }
        let outerSession = URLSession(configuration: outerStub.configuration)

        // Inner installation lives only for the duration of `runInner`. When
        // the function returns, ARC releases its `Installation` and the
        // responder slot is unregistered — but only its slot, not the outer's.
        try await runInner()

        // After the inner installation deinit'd, outer must still intercept.
        let url = try XCTUnwrap(URL(string: "https://outer.test/probe"))
        let (data, response) = try await outerSession.data(from: url)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual(data, Data("outer-ok".utf8))
    }

    private func runInner() async throws {
        let innerStub = URLProtocolStub.installScoped { request in
            let response = try XCTUnwrap(HTTPURLResponse(
                url: request.url ?? URL(string: "https://inner.test")!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: nil
            ))
            return (response, Data("inner-ok".utf8))
        }
        let innerSession = URLSession(configuration: innerStub.configuration)
        let url = try XCTUnwrap(URL(string: "https://inner.test/probe"))
        let (data, _) = try await innerSession.data(from: url)
        XCTAssertEqual(data, Data("inner-ok".utf8))
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

        let decoded = try HTTPStubFixture.loadJSON(UserMe.self, "cliniko/responses/user.json")
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
            try HTTPStubFixture.loadJSON(WrongShape.self, "cliniko/responses/user.json")
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
        let usersMeURL = try XCTUnwrap(URL(string: "https://api.au1.cliniko.com/v1/user"))
        let patientsURL = try XCTUnwrap(URL(string: "https://api.au1.cliniko.com/v1/patients?q=sample"))

        let config = URLProtocolStub.install(routes: [
            .path("/v1/user", respond: { request in
                let response = try XCTUnwrap(HTTPURLResponse(
                    url: request.url ?? usersMeURL,
                    statusCode: 200,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Type": "application/json"]
                ))
                let body = try HTTPStubFixture.load("cliniko/responses/user.json")
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
            .path("/v1/user", respond: { request in
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

        let postURL = try XCTUnwrap(URL(string: "https://example.test/v1/user"))
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
            .path("/v1/user", respond: { request in
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
    /// `deinit` removes its responder slot from the per-installation registry
    /// (not a global "currentResponder" — see #87). We verify by:
    ///   1. firing a request through the configuration's session while the
    ///      handle is alive — expect 200,
    ///   2. dropping the handle inside a helper so ARC actually releases it
    ///      at function return,
    ///   3. firing the same request again through the same (still-alive)
    ///      session — expect the loud "no responder" failure that proves the
    ///      registry slot was removed (rather than a silent network call).
    func test_installScoped_unregistersResponderOnHandleDeinit() async throws {
        let probeURL = try XCTUnwrap(URL(string: "https://example.test/probe"))

        // Helper builds + returns a session whose configuration was tagged
        // with an Installation that's released the moment the helper returns.
        let session = try await runWithScopedInstallationReturningSession(probeURL: probeURL)

        // Handle has deinit'd; the session still carries the dispatch header
        // but the registry slot is gone — startLoading() should surface the
        // descriptive "no responder" URLError.
        do {
            _ = try await session.data(from: probeURL)
            XCTFail("expected loud failure after Installation.deinit removed the responder slot")
        } catch {
            let nsError = error as NSError
            XCTAssertTrue(
                nsError.localizedDescription.contains("no responder registered for token"),
                "expected the descriptive URLError from URLProtocolStub.startLoading; got \(nsError.localizedDescription)"
            )
        }
    }

    private func runWithScopedInstallationReturningSession(probeURL: URL) async throws -> URLSession {
        let installation = URLProtocolStub.installScoped { request in
            let response = try XCTUnwrap(HTTPURLResponse(
                url: request.url ?? probeURL,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: nil
            ))
            return (response, Data())
        }
        let session = URLSession(configuration: installation.configuration)

        // Fire one successful request to prove the responder is wired up
        // before the handle deinits.
        let (_, response) = try await session.data(from: probeURL)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        return session
        // installation released here at function return → deinit unregisters.
    }

    /// Stale `Installation` deinit must not affect a parallel installation's
    /// responder. Pre-#87 this was a token-gated reset of a single shared
    /// slot; under the per-installation registry it is automatic — each handle
    /// only ever knows its own token and so can only ever remove its own
    /// entry. This test pins the property by exercising the dispatch path.
    func test_installScoped_droppingOneHandle_doesNotAffectAnother() async throws {
        let firstURL = try XCTUnwrap(URL(string: "https://stale.test/first"))
        let secondURL = try XCTUnwrap(URL(string: "https://stale.test/second"))

        var firstHandle: URLProtocolStub.Installation? = URLProtocolStub.installScoped { request in
            let response = try XCTUnwrap(HTTPURLResponse(
                url: request.url ?? firstURL,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            ))
            return (response, Data())
        }
        // Explicit read so the compiler doesn't flag `firstHandle` as
        // write-only — the test's whole point is the var-then-nil shape.
        XCTAssertNotNil(firstHandle, "installScoped must return a handle")

        let secondHandle = URLProtocolStub.installScoped { request in
            let response = try XCTUnwrap(HTTPURLResponse(
                url: request.url ?? secondURL,
                statusCode: 201,
                httpVersion: nil,
                headerFields: nil
            ))
            return (response, Data())
        }

        // Need to keep the second session reference around so we can make a
        // request against it after the first handle goes away.
        let secondSession = URLSession(configuration: secondHandle.configuration)

        // `withExtendedLifetime` does not have an `async` overload, so use it
        // inside a `defer` whose synchronous body runs `_fixLifetime` at scope
        // exit. This is the only optimizer-respected lifetime extension that
        // composes with `await`. Without it, the optimizer is free to release
        // `secondHandle` after its last syntactic use (the property read on
        // the previous line), which would let `Installation.deinit` race the
        // in-flight request below.
        defer { withExtendedLifetime(secondHandle) {} }

        // Drop the first handle — its deinit removes only the first
        // responder slot, leaving second's registry entry intact.
        firstHandle = nil

        let (_, response) = try await secondSession.data(from: secondURL)
        XCTAssertEqual(
            (response as? HTTPURLResponse)?.statusCode,
            201,
            "Dropping firstHandle must not unregister secondHandle's responder"
        )
    }
}
