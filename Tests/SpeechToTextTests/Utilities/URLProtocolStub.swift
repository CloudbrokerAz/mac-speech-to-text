import Foundation

/// Thread-safe `URLProtocol` stub for testing network code without hitting the network.
///
/// Install once per test, route all URL requests through the supplied closure, then call
/// `reset()` in tearDown.
///
/// ```swift
/// let config = URLProtocolStub.install { request in
///     guard let url = request.url else { throw URLError(.badURL) }
///     let response = HTTPURLResponse(
///         url: url,
///         statusCode: 200,
///         httpVersion: "HTTP/1.1",
///         headerFields: ["Content-Type": "application/json"]
///     )!
///     let body = try HTTPStubFixture.load("cliniko/responses/users_me.json")
///     return (response, body)
/// }
/// let session = URLSession(configuration: config)
/// // ...use session...
/// URLProtocolStub.reset()
/// ```
///
/// `@unchecked Sendable` is safe because the only mutable static (`currentResponder`) is
/// always accessed under `lock`. `nonisolated(unsafe)` is required for Swift 6 concurrency
/// checking since `URLProtocol` callbacks do not come with actor isolation — SwiftLint's
/// `nonisolated_unsafe_warning` custom rule calls these usages out for review.
final class URLProtocolStub: URLProtocol, @unchecked Sendable {
    typealias Responder = @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)

    private static let lock = NSLock()
    nonisolated(unsafe) private static var currentResponder: Responder?
    /// Generation token for the responder currently installed via
    /// `installScoped(_:)` / `installScoped(routes:)`. `Installation.deinit`
    /// clears `currentResponder` only when its captured token still matches —
    /// stops a stale handle from clobbering a newer install. The closure-form
    /// `install(_:)` clears the token (it has no RAII partner anyway).
    nonisolated(unsafe) private static var currentInstallationToken: UUID?

    /// Install the stub as the first protocol class in a new `URLSessionConfiguration`.
    /// Callers create a `URLSession` from the returned config; every request through
    /// that session will be intercepted until `reset()` is called.
    static func install(_ responder: @escaping Responder) -> URLSessionConfiguration {
        lock.lock()
        defer { lock.unlock() }
        currentResponder = responder
        currentInstallationToken = nil

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [URLProtocolStub.self] + (config.protocolClasses ?? [])
        return config
    }

    /// Clear the current responder. Call from `tearDown` so tests don't leak state.
    static func reset() {
        lock.lock()
        defer { lock.unlock() }
        currentResponder = nil
        currentInstallationToken = nil
    }

    /// Internal: install with a generation token so `Installation.deinit` can
    /// no-op if a newer install has already replaced this one.
    fileprivate static func installWithToken(
        _ responder: @escaping Responder,
        token: UUID
    ) -> URLSessionConfiguration {
        lock.lock()
        defer { lock.unlock() }
        currentResponder = responder
        currentInstallationToken = token

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [URLProtocolStub.self] + (config.protocolClasses ?? [])
        return config
    }

    /// Internal: reset only if the installation token still matches. Lets a
    /// stale `Installation.deinit` no-op when a later install has taken over.
    fileprivate static func resetIfTokenMatches(_ token: UUID) {
        lock.lock()
        defer { lock.unlock() }
        guard currentInstallationToken == token else { return }
        currentResponder = nil
        currentInstallationToken = nil
    }

    // MARK: - URLProtocol overrides

    override class func canInit(with request: URLRequest) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return currentResponder != nil
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        Self.lock.lock()
        let responder = Self.currentResponder
        Self.lock.unlock()
        guard let responder else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotLoadFromNetwork))
            return
        }
        do {
            let (response, data) = try responder(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {
        // No-op; work completes synchronously in startLoading.
    }
}

// MARK: - Routed installation + RAII handle

extension URLProtocolStub {
    /// One leg of a routed stub. The first `Route` in the array whose
    /// `matches` returns true serves the request. If none match,
    /// `install(routes:)` throws a descriptive `URLError` so a typo in a
    /// test path fails loudly instead of silently returning a
    /// `cannotLoadFromNetwork`.
    struct Route: Sendable {
        let matches: @Sendable (URLRequest) -> Bool
        let respond: @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)

        init(
            matches: @escaping @Sendable (URLRequest) -> Bool,
            respond: @escaping @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)
        ) {
            self.matches = matches
            self.respond = respond
        }

        /// Convenience for the common HTTP method + URL path case (most
        /// Cliniko service tests). Defaults to `GET`.
        static func path(
            _ path: String,
            method: String = "GET",
            respond: @escaping @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)
        ) -> Route {
            Route(
                matches: { request in
                    (request.httpMethod ?? "GET").uppercased() == method.uppercased()
                        && request.url?.path == path
                },
                respond: respond
            )
        }
    }

    /// RAII handle returned from `installScoped(_:)` / `installScoped(routes:)`.
    /// On `deinit` the handle conditionally clears the stub — only if its
    /// captured installation token is still current — so a stale handle that
    /// outlives a newer install will no-op rather than nuke the active stub.
    ///
    /// Assign the return value to a `let`; discarding it would let ARC tear
    /// the stub down before the test runs. `@unchecked Sendable` mirrors
    /// `URLProtocolStub`; `deinit` may run on an arbitrary thread but only
    /// touches lock-protected static state.
    final class Installation: @unchecked Sendable {
        let configuration: URLSessionConfiguration
        private let token: UUID

        fileprivate init(configuration: URLSessionConfiguration, token: UUID) {
            self.configuration = configuration
            self.token = token
        }

        deinit {
            URLProtocolStub.resetIfTokenMatches(token)
        }
    }

    /// Builds the multiplexed responder used by both `install(routes:)` and
    /// `installScoped(routes:)`. Only the URL *path* is interpolated into the
    /// no-match error message — query parameters and full host can carry PHI
    /// (e.g. patient_id in a Cliniko URL), and `URLError.localizedDescription`
    /// surfaces in test failure logs which CI runners may persist. The path
    /// alone is enough to diagnose a stub typo.
    private static func makeRoutedResponder(_ routes: [Route]) -> Responder {
        { request in
            for route in routes where route.matches(request) {
                return try route.respond(request)
            }
            let path = request.url?.path ?? "<no path>"
            throw URLError(
                .unsupportedURL,
                userInfo: [
                    NSLocalizedDescriptionKey: "URLProtocolStub: no Route matched \(path)"
                ]
            )
        }
    }

    /// Routed install: dispatches each request to the first matching `Route`.
    /// The single-closure `install(_:)` form remains available unchanged for
    /// tests that only stub one endpoint.
    static func install(routes: [Route]) -> URLSessionConfiguration {
        install(makeRoutedResponder(routes))
    }

    /// RAII variant of `install(_:)`. Returns an `Installation` whose `deinit`
    /// calls `reset()` — drop the manual `tearDown { URLProtocolStub.reset() }`
    /// when adopting this form. Always assign to a `let`; discarding the
    /// return value would let ARC tear the stub down immediately.
    static func installScoped(_ responder: @escaping Responder) -> Installation {
        let token = UUID()
        let configuration = installWithToken(responder, token: token)
        return Installation(configuration: configuration, token: token)
    }

    /// RAII variant of `install(routes:)`. Same dispatch semantics, lifetime
    /// tied to the returned handle. Always assign to a `let`.
    static func installScoped(routes: [Route]) -> Installation {
        let token = UUID()
        let configuration = installWithToken(makeRoutedResponder(routes), token: token)
        return Installation(configuration: configuration, token: token)
    }
}
