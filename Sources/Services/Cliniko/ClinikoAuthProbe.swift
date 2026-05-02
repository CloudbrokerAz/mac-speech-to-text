import Foundation
import os.log

/// Errors surfaced by `ClinikoAuthProbe`. Structural cases only — error
/// strings never embed the API key, the URL, or any PHI. The `.transport`
/// payload preserves a `URLError.Code` so callers can distinguish offline
/// from DNS / TLS, but `.cancelled` lives in its own case so a user-cancelled
/// probe never renders as "could not reach Cliniko" in the UI.
public enum ClinikoAuthProbeError: Error, Sendable, Equatable, CustomStringConvertible {
    case unauthorized
    case http(status: Int)
    case transport(URLError.Code)
    case cancelled
    case nonHTTPResponse
    case unknown(typeName: String)

    public var description: String {
        switch self {
        case .unauthorized: return "Cliniko rejected the API key (HTTP 401/403)"
        case .http(let status): return "Cliniko responded with HTTP \(status)"
        case .transport(let code): return "Network error (URLError code \(code.rawValue))"
        case .cancelled: return "Request was cancelled"
        case .nonHTTPResponse: return "Cliniko returned a non-HTTP response"
        case .unknown(let typeName): return "Unexpected error of type \(typeName)"
        }
    }
}

/// Minimal `GET /user` probe used by the Cliniko settings UI to verify that
/// a freshly entered API key works. This is intentionally narrower than the
/// full `ClinikoClient` planned for #8 — once that lands, the probe will be
/// expressed as `clinikoClient.send(.usersMe)`. Until then, a small
/// dependency-free actor here keeps #7 self-contained without pre-empting #8's
/// design.
///
/// The path is `/user` (singular, no id) — Cliniko's actual authenticated-user
/// endpoint per https://docs.api.cliniko.com/openapi/user. The earlier
/// `/users/me` wiring 404'd because Cliniko routes `/users/{id}` numerically
/// and `me` is not a numeric id; see #88 for the bug + fix history.
///
/// PHI: `/user` returns the practitioner's account, **not** patient data, so
/// the response body is non-PHI. Logs still avoid the response body and any
/// URL details — only the structural status / error case is emitted.
public actor ClinikoAuthProbe {
    private let session: URLSession
    /// `@Sendable () -> String` so the UA is resolved per request rather
    /// than frozen at init. The doctor edits their contact email in the
    /// Clinical Notes settings UI (#89); the default provider reads
    /// `ClinikoCredentialStore.contactEmailUserDefaultsKey` from
    /// `UserDefaults.standard`, so an email change takes effect on the
    /// next probe without re-instantiating the actor.
    private let userAgentProvider: @Sendable () -> String

    public init(
        session: URLSession = .shared,
        userAgentProvider: @escaping @Sendable () -> String = ClinikoUserAgent.defaultProvider()
    ) {
        self.session = session
        self.userAgentProvider = userAgentProvider
    }

    /// Convenience init for tests that pin a specific `User-Agent` string.
    /// Wraps the literal in a `@Sendable` closure so call sites that don't
    /// care about runtime UA reconfiguration stay terse.
    public init(
        session: URLSession = .shared,
        userAgent: String
    ) {
        self.init(session: session, userAgentProvider: { userAgent })
    }

    /// Issue `GET /user` against Cliniko using `credentials`. Returns
    /// successfully on any 2xx response, throws a typed `ClinikoAuthProbeError`
    /// otherwise. The response body is discarded — we only care that the key
    /// authenticates.
    public func ping(credentials: ClinikoCredentials) async throws {
        var request = URLRequest(url: credentials.baseURL.appendingPathComponent("user"))
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(userAgentProvider(), forHTTPHeaderField: "User-Agent")
        request.setValue(credentials.basicAuthHeaderValue, forHTTPHeaderField: "Authorization")
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData

        let response: URLResponse
        do {
            (_, response) = try await session.data(for: request)
        } catch is CancellationError {
            // Swift Concurrency cancellation — user navigated away. Don't
            // misreport as a network failure.
            throw ClinikoAuthProbeError.cancelled
        } catch let urlError as URLError where urlError.code == .cancelled {
            // URLSession-level cancellation (session invalidation) — treat
            // the same as user cancellation.
            throw ClinikoAuthProbeError.cancelled
        } catch let urlError as URLError {
            AppLogger.service.error(
                "ClinikoAuthProbe.ping: transport error code=\(urlError.code.rawValue, privacy: .public)"
            )
            throw ClinikoAuthProbeError.transport(urlError.code)
        } catch {
            // Type-name-only logging — never `String(describing: error)` because
            // a future error type could embed PHI (e.g. URL paths after #8).
            let typeName = String(describing: type(of: error))
            AppLogger.service.error(
                "ClinikoAuthProbe.ping: unexpected error type=\(typeName, privacy: .public)"
            )
            throw ClinikoAuthProbeError.unknown(typeName: typeName)
        }
        // `URLProtocolStub` always returns `HTTPURLResponse`, so this branch
        // is defensive against future custom URLProtocols (e.g. file://).
        guard let http = response as? HTTPURLResponse else {
            throw ClinikoAuthProbeError.nonHTTPResponse
        }
        switch http.statusCode {
        case 200..<300:
            AppLogger.service.info(
                "ClinikoAuthProbe.ping: OK status=\(http.statusCode, privacy: .public)"
            )
            return
        case 401, 403:
            AppLogger.service.info(
                "ClinikoAuthProbe.ping: unauthorized status=\(http.statusCode, privacy: .public)"
            )
            throw ClinikoAuthProbeError.unauthorized
        default:
            AppLogger.service.info(
                "ClinikoAuthProbe.ping: http status=\(http.statusCode, privacy: .public)"
            )
            throw ClinikoAuthProbeError.http(status: http.statusCode)
        }
    }
}
