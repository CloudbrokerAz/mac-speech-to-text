import Foundation

/// Thread-safe `URLProtocol` stub for testing network code without hitting the network.
///
/// Each `install(_:)` mints a unique installation token, registers the supplied responder
/// in a token-keyed registry, and tags the returned `URLSessionConfiguration` with that
/// token via `httpAdditionalHeaders[stubTokenHeader]`. Every request that flows through a
/// session built from that configuration carries the header; `startLoading()` reads the
/// header to dispatch back to the right responder.
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
///     let body = try HTTPStubFixture.load("cliniko/responses/user.json")
///     return (response, body)
/// }
/// let session = URLSession(configuration: config)
/// // ...use session...
/// ```
///
/// ## Concurrent suites are isolated (#87)
///
/// Earlier versions kept a single global `currentResponder` slot. Suites that ran in
/// parallel (e.g. `ModelDownloaderTests` + Cliniko networking suites) would race: one
/// suite's `defer { URLProtocolStub.reset() }` could null the slot mid-flight while
/// another suite's request was still in motion, surfacing as a misleading
/// `sizeMismatch(expected: 4, got: 0)` because the responder fell through to nothing.
///
/// The token-keyed registry makes that race impossible: each `install(_:)` writes to its
/// own slot, and only `Installation.deinit` (RAII) ever removes a slot — the per-test
/// `defer { URLProtocolStub.reset() }` pattern is now a documented no-op kept only so
/// existing call sites keep compiling. New tests should prefer `installScoped(_:)` and
/// let the handle's `deinit` clean up its slot.
///
/// ## Threading
///
/// `@unchecked Sendable` is safe because every access to the `responders` dict goes
/// through `lock`. `nonisolated(unsafe)` is required for Swift 6 concurrency checking
/// since `URLProtocol` callbacks come without actor isolation — SwiftLint's
/// `nonisolated_unsafe_warning` custom rule calls these usages out for review.
final class URLProtocolStub: URLProtocol, @unchecked Sendable {
    typealias Responder = @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)

    /// HTTP header name carrying the per-installation dispatch token. Tests should not
    /// set this header on outgoing requests — `URLSessionConfiguration.httpAdditionalHeaders`
    /// is responsible for stamping it on every request through a stub session, and a
    /// per-request override would defeat the dispatch.
    static let stubTokenHeader = "X-URLProtocolStub-Token"

    private static let lock = NSLock()
    nonisolated(unsafe) private static var responders: [String: Responder] = [:]

    // MARK: - Installation

    /// Install a responder; returns a `URLSessionConfiguration` tagged with a fresh
    /// per-installation token. Every request through a session built from the returned
    /// config will be intercepted and dispatched to `responder`.
    ///
    /// The responder slot persists for the test process lifetime (a few hundred bytes per
    /// test, garbage-collected at process exit). Tests that want deterministic cleanup
    /// should prefer `installScoped(_:)` instead.
    static func install(_ responder: @escaping Responder) -> URLSessionConfiguration {
        let (configuration, _) = makeConfiguration(responder: responder)
        return configuration
    }

    /// Routed install: dispatches each request to the first matching `Route`. The
    /// single-closure `install(_:)` form remains available unchanged for tests that only
    /// stub one endpoint.
    static func install(routes: [Route]) -> URLSessionConfiguration {
        install(makeRoutedResponder(routes))
    }

    /// RAII variant of `install(_:)`. Returns an `Installation` whose `deinit` removes
    /// its responder from the registry. Always assign the return value to a `let` —
    /// discarding it would let ARC tear the responder down before the test runs.
    static func installScoped(_ responder: @escaping Responder) -> Installation {
        let (configuration, token) = makeConfiguration(responder: responder)
        return Installation(configuration: configuration, token: token)
    }

    /// RAII variant of `install(routes:)`. Same dispatch semantics, lifetime tied to the
    /// returned handle. Always assign to a `let`.
    static func installScoped(routes: [Route]) -> Installation {
        let (configuration, token) = makeConfiguration(responder: makeRoutedResponder(routes))
        return Installation(configuration: configuration, token: token)
    }

    /// **No-op kept for back-compat** with the pre-#87 `defer { URLProtocolStub.reset() }`
    /// pattern. The per-installation registry makes per-test cleanup unnecessary, and
    /// clearing the entire registry mid-test is the exact bug #87 fixed (a parallel
    /// suite's reset would null another suite's responder mid-flight).
    ///
    /// Tests that genuinely want every responder gone can call `resetAll()` — but that
    /// is dangerous in a parallel-suite test runner and should only be used at process
    /// boundaries. Prefer `installScoped(_:)` for deterministic cleanup.
    static func reset() {
        // Deliberately no-op. See doc comment.
    }

    /// Hard-clear the entire responder registry. Dangerous in a parallel-suite runner;
    /// prefer `installScoped(_:)` for per-test cleanup. Exposed only so a future
    /// process-level fixture (`@MainActor` `setUpAll` / `tearDownAll`) has an explicit
    /// escape hatch when one is genuinely needed.
    static func resetAll() {
        lock.lock()
        defer { lock.unlock() }
        responders.removeAll()
    }

    // MARK: - Internals

    private static func makeConfiguration(
        responder: @escaping Responder
    ) -> (URLSessionConfiguration, String) {
        let token = UUID().uuidString
        lock.lock()
        responders[token] = responder
        lock.unlock()

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [URLProtocolStub.self] + (config.protocolClasses ?? [])
        // Merge with any existing additional headers the caller might have set on a
        // shared base config (none today, but defensive against future callers).
        var headers: [AnyHashable: Any] = config.httpAdditionalHeaders ?? [:]
        headers[stubTokenHeader] = token
        config.httpAdditionalHeaders = headers
        return (config, token)
    }

    fileprivate static func unregister(token: String) {
        lock.lock()
        defer { lock.unlock() }
        responders.removeValue(forKey: token)
    }

    private static func responder(for request: URLRequest) -> Responder? {
        guard let token = request.value(forHTTPHeaderField: stubTokenHeader) else { return nil }
        lock.lock()
        defer { lock.unlock() }
        return responders[token]
    }

    // MARK: - URLProtocol overrides

    /// Claim based on header *presence*, not registration. A request through a
    /// stub-tagged session whose `Installation` has already deinit'd would
    /// otherwise silently fall through to the real network — better to claim
    /// it and let `startLoading()` surface the descriptive "no responder"
    /// failure so the test author sees the lifetime bug at the point of harm.
    /// Untagged requests (e.g. `URLSession.shared` traffic) are unaffected.
    override class func canInit(with request: URLRequest) -> Bool {
        request.value(forHTTPHeaderField: stubTokenHeader) != nil
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let responder = Self.responder(for: request) else {
            // (c) — fail loudly with a diagnostic so a future regression surfaces as
            // "no responder for token X" rather than e.g. `sizeMismatch(expected: 4, got: 0)`
            // from the request falling through to nothing.
            let token = request.value(forHTTPHeaderField: Self.stubTokenHeader) ?? "<missing>"
            let error = URLError(
                .cannotLoadFromNetwork,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "URLProtocolStub: no responder registered for token \(token). "
                        + "Did the Installation handle deinit before the request fired?"
                ]
            )
            client?.urlProtocol(self, didFailWithError: error)
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
    /// One leg of a routed stub. The first `Route` in the array whose `matches` returns
    /// true serves the request. If none match, `install(routes:)` throws a descriptive
    /// `URLError` so a typo in a test path fails loudly instead of silently returning a
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

        /// Convenience for the common HTTP method + URL path case (most Cliniko service
        /// tests). Defaults to `GET`. The method and path are normalized once at Route
        /// construction (uppercased / leading slash enforced) so the per-request match
        /// is a pair of plain string equality checks — also makes a missing leading
        /// slash in the call site (`"v1/users"` vs `"/v1/users"`) a non-issue.
        static func path(
            _ path: String,
            method: String = "GET",
            respond: @escaping @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)
        ) -> Route {
            let normalizedMethod = method.uppercased()
            let normalizedPath = path.hasPrefix("/") ? path : "/" + path
            return Route(
                matches: { request in
                    (request.httpMethod ?? "GET").uppercased() == normalizedMethod
                        && request.url?.path == normalizedPath
                },
                respond: respond
            )
        }
    }

    /// RAII handle returned from `installScoped(_:)` / `installScoped(routes:)`. On
    /// `deinit` the handle removes only its own responder from the registry — it cannot
    /// affect a parallel suite's installation.
    ///
    /// Assign the return value to a `let`; discarding it would let ARC tear the
    /// responder down before the test runs. `@unchecked Sendable` mirrors
    /// `URLProtocolStub`; `deinit` may run on an arbitrary thread but only touches
    /// lock-protected static state.
    final class Installation: @unchecked Sendable {
        let configuration: URLSessionConfiguration
        private let token: String

        fileprivate init(configuration: URLSessionConfiguration, token: String) {
            self.configuration = configuration
            self.token = token
        }

        deinit {
            URLProtocolStub.unregister(token: token)
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
}
