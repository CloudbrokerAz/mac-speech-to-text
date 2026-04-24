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

    /// Install the stub as the first protocol class in a new `URLSessionConfiguration`.
    /// Callers create a `URLSession` from the returned config; every request through
    /// that session will be intercepted until `reset()` is called.
    static func install(_ responder: @escaping Responder) -> URLSessionConfiguration {
        lock.lock()
        defer { lock.unlock() }
        currentResponder = responder

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [URLProtocolStub.self] + (config.protocolClasses ?? [])
        return config
    }

    /// Clear the current responder. Call from `tearDown` so tests don't leak state.
    static func reset() {
        lock.lock()
        defer { lock.unlock() }
        currentResponder = nil
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
